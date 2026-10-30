import Dispatch
import Foundation

/// A folder Claude Code has been used in, found from `~/.claude/projects`.
public struct UsedFolder: Hashable, Sendable, Identifiable {
    public var path: String
    public var lastUsed: Date
    public var sessions: Int

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public init(path: String, lastUsed: Date, sessions: Int) {
        self.path = path
        self.lastUsed = lastUsed
        self.sessions = sessions
    }
}

extension SessionHistory {
    /// Folders Claude Code has run in, most recently used first, for the
    /// welcome's project suggestions. The folder comes from the `cwd` in the
    /// newest transcript, since the directory name loses its separators.
    /// Skipped: folders that no longer exist, the home folder itself,
    /// Tether's own worktrees and anything under `.claude`.
    public static func recentFolders(
        projectsDirectory: URL = TranscriptLocator.defaultProjectsDirectory,
        home: String = NSHomeDirectory(),
        limit: Int = 12,
        folderExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> [UsedFolder] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: projectsDirectory.path) else { return [] }
        var found: [String: UsedFolder] = [:]
        for name in names {
            let dir = projectsDirectory.appendingPathComponent(name)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            var newest: (name: String, modified: Date)?
            var count = 0
            for file in files where file.hasSuffix(".jsonl") && !file.hasPrefix("agent-") {
                count += 1
                let modified = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.modificationDate]
                                as? Date) ?? .distantPast
                if newest == nil || modified > newest!.modified { newest = (file, modified) }
            }
            guard let newest,
                  let (head, _) = readEnds(of: dir.appendingPathComponent(newest.name)),
                  let cwd = firstCwd(in: head),
                  isSuggestible(cwd, home: home), folderExists(cwd) else { continue }
            // Two encoded directories can name one folder (a trailing slash, a rename).
            if let existing = found[cwd] {
                found[cwd] = UsedFolder(path: cwd, lastUsed: max(existing.lastUsed, newest.modified),
                                        sessions: existing.sessions + count)
            } else {
                found[cwd] = UsedFolder(path: cwd, lastUsed: newest.modified, sessions: count)
            }
        }
        return Array(found.values.sorted { $0.lastUsed > $1.lastUsed }.prefix(limit))
    }

    static func isSuggestible(_ path: String, home: String) -> Bool {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == "/" || trimmed == home { return false }
        if trimmed.contains("/.claude") || trimmed.contains("/Application Support/Tether/Worktrees") { return false }
        return true
    }
}

/// Finds the command-line tools Tether runs, the way a new tab does: through
/// the user's login shell, so PATH set in `.zprofile` applies.
public enum ToolProbe {
    /// The path `tool` resolves to, or nil when the shell can't find it.
    public static func resolve(_ tool: String, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                               timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(tool, shell: shell, timeout: timeout))
            }
        }
    }

    static func runBlocking(_ tool: String, shell: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(TerminalLaunch.shellQuote(tool))"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parse(text)
    }

    /// The last non-empty line: a login shell can print a banner first. An
    /// alias or function comes back as a word, not a path, and counts as missing.
    static func parse(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line, line.hasPrefix("/") else { return nil }
        return line
    }
}
