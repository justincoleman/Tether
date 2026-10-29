import Foundation

/// Whether Claude Code will ask "Do you trust the files in this folder?" before
/// starting. Claude records the answer in `~/.claude.json`; Tether only reads
/// it to know a tab is parked at that question, and never writes it.
public enum FolderTrust {
    public static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// True when `path` or one of its parents has been accepted. An unreadable
    /// config counts as trusted, so Tether never invents a prompt it can't confirm.
    public static func isTrusted(_ path: String, config: Data?) -> Bool {
        guard let config, let json = try? JSONDecoder().decode(JSONValue.self, from: config),
              case .object(let projects)? = json["projects"] else { return true }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for start in Set([path, resolved]) {
            for folder in ancestors(of: start) {
                if projects[folder]?["hasTrustDialogAccepted"] == .bool(true) { return true }
            }
        }
        return false
    }

    /// The folder and each parent, nearest first, without the root.
    static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/", !url.path.isEmpty {
            out.append(url.path)
            url.deleteLastPathComponent()
        }
        return out
    }
}
