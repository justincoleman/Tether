import Foundation
import TetherProtocol

/// A note on selected lines of a diff: "change this part like so".
public struct ReviewComment: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: String
    /// The selected diff lines, in order.
    public var lines: [DiffLine]
    public var instruction: String

    public init(id: UUID = UUID(), path: String, lines: [DiffLine], instruction: String) {
        self.id = id
        self.path = path
        self.lines = lines
        self.instruction = instruction
    }

    public var hasRemovedLines: Bool { lines.contains { $0.kind == .delete } }
    public var hasCurrentLines: Bool { lines.contains { $0.kind != .delete } }

    /// Line span in the current version of the file.
    public var newRange: ClosedRange<Int>? {
        Self.span(lines.filter { $0.kind != .delete }.compactMap(\.newNumber))
    }

    /// Line span in the previous version, for removed lines.
    public var oldRange: ClosedRange<Int>? {
        Self.span(lines.filter { $0.kind == .delete }.compactMap(\.oldNumber))
    }

    /// "lines 28–33", "removed lines 10–12 (previous version)", and so on.
    public var rangeDescription: String {
        switch (hasCurrentLines, hasRemovedLines) {
        case (true, false):
            return Self.describe(newRange)
        case (false, true):
            return "removed " + Self.describe(oldRange) + " (previous version)"
        default:
            return Self.describe(newRange) + ", including removed lines (shown as a diff)"
        }
    }

    /// Short form for chips: "a.swift · lines 28–33".
    public var shortLabel: String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return "\(name) · \(rangeDescription.components(separatedBy: ",").first ?? rangeDescription)"
    }

    static func span(_ numbers: [Int]) -> ClosedRange<Int>? {
        guard let lo = numbers.min(), let hi = numbers.max() else { return nil }
        return lo...hi
    }

    static func describe(_ range: ClosedRange<Int>?) -> String {
        guard let range else { return "the selected lines" }
        return range.lowerBound == range.upperBound
            ? "line \(range.lowerBound)"
            : "lines \(range.lowerBound)–\(range.upperBound)"
    }
}

/// Turns review comments into the message Claude receives.
public enum ReviewMessage {
    public static func compose(_ comments: [ReviewComment]) -> String {
        let comments = comments.filter { !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch comments.count {
        case 0:
            return ""
        case 1:
            return block(for: comments[0], number: nil)
        default:
            let body = comments.enumerated().map { block(for: $1, number: $0 + 1) }.joined(separator: "\n\n")
            return "Please address these review comments on the current changes:\n\n" + body
        }
    }

    static func block(for comment: ReviewComment, number: Int?) -> String {
        let prefix = number.map { "\($0). " } ?? ""
        let header = "\(prefix)In `\(comment.path)`, \(comment.rangeDescription):"
        let mixed = comment.hasRemovedLines && comment.hasCurrentLines
        let snippet = mixed
            ? comment.lines.map { marker($0.kind) + $0.text }.joined(separator: "\n")
            : comment.lines.map(\.text).joined(separator: "\n")
        let language = mixed ? "diff" : CodeLanguage.hint(forPath: comment.path)
        let marks = fence(for: snippet)
        let instruction = comment.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(header)\n\n\(marks)\(language)\n\(snippet)\n\(marks)\n\n\(instruction)"
    }

    private static func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .add: "+"
        case .delete: "-"
        case .context: " "
        }
    }

    /// A backtick fence longer than any run of backticks in the snippet, so
    /// code containing ``` cannot close it early.
    static func fence(for snippet: String) -> String {
        var longest = 0, current = 0
        for ch in snippet {
            if ch == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

enum CodeLanguage {
    static func hint(forPath path: String) -> String {
        let ext = path.split(separator: ".").last.map { $0.lowercased() } ?? ""
        let map: [String: String] = [
            "swift": "swift", "py": "python", "js": "javascript", "jsx": "jsx", "ts": "typescript",
            "tsx": "tsx", "json": "json", "md": "markdown", "yml": "yaml", "yaml": "yaml",
            "sh": "bash", "bash": "bash", "zsh": "bash", "rb": "ruby", "go": "go", "rs": "rust",
            "c": "c", "h": "c", "m": "objectivec", "mm": "objectivec", "cpp": "cpp", "hpp": "cpp",
            "java": "java", "kt": "kotlin", "html": "html", "css": "css", "sql": "sql",
            "toml": "toml", "xml": "xml", "plist": "xml",
        ]
        return map[ext] ?? ""
    }
}
