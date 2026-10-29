import Dispatch
import Foundation

/// A process listening on a local TCP port whose working directory is inside
/// a project: almost always a dev server started from one of its tabs.
public struct DevServer: Hashable, Sendable, Identifiable {
    public var port: Int
    public var pid: Int32
    public var command: String

    public var id: Int { port }

    public init(port: Int, pid: Int32, command: String) {
        self.port = port
        self.pid = pid
        self.command = command
    }

    public var url: URL { URL(string: "http://localhost:\(port)/")! }
}

/// Parses `lsof -F` field output: one field per line, the first character
/// naming it (`p` pid, `c` command, `n` name, `f` fd, others ignored).
public enum LsofParser {
    public struct Listener: Hashable, Sendable {
        public var pid: Int32
        public var command: String
        public var port: Int
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`. A process listening on both IPv4
    /// and IPv6 for the same port is reported once.
    public static func listeners(_ output: String) -> [Listener] {
        var result: [Listener] = []
        var seen: Set<Listener> = []
        var pid: Int32?
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let port = port(of: value) else { continue }
                let listener = Listener(pid: pid, command: command, port: port)
                if seen.insert(listener).inserted { result.append(listener) }
            default:
                continue
            }
        }
        return result
    }

    /// `lsof -a -d cwd -p <pids> -Fpn`: each process's working directory.
    public static func workingDirectories(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "n": if let pid { result[pid] = value }
            default: continue
            }
        }
        return result
    }

    /// The port in `127.0.0.1:5173`, `*:3000` or `[::1]:8080`.
    static func port(of name: String) -> Int? {
        // An established connection reads `a:1->b:2`; listeners never do.
        guard !name.contains("->"), let colon = name.lastIndex(of: ":") else { return nil }
        return Int(name[name.index(after: colon)...])
    }
}

public enum DevServerFinder {
    /// Listeners that are never a project's dev server: Claude Code's own
    /// IDE bridge runs in the project folder too.
    public static let ignoredCommands: Set<String> = ["claude", "Tether"]

    /// Pairs listeners with working directories and keeps those inside one
    /// of `folders`, keyed by that folder. The deepest folder wins, so a
    /// worktree nested in its project gets its own servers.
    public static func match(listeners: [LsofParser.Listener], cwds: [Int32: String],
                             folders: [String], excludingPid: Int32) -> [String: [DevServer]] {
        let roots = folders.map(normalized).sorted { $0.count > $1.count }
        var result: [String: [DevServer]] = [:]
        for listener in listeners where listener.pid != excludingPid && !ignoredCommands.contains(listener.command) {
            guard let cwd = cwds[listener.pid].map(normalized),
                  let root = roots.first(where: { cwd == $0 || cwd.hasPrefix($0 + "/") })
            else { continue }
            result[root, default: []].append(DevServer(port: listener.port, pid: listener.pid, command: listener.command))
        }
        for key in result.keys { result[key]?.sort { $0.port < $1.port } }
        return result
    }

    /// The key `match` and `scan` file a folder's servers under.
    public static func key(for folder: String) -> String { normalized(folder) }

    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // lsof reports the resolved path; /tmp and /var are symlinks into /private on macOS.
        for link in ["/tmp", "/var"] where path == link || path.hasPrefix(link + "/") {
            path = "/private" + path
        }
        return path
    }

    /// Runs lsof twice: every TCP listener, then the working directories of
    /// their processes. Returns nothing (not an error) when lsof is missing.
    public static func scan(folders: [String], lsof: String = "/usr/sbin/lsof",
                            timeout: TimeInterval = 5) async -> [String: [DevServer]] {
        guard !folders.isEmpty, FileManager.default.isExecutableFile(atPath: lsof) else { return [:] }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scanBlocking(folders: folders, lsof: lsof, timeout: timeout, ownPid: ownPid))
            }
        }
    }

    private static func scanBlocking(folders: [String], lsof: String, timeout: TimeInterval,
                                     ownPid: Int32) -> [String: [DevServer]] {
        let env = ["LC_ALL": "C"]
        // lsof exits 1 when it finds nothing.
        guard let listening = try? GitRunner.runBlocking(
            executable: lsof, arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], directory: "/",
            environment: env, timeout: timeout, allowedExitCodes: [0, 1])
        else { return [:] }
        let listeners = LsofParser.listeners(listening.text)
            .filter { $0.pid != ownPid && !ignoredCommands.contains($0.command) }
        guard !listeners.isEmpty else { return [:] }
        let pids = Set(listeners.map(\.pid)).map(String.init).sorted().joined(separator: ",")
        guard let cwdOutput = try? GitRunner.runBlocking(
            executable: lsof, arguments: ["-a", "-d", "cwd", "-p", pids, "-Fpn"], directory: "/",
            environment: env, timeout: timeout, allowedExitCodes: [0, 1])
        else { return [:] }
        return match(listeners: listeners, cwds: LsofParser.workingDirectories(cwdOutput.text),
                     folders: folders, excludingPid: ownPid)
    }
}

/// What the Preview panel shows for a folder.
public enum PreviewTarget {
    /// The address typed or picked for this folder wins; otherwise the
    /// lowest port found running there.
    public static func url(chosen: URL?, servers: [DevServer]) -> URL? {
        chosen ?? servers.first?.url
    }

    /// Turns what someone typed into an address: `5173`, `localhost:3000`,
    /// `example.com/path` or a full URL.
    public static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let port = Int(trimmed), (1...65535).contains(port) {
            return URL(string: "http://localhost:\(port)/")
        }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
