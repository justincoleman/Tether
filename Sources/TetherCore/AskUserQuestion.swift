import Foundation
import TetherProtocol

/// Claude Code's AskUserQuestion tool. Its PermissionRequest hook carries
/// `tool_input = {"questions":[{"header","question","multiSelect","options":[{"label","description"}]}]}`.
/// Allowing the call with `updatedInput.answers = {question: label}` answers
/// it without the terminal dialog.
public enum AskUserQuestion {
    public static let toolName = "AskUserQuestion"

    /// The card for a call with exactly one single-answer question and options.
    /// Anything else returns nil and keeps the ordinary permission card.
    public static func prompt(from input: JSONValue?) -> QuestionPrompt? {
        guard case .array(let questions)? = input?["questions"], questions.count == 1,
              let q = questions.first, q["multiSelect"] != .bool(true),
              let text = q["question"]?.stringValue, !text.isEmpty,
              case .array(let raw)? = q["options"] else { return nil }
        let options = raw.compactMap { option -> QuestionPrompt.Option? in
            guard let label = option["label"]?.stringValue, !label.isEmpty else { return nil }
            return .init(label: label, description: option["description"]?.stringValue ?? "")
        }
        guard !options.isEmpty else { return nil }
        return QuestionPrompt(header: q["header"]?.stringValue ?? "", question: text, options: options)
    }

    /// The tool input with the answer filled in, to return as `updatedInput`.
    public static func updatedInput(_ input: JSONValue?, question: String, answer: String) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if case .object(let o)? = input { object = o }
        object["answers"] = .object([question: .string(answer)])
        return .object(object)
    }
}
