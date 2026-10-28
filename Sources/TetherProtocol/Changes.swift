import Foundation

/// What happened to a file relative to the base branch.
public enum FileChangeKind: String, Codable, Hashable, Sendable {
    case added, modified, deleted, renamed, copied, untracked, conflicted

    /// One-letter badge, as in `git status`.
    public var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .conflicted: "!"
        }
    }
}

public struct ChangedFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    /// Set for renames and copies.
    public var oldPath: String?
    public var kind: FileChangeKind
    /// Nil for binary files and for files too large to count.
    public var additions: Int?
    public var deletions: Int?
    public var isBinary: Bool
    /// Differs from what is committed (staged, unstaged or untracked), as
    /// opposed to changed only by commits on this branch.
    public var hasUncommittedChanges: Bool

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, kind: FileChangeKind,
                additions: Int? = nil, deletions: Int? = nil, isBinary: Bool = false,
                hasUncommittedChanges: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.hasUncommittedChanges = hasUncommittedChanges
    }

    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public var directory: String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }
}

public struct CommitInfo: Codable, Hashable, Sendable, Identifiable {
    public var hash: String
    public var shortHash: String
    public var author: String
    public var date: Date
    public var subject: String

    public var id: String { hash }

    public init(hash: String, shortHash: String, author: String, date: Date, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.date = date
        self.subject = subject
    }
}

/// One worktree's state against its base branch: the file list and commits
/// shown in the Changes panel.
public struct ChangesSnapshot: Codable, Hashable, Sendable {
    /// Nil when HEAD is detached or the repository has no commits yet.
    public var branch: String?
    public var commitShort: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// What the files are compared against, e.g. "origin/main". Nil means there
    /// is no base branch, so only uncommitted changes (against HEAD) are shown.
    public var baseRef: String?
    public var mergeBase: String?
    public var files: [ChangedFile]
    public var commits: [CommitInfo]
    public var capturedAt: Date

    public init(branch: String?, commitShort: String?, upstream: String?, ahead: Int, behind: Int,
                baseRef: String?, mergeBase: String?, files: [ChangedFile], commits: [CommitInfo],
                capturedAt: Date = Date()) {
        self.branch = branch
        self.commitShort = commitShort
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.baseRef = baseRef
        self.mergeBase = mergeBase
        self.files = files
        self.commits = commits
        self.capturedAt = capturedAt
    }

    public var additions: Int { files.compactMap(\.additions).reduce(0, +) }
    public var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }
    public var isClean: Bool { files.isEmpty && commits.isEmpty }

    public var branchLabel: String {
        if let branch { return branch }
        if let commitShort { return "detached @ \(commitShort)" }
        return "no commits yet"
    }

    /// Equality that ignores when the snapshot was taken, so a refresh that
    /// found nothing new does not look like a change.
    public func sameContent(as other: ChangesSnapshot) -> Bool {
        var copy = self
        copy.capturedAt = other.capturedAt
        return copy == other
    }
}

// MARK: Diffs

public enum DiffLineKind: String, Codable, Hashable, Sendable {
    case context, add, delete
}

public struct DiffLine: Codable, Hashable, Sendable {
    public var kind: DiffLineKind
    /// Line number in the old file; nil for added lines.
    public var oldNumber: Int?
    /// Line number in the new file; nil for deleted lines.
    public var newNumber: Int?
    public var text: String
    /// The file has no newline after this line (`\ No newline at end of file`).
    public var noNewlineAtEnd: Bool

    public init(kind: DiffLineKind, oldNumber: Int?, newNumber: Int?, text: String,
                noNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.noNewlineAtEnd = noNewlineAtEnd
    }
}

public struct DiffHunk: Codable, Hashable, Sendable {
    /// The full `@@ -a,b +c,d @@ section` line.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                lines: [DiffLine] = []) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Codable, Hashable, Sendable {
    public var path: String
    public var oldPath: String?
    public var kind: FileChangeKind
    public var isBinary: Bool
    /// More lines than the viewer will show were dropped.
    public var truncated: Bool
    public var hunks: [DiffHunk]

    public init(path: String, oldPath: String? = nil, kind: FileChangeKind = .modified,
                isBinary: Bool = false, truncated: Bool = false, hunks: [DiffHunk] = []) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.isBinary = isBinary
        self.truncated = truncated
        self.hunks = hunks
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .add }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .delete }.count } }
    public var isEmpty: Bool { hunks.isEmpty }
}
