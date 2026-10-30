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

/// Finds a command-line tool the way a new tab does (`ToolLocator`): through
/// the user's interactive login shell, then common install folders.
public enum ToolProbe {
    /// The path `tool` resolves to, or nil when nothing finds it.
    public static func resolve(_ tool: String, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                               overrides: [String: String] = [:], timeout: TimeInterval = 8) async -> String? {
        await ToolLocator.locate([tool], shell: shell, overrides: overrides, timeout: timeout).path(of: tool)
    }
}
