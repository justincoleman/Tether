import Foundation
import TetherProtocol

/// Finds a session's transcript by id, without relying on how Claude Code
/// encodes the project directory name.
public enum TranscriptLocator {
    public static var defaultProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// `<projects>/<any dir>/<sessionId>.jsonl`, or nil if it does not exist yet
    /// (a new session writes its file on the first message).
    public static func find(sessionId: SessionID,
                            in projects: URL = defaultProjectsDirectory) -> String? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects.path) else { return nil }
        for dir in dirs {
            let candidate = projects.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl").path
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
