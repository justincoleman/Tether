import Dispatch
import Foundation

/// Where Tether found the command-line tools it launches, and the PATH the
/// user's own shell sets up.
///
/// An app opened from Finder or the Dock inherits launchd's PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), and `zsh -l -c` reads `.zprofile` but
/// not `.zshrc`, which is where most installers add `~/.local/bin`, nvm or
/// npm's bin folder. Started from a terminal, the app inherits that terminal's
/// PATH, which is why a dev build finds `claude` and a released one may not.
/// So tabs launch tools by absolute path and get the shell's PATH in their env.
public struct ToolPaths: Hashable, Sendable {
    /// Absolute path per tool name, for the tools that were found.
    public var executables: [String: String]
    /// PATH from the user's interactive login shell; nil when no probe printed one.
    public var shellPath: String?

    public init(executables: [String: String] = [:], shellPath: String? = nil) {
        self.executables = executables
        self.shellPath = shellPath
    }

    public func path(of tool: String) -> String? { executables[tool] }

    /// PATH for a new tab: the shell's (or the inherited one), plus every folder
    /// a tool was found in, so `claude` can still run `claude` and `node`.
    public func launchPath(inherited: String?) -> String {
        let base = shellPath ?? inherited ?? ToolLocator.systemPath
        var dirs = base.split(separator: ":").map(String.init)
        for exe in executables.values.sorted() {
            let dir = URL(fileURLWithPath: exe).deletingLastPathComponent().path
            if !dir.isEmpty, !dirs.contains(dir) { dirs.append(dir) }
        }
        return dirs.joined(separator: ":")
    }
}

public enum ToolLocator {
    /// launchd's PATH, what a Finder-launched app starts with.
    public static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Finds `tools`. In order: a path the user picked (`overrides`), the
    /// user's interactive login shell (`$SHELL -ilc`, so `.zshrc` applies),
    /// a plain login shell in case `.zshrc` misbehaves without a terminal,
    /// then the folders installers commonly use.
    public static func locate(
        _ tools: [String],
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        home: String = NSHomeDirectory(),
        overrides: [String: String] = [:],
        timeout: TimeInterval = 8
    ) async -> ToolPaths {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = probeScript(tools: tools)
                var outputs: [String] = []
                if let out = runShell(shell, ["-i", "-l", "-c", script], timeout: timeout) {
                    outputs.append(out)
                }
                let first = merge(tools: tools, probes: outputs, home: home, overrides: [:],
                                  isExecutable: isExecutable, listDirectory: { _ in [] }, searchCommonFolders: false)
                if first.shellPath == nil || first.executables.count < tools.count,
                   let out = runShell(shell, ["-l", "-c", script], timeout: timeout) {
                    outputs.append(out)
                }
                continuation.resume(returning: merge(
                    tools: tools, probes: outputs, home: home, overrides: overrides,
                    isExecutable: isExecutable, listDirectory: listDirectory))
            }
        }
    }

    /// Combines what the probes printed with the overrides and common folders.
    /// The first probe to name a tool that exists wins; the first PATH wins.
    static func merge(
        tools: [String],
        probes: [String],
        home: String,
        overrides: [String: String],
        isExecutable: (String) -> Bool,
        listDirectory: (String) -> [String],
        searchCommonFolders: Bool = true
    ) -> ToolPaths {
        let parsed = probes.map { parseProbe($0, home: home) }
        var result = ToolPaths(shellPath: parsed.lazy.compactMap { $0.path }.first)
        let common = searchCommonFolders ? candidateDirectories(home: home, listDirectory: listDirectory) : []
        for tool in tools {
            if let picked = overrides[tool], isExecutable(picked) {
                result.executables[tool] = picked
                continue
            }
            if let found = parsed.lazy.compactMap({ $0.tools[tool] }).first(where: isExecutable) {
                result.executables[tool] = found
                continue
            }
            if let found = common.lazy.map({ "\($0)/\(tool)" }).first(where: isExecutable) {
                result.executables[tool] = found
            }
        }
        return result
    }

    // MARK: The shell probe

    static let marker = "__TETHER_PROBE__"

    /// Prints PATH and each tool's `command -v`, each on a line behind a marker,
    /// so banners, prompts and escape codes from `.zshrc` can't be mistaken for
    /// output. Works in zsh, bash and fish.
    public static func probeScript(tools: [String]) -> String {
        var lines = ["printf '\\n\(marker)PATH=%s\\n' \"$PATH\""]
        for tool in tools {
            let q = TerminalLaunch.shellQuote(tool)
            lines.append("printf '\(marker)\(tool)=%s\\n' \"$(command -v \(q) 2>/dev/null)\"")
        }
        return lines.joined(separator: "; ")
    }

    static func parseProbe(_ output: String, home: String) -> (path: String?, tools: [String: String]) {
        var path: String?
        var tools: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: marker) else { continue }
            let rest = line[range.upperBound...]
            guard let eq = rest.firstIndex(of: "=") else { continue }
            let key = String(rest[..<eq])
            let value = String(rest[rest.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "PATH" {
                if !value.isEmpty { path = value }
            } else if let exe = executablePath(fromCommandV: value, home: home) {
                tools[key] = exe
            }
        }
        return (path, tools)
    }

    /// `command -v` prints a path, or in an interactive shell the alias, as
    /// `alias claude='~/.claude/local/claude'` (the old local installer adds
    /// one to `.zshrc`). A function or builtin prints a bare word: no path.
    static func executablePath(fromCommandV raw: String, home: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("alias ") {
            guard let eq = s.firstIndex(of: "=") else { return nil }
            s = String(s[s.index(after: eq)...])
            if let quote = s.first, quote == "'" || quote == "\"" {
                s.removeFirst()
                if s.last == quote { s.removeLast() }
            }
            s = s.split(separator: " ").first.map(String.init) ?? ""
        }
        if s.hasPrefix("~/") {
            s = home + s.dropFirst()
        } else if s.hasPrefix("$HOME/") {
            s = home + s.dropFirst(5)
        }
        return s.hasPrefix("/") ? s : nil
    }

    // MARK: Common install folders

    /// Folders installers put `claude` and `codex` in, checked when no shell
    /// names the tool. nvm versions come newest first.
    static func candidateDirectories(home: String, listDirectory: (String) -> [String]) -> [String] {
        var dirs = [
            "\(home)/.local/bin",       // Claude Code's native installer
            "\(home)/.claude/local",    // Claude Code's older local install
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/Library/pnpm",
            "\(home)/.yarn/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/.cargo/bin",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        dirs += listDirectory(nvm).sorted(by: versionIsNewer).map { "\(nvm)/\($0)/bin" }
        return dirs
    }

    static func versionIsNewer(_ a: String, _ b: String) -> Bool {
        let pa = numbers(a), pb = numbers(b)
        for (x, y) in zip(pa, pb) where x != y { return x > y }
        return pa.count > pb.count
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split { !$0.isNumber }.compactMap { Int($0) }
    }

    // MARK: Running the shell

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    static func listDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// Runs the shell and returns what it printed, whatever its exit status, or
    /// nil if it couldn't start or ran past `timeout`. Output goes to a file,
    /// not a pipe: a `.zshrc` that starts an agent in the background would keep
    /// a pipe open, and reading it would never finish.
    static func runShell(_ shell: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let fm = FileManager.default
        let outURL = fm.temporaryDirectory.appendingPathComponent("tether-probe-\(UUID().uuidString)")
        guard fm.createFile(atPath: outURL.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outURL) else { return nil }
        defer {
            try? outHandle.close()
            try? fm.removeItem(at: outURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // The termination handler, not a second thread parked in waitUntilExit:
        // with the pool busy that thread can start late and the timeout fires on
        // a shell that had long since exited.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard let data = try? Data(contentsOf: outURL) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
