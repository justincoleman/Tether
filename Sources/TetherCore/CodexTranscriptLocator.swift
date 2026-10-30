import Foundation

/// Locates one known Codex session. It does not import the user's session history.
public enum CodexTranscriptLocator {
    public static var defaultSessionsDirectory: URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let home = configured.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Only dated rollout files are considered, with a fixed entry budget.
    public static func find(sessionId: String, in root: URL = defaultSessionsDirectory,
                            maxEntries: Int = 10_000) -> String? {
        guard let uuid = UUID(uuidString: sessionId), maxEntries > 0 else { return nil }
        let suffix = "-" + uuid.uuidString.lowercased() + ".jsonl"
        var remaining = maxEntries
        func children(_ directory: URL) -> [URL] {
            guard remaining > 0 else { return [] }
            // Enumeration is non-recursive; symlink directories are never followed.
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return [] }
            var urls: [URL] = []
            while remaining > 0, let url = enumerator.nextObject() as? URL {
                remaining -= 1
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
                urls.append(url)
            }
            return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        func dateDirectory(_ url: URL, digits: Int) -> Bool {
            let name = url.lastPathComponent
            return name.count == digits && name.utf8.allSatisfy { (48...57).contains($0) }
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        for year in children(root) where dateDirectory(year, digits: 4) {
            for month in children(year) where dateDirectory(month, digits: 2) {
                for day in children(month) where dateDirectory(day, digits: 2) {
                    for file in children(day) where file.lastPathComponent.hasPrefix("rollout-") && file.lastPathComponent.lowercased().hasSuffix(suffix) {
                        if let path = validatedPath(file.path, sessionId: sessionId) { return path }
                    }
                }
            }
        }
        return nil
    }

    /// Hook paths must still identify the requested session in their metadata.
    /// Only the bounded first record is read; conversation contents are not scanned.
    public static func validatedPath(_ path: String, sessionId: String) -> String? {
        guard path.hasPrefix("/"), let expected = UUID(uuidString: sessionId),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 64 * 1024), let newline = bytes.firstIndex(of: 10),
              let record = try? JSONDecoder().decode(JSONValue.self, from: bytes[..<newline]),
              record["type"]?.stringValue == "session_meta", let metadata = record["payload"],
              let id = metadata["id"]?.stringValue ?? metadata["session_id"]?.stringValue,
              UUID(uuidString: id) == expected, let cwd = metadata["cwd"]?.stringValue, cwd.hasPrefix("/") else { return nil }
        // Subagent sessions are not public conversation feeds.
        if case .object? = metadata["source"] { return nil }
        return path
    }
}
