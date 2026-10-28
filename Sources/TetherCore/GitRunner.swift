import Dispatch
import Foundation

public struct GitOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum GitError: Error, Sendable, Equatable, CustomStringConvertible {
    case notARepository
    case failed(command: String, status: Int32, stderr: String)
    case timedOut(command: String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .notARepository:
            "Not a git repository"
        case .failed(let command, let status, let stderr):
            let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(status)"
            return "git \(command): \(line)"
        case .timedOut(let command):
            "git \(command) timed out"
        case .launchFailed(let reason):
            "Could not run git: \(reason)"
        }
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

/// Foundation's process and pipe types are thread-safe in practice but not
/// all marked Sendable on every SDK.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Runs the `git` CLI. Shelling out keeps worktrees, sparse checkouts and
/// credential helpers behaving exactly as they do in the user's terminal.
public struct GitRunner: Sendable {
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(environment: [String: String] = [:], timeout: TimeInterval = 30) {
        self.environment = environment
        self.timeout = timeout
    }

    /// Runs git in `directory`. A status outside `allowedExitCodes` throws.
    public func run(_ arguments: [String], in directory: String,
                    allowedExitCodes: Set<Int32> = [0], timeout: TimeInterval? = nil) async throws -> GitOutput {
        let env = effectiveEnvironment()
        let limit = timeout ?? self.timeout
        let args = ["-c", "core.quotepath=false", "-c", "color.ui=never"] + arguments
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try Self.runBlocking(arguments: args, directory: directory, environment: env,
                                         timeout: limit, allowedExitCodes: allowedExitCodes)
                })
            }
        }
    }

    func effectiveEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Reading status must not rewrite the index, or every refresh would
        // trigger the file watcher that caused it.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        env.merge(environment) { _, new in new }
        return env
    }

    static func runBlocking(arguments: [String], directory: String, environment: [String: String],
                            timeout: TimeInterval, allowedExitCodes: Set<Int32>) throws -> GitOutput {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError.launchFailed("folder not found: \(directory)")
        }
        let command = arguments.drop(while: { $0 == "-c" || $0.contains("=") }).first ?? "git"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(String(describing: error))
        }

        // Drain stderr on its own thread so a chatty git cannot fill the pipe
        // and deadlock while we read stdout.
        let errorData = LockedBox(Data())
        let errorDone = DispatchSemaphore(value: 0)
        let errorHandle = Unchecked(stderr.fileHandleForReading)
        DispatchQueue.global(qos: .utility).async {
            errorData.set(errorHandle.value.readDataToEndOfFile())
            errorDone.signal()
        }

        let timedOut = LockedBox(false)
        let running = Unchecked(process)
        let killer = DispatchWorkItem {
            if running.value.isRunning {
                timedOut.set(true)
                running.value.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        errorDone.wait()

        if timedOut.get() { throw GitError.timedOut(command: command) }
        let errorText = String(decoding: errorData.get(), as: UTF8.self)
        let status = process.terminationStatus
        guard allowedExitCodes.contains(status) else {
            if errorText.contains("not a git repository") { throw GitError.notARepository }
            throw GitError.failed(command: command, status: status,
                                  stderr: errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return GitOutput(status: status, stdout: output, stderr: errorText)
    }
}
