import Foundation

/// Decides which file-system events are worth a git refresh. Build output and
/// git's own housekeeping would otherwise refresh the panel constantly.
public enum GitEventFilter {
    /// Directories whose contents change during builds and are almost always
    /// gitignored. A repository that tracks one of these will not see live
    /// updates for it; the periodic refresh still catches them.
    static let noisyDirectories: Set<String> = [
        ".build", "build", "node_modules", "DerivedData", "Pods",
        ".swiftpm", "__pycache__", ".gradle", ".next", ".cache",
    ]

    /// Files under `.git` that mean the branch, index or refs changed.
    static let meaningfulGitEntries: Set<String> = [
        "HEAD", "index", "refs", "packed-refs", "MERGE_HEAD", "CHERRY_PICK_HEAD",
        "REBASE_HEAD", "ORIG_HEAD",
    ]

    /// `root` and event paths should both be real paths (FSEvents reports
    /// symlinks resolved).
    public static func isRelevant(eventPath: String, root: String) -> Bool {
        var relative = eventPath
        if eventPath.hasPrefix(root) {
            relative = String(eventPath.dropFirst(root.count))
        }
        let components = relative.split(separator: "/").map(String.init)
        guard let first = components.first else { return true }

        if first == ".git" {
            guard components.count >= 2 else { return true }
            if components.last?.hasSuffix(".lock") == true { return false }
            return meaningfulGitEntries.contains(components[1])
        }
        if components.last == ".DS_Store" { return false }
        if components.dropLast().contains(where: { noisyDirectories.contains($0) }) { return false }
        // The directory itself (an event on "build") is noise too.
        if let last = components.last, noisyDirectories.contains(last) { return false }
        return true
    }
}
