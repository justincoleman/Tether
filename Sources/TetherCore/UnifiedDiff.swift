import Foundation
import TetherProtocol

/// Parses `git diff` output into hunks with real line numbers.
public enum UnifiedDiff {
    public static func parse(_ text: String, maxLines: Int = 5000) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileDiff?
        var hunk: DiffHunk?
        var oldRemaining = 0, newRemaining = 0
        var oldNumber = 0, newNumber = 0
        var emitted = 0

        func closeHunk() {
            if let h = hunk { file?.hunks.append(h) }
            hunk = nil
            oldRemaining = 0
            newRemaining = 0
        }
        func closeFile() {
            closeHunk()
            if let f = file { files.append(f) }
            file = nil
        }
        func append(_ line: DiffLine) {
            guard emitted < maxLines else { file?.truncated = true; return }
            emitted += 1
            hunk?.lines.append(line)
        }
        func markNoNewline() {
            guard var h = hunk, !h.lines.isEmpty else { return }
            h.lines[h.lines.count - 1].noNewlineAtEnd = true
            hunk = h
        }

        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(piece)

            // Inside a hunk the counts say how many body lines remain, so a
            // line that merely looks like a header ("+++ x") stays content.
            if hunk != nil, oldRemaining > 0 || newRemaining > 0 {
                let marker = raw.first ?? " "
                var body = raw.isEmpty ? "" : String(raw.dropFirst())
                if body.hasSuffix("\r") { body.removeLast() }
                var consumed = true
                switch marker {
                case " ":
                    append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: body))
                    oldNumber += 1; newNumber += 1; oldRemaining -= 1; newRemaining -= 1
                case "-":
                    append(DiffLine(kind: .delete, oldNumber: oldNumber, newNumber: nil, text: body))
                    oldNumber += 1; oldRemaining -= 1
                case "+":
                    append(DiffLine(kind: .add, oldNumber: nil, newNumber: newNumber, text: body))
                    newNumber += 1; newRemaining -= 1
                case "\\":
                    markNoNewline()
                default:
                    consumed = false
                    closeHunk() // malformed; reread this line as a header
                }
                if consumed { continue }
            }

            if raw.hasPrefix("diff --git ") {
                closeFile()
                file = FileDiff(path: pathFromDiffLine(raw))
            } else if raw.hasPrefix("@@ ") {
                closeHunk()
                guard let h = parseHunkHeader(raw) else { continue }
                if file == nil { file = FileDiff(path: "") }
                hunk = DiffHunk(header: raw, oldStart: h.oldStart, oldCount: h.oldCount,
                                newStart: h.newStart, newCount: h.newCount)
                oldNumber = h.oldStart
                newNumber = h.newStart
                oldRemaining = h.oldCount
                newRemaining = h.newCount
            } else if raw.hasPrefix("\\") {
                markNoNewline()
            } else if file != nil {
                applyHeaderLine(raw, to: &file)
            }
        }
        closeFile()
        return files
    }

    // MARK: Headers

    private static func applyHeaderLine(_ raw: String, to file: inout FileDiff?) {
        if raw.hasPrefix("new file mode") {
            file?.kind = .added
        } else if raw.hasPrefix("deleted file mode") {
            file?.kind = .deleted
        } else if raw.hasPrefix("rename from ") {
            file?.oldPath = GitPath.unquote(String(raw.dropFirst("rename from ".count)))
            file?.kind = .renamed
        } else if raw.hasPrefix("rename to ") {
            file?.path = GitPath.unquote(String(raw.dropFirst("rename to ".count)))
        } else if raw.hasPrefix("copy from ") {
            file?.oldPath = GitPath.unquote(String(raw.dropFirst("copy from ".count)))
            file?.kind = .copied
        } else if raw.hasPrefix("copy to ") {
            file?.path = GitPath.unquote(String(raw.dropFirst("copy to ".count)))
        } else if raw.hasPrefix("Binary files ") || raw.hasPrefix("GIT binary patch") {
            file?.isBinary = true
        } else if raw.hasPrefix("--- ") {
            // After a rename the old path must not replace the new one.
            if file?.kind != .renamed, file?.kind != .copied,
               let path = headerPath(raw, prefix: "a/") { file?.path = path }
        } else if raw.hasPrefix("+++ ") {
            if let path = headerPath(raw, prefix: "b/") { file?.path = path }
        }
    }

    /// The path in a `--- a/x` or `+++ b/x` line; nil for /dev/null.
    private static func headerPath(_ line: String, prefix: String) -> String? {
        var value = String(line.dropFirst(4))
        // Git appends a tab to names containing spaces.
        while value.hasSuffix("\t") { value.removeLast() }
        if value == "/dev/null" { return nil }
        value = GitPath.unquote(value)
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    private static func pathFromDiffLine(_ line: String) -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        if let range = rest.range(of: " b/", options: .backwards) {
            return GitPath.unquote(String(rest[range.upperBound...]))
        }
        return rest
    }

    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let body = line.dropFirst(3) // after "@@ "
        guard let end = body.range(of: " @@") else { return nil }
        let ranges = body[..<end.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+") else { return nil }

        func parse(_ token: Substring) -> (Int, Int)? {
            let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) : 1
            guard let count else { return nil }
            return (start, count)
        }
        guard let old = parse(ranges[0]), let new = parse(ranges[1]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }
}

/// A diff for a file git does not track yet: every line is an addition.
public enum UntrackedDiff {
    public static let maxBytes = 1_000_000

    public static func make(path: String, data: Data, maxLines: Int = 5000) -> FileDiff {
        if data.prefix(8000).contains(0) {
            return FileDiff(path: path, kind: .untracked, isBinary: true)
        }
        if data.isEmpty { return FileDiff(path: path, kind: .untracked) }

        let text = String(decoding: data, as: UTF8.self)
        var pieces = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { pieces.removeLast() }

        var lines: [DiffLine] = []
        for (i, piece) in pieces.enumerated() {
            if lines.count >= maxLines { break }
            var body = piece
            if body.hasSuffix("\r") { body.removeLast() }
            lines.append(DiffLine(kind: .add, oldNumber: nil, newNumber: i + 1, text: body,
                                  noNewlineAtEnd: !endsWithNewline && i == pieces.count - 1))
        }
        let hunk = DiffHunk(header: "@@ -0,0 +1,\(pieces.count) @@", oldStart: 0, oldCount: 0,
                            newStart: 1, newCount: pieces.count, lines: lines)
        return FileDiff(path: path, kind: .untracked, truncated: lines.count < pieces.count, hunks: [hunk])
    }
}

enum GitPath {
    /// Undoes git's C-style quoting of unusual file names.
    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        let inner = Array(s.dropFirst().dropLast().utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < inner.count {
            let b = inner[i]
            guard b == 0x5C, i + 1 < inner.count else { bytes.append(b); i += 1; continue }
            let n = inner[i + 1]
            switch n {
            case UInt8(ascii: "n"): bytes.append(10); i += 2
            case UInt8(ascii: "t"): bytes.append(9); i += 2
            case UInt8(ascii: "r"): bytes.append(13); i += 2
            case UInt8(ascii: "a"): bytes.append(7); i += 2
            case UInt8(ascii: "b"): bytes.append(8); i += 2
            case UInt8(ascii: "f"): bytes.append(12); i += 2
            case UInt8(ascii: "v"): bytes.append(11); i += 2
            case 0x30...0x37:
                var value = 0, digits = 0, j = i + 1
                while j < inner.count, digits < 3, (0x30...0x37).contains(inner[j]) {
                    value = value * 8 + Int(inner[j] - 0x30)
                    j += 1; digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                i = j
            default:
                bytes.append(n); i += 2 // \\ and \" and anything else
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// `git diff --name-status -z` and `--numstat -z`.
public enum GitDiffSummary {
    public struct NameStatus: Sendable, Equatable {
        public var kind: FileChangeKind
        public var path: String
        public var oldPath: String?
    }

    public struct Numstat: Sendable, Equatable {
        public var path: String
        public var oldPath: String?
        /// Nil for binary files, which git reports as "-".
        public var additions: Int?
        public var deletions: Int?
    }

    public static func parseNameStatus(_ data: Data) -> [NameStatus] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var result: [NameStatus] = []
        var i = 0
        while i < records.count {
            let code = records[i]
            i += 1
            let isPair = code.hasPrefix("R") || code.hasPrefix("C")
            if isPair {
                guard i + 1 < records.count else { break }
                let old = records[i], new = records[i + 1]
                i += 2
                result.append(NameStatus(kind: code.hasPrefix("R") ? .renamed : .copied, path: new, oldPath: old))
            } else {
                guard i < records.count else { break }
                let path = records[i]
                i += 1
                result.append(NameStatus(kind: kind(for: code), path: path, oldPath: nil))
            }
        }
        return result
    }

    static func kind(for code: String) -> FileChangeKind {
        switch code.first {
        case "A": .added
        case "D": .deleted
        case "U": .conflicted
        default: .modified // M, T and anything new
        }
    }

    public static func parseNumstat(_ data: Data) -> [Numstat] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var result: [Numstat] = []
        var i = 0
        while i < records.count {
            let fields = records[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard fields.count == 3 else { continue }
            let additions = Int(fields[0]) // "-" for binary parses to nil
            let deletions = Int(fields[1])
            if fields[2].isEmpty {
                // Rename: the next two records are the old and new paths.
                guard i + 1 < records.count else { break }
                result.append(Numstat(path: records[i + 1], oldPath: records[i],
                                      additions: additions, deletions: deletions))
                i += 2
            } else {
                result.append(Numstat(path: String(fields[2]), oldPath: nil,
                                      additions: additions, deletions: deletions))
            }
        }
        return result
    }
}
