import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum CodexServerEvent: Sendable {
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
    case closed(String?)
}

public enum CodexAppServerError: Error, Sendable, LocalizedError {
    case unavailable, disconnected, timedOut, malformedMessage, frameTooLarge
    case launchFailed, writeFailed, rpc(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Codex app-server is not ready."
        case .disconnected: "Codex app-server disconnected."
        case .timedOut: "Codex app-server request timed out."
        case .malformedMessage: "Codex app-server sent an invalid RPC message."
        case .frameTooLarge: "Codex app-server exceeded the message size limit."
        case .launchFailed: "Codex app-server could not be launched."
        case .writeFailed: "Could not write to Codex app-server."
        case .rpc(let code, let message): "Codex app-server error \(code): \(message)"
        }
    }
}

/// One app-server process and its RPC connection. Starting never creates a thread or turn.
/// Instances are single-use; create a fresh instance after disconnecting.
public actor CodexAppServer {
    public struct Configuration: Sendable {
        public var workingDirectory: String
        public var clientVersion: String
        public var executableURL: URL?
        public var arguments: [String]?
        public var environment: [String: String]?
        public var requestTimeout: Duration

        public init(workingDirectory: String, clientVersion: String, executableURL: URL? = nil,
                    arguments: [String]? = nil, environment: [String: String]? = nil,
                    requestTimeout: Duration = .seconds(30)) {
            self.workingDirectory = workingDirectory
            self.clientVersion = clientVersion
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
            self.requestTimeout = requestTimeout
        }
    }

    public nonisolated let events: AsyncStream<CodexServerEvent>
    private let eventSink: AsyncStream<CodexServerEvent>.Continuation
    private let configuration: Configuration
    private enum State { case idle, starting, ready, closed }
    private var state = State.idle
    private var process: Process?
    private var closingProcess: Process?
    private var input: CodexRPCInput?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var nextID = 0
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timer: Task<Void, Never>
    }
    private var pending: [JSONValue: Pending] = [:]
    private static let maximumFrameBytes = 16 * 1024 * 1024

    public init(configuration: Configuration) {
        self.configuration = configuration
        let stream = AsyncStream<CodexServerEvent>.makeStream()
        events = stream.stream
        eventSink = stream.continuation
    }

    public func start() async throws {
        guard state == .idle else { throw CodexAppServerError.unavailable }
        state = .starting
        let child = Process()
        let output = Pipe()
        let incoming = Pipe()
        let shell = configuration.environment?["SHELL"] ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        child.executableURL = configuration.executableURL ?? URL(fileURLWithPath: shell)
        child.arguments = configuration.arguments ?? (configuration.executableURL == nil
            ? ["-l", "-c", "exec codex app-server --listen stdio://"]
            : ["app-server", "--listen", "stdio://"])
        child.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        child.environment = configuration.environment ?? ProcessInfo.processInfo.environment
        child.standardInput = incoming
        child.standardOutput = output
        // Do not relay diagnostics that may include user content or credentials.
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch {
            close(.launchFailed)
            throw CodexAppServerError.launchFailed
        }
        process = child
        input = CodexRPCInput(handle: incoming.fileHandleForWriting)
        try? incoming.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let handle = output.fileHandleForReading
        reader = Task.detached { [weak self] in
            defer { try? handle.close() }
            while !Task.isCancelled {
                // FileHandle.read(upToCount:) can wait for the entire count on pipes.
                // POSIX read returns the currently available bytes, including short frames.
                // A pipe can wait indefinitely. Keep that wait off Swift's cooperative
                // executor so multiple sessions cannot starve requests and timers.
                let data: Data? = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        var bytes = [UInt8](repeating: 0, count: 65_536)
                        var count: Int
                        repeat { count = read(handle.fileDescriptor, &bytes, bytes.count) }
                        while count < 0 && errno == EINTR
                        continuation.resume(returning: count > 0 ? Data(bytes.prefix(count)) : nil)
                    }
                }
                guard let data, let self else { break }
                await self.receive(data)
            }
            await self?.ended()
        }
        do {
            _ = try await sendRequest("initialize", params: .object([
                "clientInfo": .object(["name": .string("tether"), "title": .string("Tether"),
                                       "version": .string(configuration.clientVersion)])
            ]))
            guard state == .starting else { throw CodexAppServerError.disconnected }
            try await write(.object(["method": .string("initialized"), "params": .object([:])]))
            guard state == .starting else { throw CodexAppServerError.disconnected }
            state = .ready
        } catch {
            close(error as? CodexAppServerError ?? .disconnected)
            throw error
        }
    }

    public func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard state == .ready else { throw CodexAppServerError.unavailable }
        return try await sendRequest(method, params: params)
    }

    public func respond(to id: JSONValue, result: JSONValue) async throws {
        guard state == .ready, Self.validID(id) else { throw CodexAppServerError.unavailable }
        try await write(.object(["id": id, "result": result]))
    }

    public func respondError(to id: JSONValue, message: String) async throws {
        guard state == .ready, Self.validID(id) else { throw CodexAppServerError.unavailable }
        try await write(.object(["id": id, "error": .object([
            "code": .number(-32601), "message": .string(message)
        ])]))
    }

    public func stop() async {
        let child = process ?? closingProcess
        close(.disconnected, reason: nil)
        guard let child else { return }
        // Awaitable shutdown is also used by application termination. Do not rely
        // on a detached cleanup task surviving after the app has exited.
        for _ in 0..<20 {
            if !child.isRunning { closingProcess = nil; return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        for _ in 0..<10 {
            if !child.isRunning { closingProcess = nil; return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sendRequest(_ method: String, params: JSONValue) async throws -> JSONValue {
        nextID += 1
        let id = JSONValue.number(Double(nextID))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = configuration.requestTimeout
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.write(.object(["id": id, "method": .string(method), "params": params])) }
                    catch { await self.close(.writeFailed) }
                }
            }
        } onCancel: {
            // A canceled request may already have reached the server. Close rather than retry it.
            Task { await self.close(.disconnected) }
        }
    }

    private func write(_ value: JSONValue) async throws {
        guard state != .closed, let input else { throw CodexAppServerError.disconnected }
        var data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumFrameBytes else { throw CodexAppServerError.frameTooLarge }
        data.append(10)
        try await input.write(data)
    }

    private func receive(_ data: Data) {
        guard state != .closed else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let count = buffer.distance(from: buffer.startIndex, to: newline)
            guard count <= Self.maximumFrameBytes else { close(.frameTooLarge); return }
            let frame = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if frame.isEmpty { continue }
            do {
                let value = try JSONDecoder().decode(JSONValue.self, from: frame)
                try receiveMessage(value)
            } catch {
                close(.malformedMessage)
                return
            }
        }
        if buffer.count > Self.maximumFrameBytes { close(.frameTooLarge) }
    }

    private static func validID(_ id: JSONValue) -> Bool {
        switch id {
        case .string: true
        case .number(let n): n.isFinite && n.rounded() == n
        default: false
        }
    }

    private func receiveMessage(_ value: JSONValue) throws {
        guard case .object(let object) = value else { throw CodexAppServerError.malformedMessage }
        if let method = object["method"]?.stringValue {
            let params = object["params"] ?? .object([:])
            if let id = object["id"] {
                guard Self.validID(id) else { throw CodexAppServerError.malformedMessage }
                eventSink.yield(.request(id: id, method: method, params: params))
            } else {
                eventSink.yield(.notification(method: method, params: params))
            }
            return
        }
        guard let id = object["id"], Self.validID(id),
              (object["result"] != nil) != (object["error"] != nil) else {
            throw CodexAppServerError.malformedMessage
        }
        let rpcError: CodexAppServerError?
        if let error = object["error"] {
            guard case .number(let code)? = error["code"], code.isFinite,
                  code.rounded() == code, code >= Double(Int.min), code < Double(Int.max),
                  let message = error["message"]?.stringValue else { throw CodexAppServerError.malformedMessage }
            rpcError = .rpc(code: Int(code), message: message)
        } else { rpcError = nil }
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        if let rpcError { request.continuation.resume(throwing: rpcError) }
        else { request.continuation.resume(returning: object["result"]!) }
    }

    private func expire(_ id: JSONValue) {
        if pending[id] != nil { close(.timedOut) }
    }

    private func ended() {
        close(buffer.isEmpty ? .disconnected : .malformedMessage)
    }

    private func close(_ error: CodexAppServerError, reason: String? = "disconnected") {
        guard state != .closed else { return }
        state = .closed
        reader?.cancel()
        reader = nil
        input?.close()
        input = nil
        let child = process
        closingProcess = child
        process = nil
        if let child, child.isRunning {
            child.terminate()
            // A misbehaving child must not outlive a stopped connection indefinitely.
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
        }
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timer.cancel()
            request.continuation.resume(throwing: error)
        }
        buffer.removeAll()
        eventSink.yield(.closed(reason == nil ? nil : error.localizedDescription))
        eventSink.finish()
    }
}

/// Writes are serialized off the actor so a full stdin pipe cannot block stdout processing.
private final class CodexRPCInput: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.tether.codex-rpc-input")
    init(handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do { try writeWithoutSIGPIPE(data); continuation.resume() }
                catch { continuation.resume(throwing: CodexAppServerError.writeFailed) }
            }
        }
    }
    private func writeWithoutSIGPIPE(_ data: Data) throws {
        let descriptor = handle.fileDescriptor
        #if canImport(Darwin)
        // Scope suppression to this pipe; changing the process signal handler would
        // also change the embedded terminal and every unrelated subprocess.
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else { throw CodexAppServerError.writeFailed }
        #else
        // Linux pipes have no per-descriptor NOSIGPIPE flag. Block on this worker
        // thread, consume only a SIGPIPE generated by our write, then restore its mask.
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        var previous = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else { throw CodexAppServerError.writeFailed }
        var signals = sigset_t()
        sigpending(&signals)
        let alreadyPending = sigismember(&signals, SIGPIPE) == 1
        var brokenPipe = false
        defer {
            if brokenPipe && !alreadyPending {
                sigpending(&signals)
                if sigismember(&signals, SIGPIPE) == 1 {
                    var received: Int32 = 0
                    _ = sigwait(&blocked, &received)
                }
            }
            _ = pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        #endif
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor, address.advanced(by: offset), bytes.count - offset)
                #else
                let count = Glibc.write(descriptor, address.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EPIPE { brokenPipe = true }
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CodexAppServerError.writeFailed }
                offset += count
            }
        }
    }
    func close() { queue.async { [self] in try? handle.close() } }
}
