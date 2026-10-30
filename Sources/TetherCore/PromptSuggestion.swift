import Foundation

/// Claude Code's suggested next prompt: the faint text it shows in an empty
/// prompt box after a turn. It is written nowhere else (not the transcript,
/// the status line or a hook; checked against 2.1.308), so this is the one
/// place Tether reads a pane's screen. See docs/TRANSCRIPT.md.
///
/// The prompt box is a rule line, `❯ <text>`, and another rule line. The
/// screen read carries no styling, so text the user typed into the terminal
/// looks the same: callers only ask when nothing can have been typed there.
public enum PromptSuggestion {
    static let promptMark: Character = "\u{276F}" // ❯

    /// The text in the lowest prompt box on screen, or nil when there is none
    /// or it's empty.
    public static func extract(viewport: String) -> String? {
        let lines = viewport.components(separatedBy: "\n")
        guard lines.count >= 3 else { return nil }
        for i in stride(from: lines.count - 2, through: 1, by: -1) {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.first == promptMark, isRule(lines[i - 1]), isRule(lines[i + 1]) else { continue }
            let text = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}")))
            return text.isEmpty ? nil : String(text.prefix(500))
        }
        return nil
    }

    /// A horizontal rule drawn with box-drawing dashes.
    static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 10 && trimmed.allSatisfy { $0 == "\u{2500}" || $0 == "\u{2501}" }
    }
}
