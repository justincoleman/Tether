import Foundation
import TetherProtocol

public struct StatusEntry: Sendable, Hashable {
    public var path: String
    /// Set for renames and copies.
    public var originalPath: String?
    /// Staged state: `.` unchanged, `M` `A` `D` `R` `C` `T`, or `?` untracked.
    public var staged: Character
    /// Working tree state, same letters.
    public var unstaged: Character
    public var isUnmerged: Bool

    public var isUntracked: Bool { staged == "?" }

    /// Best guess at the kind when there is no base to diff against.
    public var approximateKind: FileChangeKind {
        if isUnmerged { return .conflicted }
        if isUntracked { return .untracked }
        if staged == "A" { return .added }
        if staged == "D" || unstaged == "D" { return .deleted }
        if staged == "R" { return .renamed }
        if staged == "C" { return .copied }
        return .modified
    }
}

/// Parsed `git status --porcelain=v2 --branch -z`.
public struct GitStatus: Sendable, Equatable {
    /// Full commit id of HEAD; nil in a repository with no commits yet.
    public var oid: String?
    /// Nil when HEAD is detached.
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var entries: [StatusEntry]

    public var isDetached: Bool { branch == nil && oid != nil }

    public static func parse(_ data: Data) -> GitStatus {
        var status = GitStatus(oid: nil, branch: nil, upstream: nil, ahead: 0, behind: 0, entries: [])
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            if record.hasPrefix("# ") {
                status.applyHeader(record)
                continue
            }
            guard let type = record.first else { continue }
            switch type {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let f = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard f.count == 9 else { continue }
                status.entries.append(entry(xy: f[1], path: String(f[8]), original: nil, unmerged: false))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, then the original path
                let f = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard f.count == 10 else { continue }
                var original: String?
                if i < records.count { original = records[i]; i += 1 }
                status.entries.append(entry(xy: f[1], path: String(f[9]), original: original, unmerged: false))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let f = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard f.count == 11 else { continue }
                status.entries.append(entry(xy: f[1], path: String(f[10]), original: nil, unmerged: true))
            case "?":
                status.entries.append(StatusEntry(path: String(record.dropFirst(2)), originalPath: nil,
                                                  staged: "?", unstaged: "?", isUnmerged: false))
            default:
                continue // "!" ignored files
            }
        }
        return status
    }

    private static func entry(xy: Substring, path: String, original: String?, unmerged: Bool) -> StatusEntry {
        let chars = Array(xy)
        return StatusEntry(path: path, originalPath: original,
                           staged: chars.first ?? ".", unstaged: chars.dropFirst().first ?? ".",
                           isUnmerged: unmerged)
    }

    private mutating func applyHeader(_ record: String) {
        let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let value = String(parts[1])
        switch parts[0] {
        case "branch.oid":
            oid = value == "(initial)" ? nil : value
        case "branch.head":
            branch = value == "(detached)" ? nil : value
        case "branch.upstream":
            upstream = value
        case "branch.ab":
            // "+3 -1"
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }
}
