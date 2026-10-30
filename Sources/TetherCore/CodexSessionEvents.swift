import Foundation
import TetherProtocol

/// Maps only public app-server items. Reasoning, hook prompts and collaboration
/// internals never become transcript content.
public enum CodexSessionEvents {
    public static func item(_ item: JSONValue, completed: Bool, at: Date = Date()) -> [MirrorEvent] {
        guard let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else { return [] }
        switch type {
        case "userMessage":
            guard completed, case .array(let content)? = item["content"] else { return [] }
            let text = content.compactMap { $0["type"] == .string("text") ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
            return text.isEmpty ? [] : [.userText(id: id, text: text, at: at)]
        case "agentMessage":
            guard completed, let text = item["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.assistantText(id: id, text: text, at: at)]
        case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch":
            let name: String
            let summary: String
            switch type {
            case "commandExecution": name = "Bash"; summary = item["command"]?.stringValue ?? "Command"
            case "fileChange":
                name = "Edit"
                if case .array(let changes)? = item["changes"] {
                    summary = changes.compactMap { $0["path"]?.stringValue }.joined(separator: ", ")
                } else { summary = "File changes" }
            case "webSearch": name = "WebSearch"; summary = item["query"]?.stringValue ?? "Search"
            default: name = item["tool"]?.stringValue ?? type; summary = item["arguments"]?.compactString() ?? name
            }
            guard completed else { return [.toolUse(id: id, name: name, summary: summary, at: at)] }
            let status = item["status"]?.stringValue
            let failed = status == "failed" || status == "declined" || item["success"] == .bool(false)
                || (item["exitCode"].map { $0 != .null && $0 != .number(0) } ?? false)
            let output = item["aggregatedOutput"]?.stringValue ?? item["result"]?.compactString()
                ?? item["error"]?.compactString() ?? status ?? "Completed"
            return [.toolResult(id: id + ":result", toolUseId: id,
                                summary: TranscriptParser.resultTail(.string(output)), isError: failed, at: at)]
        default: return []
        }
    }

    public static func history(_ thread: JSONValue, at: Date = Date()) -> [MirrorEvent] {
        guard case .array(let turns)? = thread["turns"] else { return [] }
        return turns.flatMap { turn -> [MirrorEvent] in
            guard case .array(let items)? = turn["items"] else { return [] }
            return items.flatMap { item($0, completed: false, at: at) + item($0, completed: true, at: at) }
        }
    }

    public struct UserInput: Sendable {
        public let questionID: String
        public let toolInput: JSONValue
    }

    public static func userInput(_ params: JSONValue) -> UserInput? {
        guard case .array(let questions)? = params["questions"], questions.count == 1,
              let q = questions.first, let id = q["id"]?.stringValue,
              let question = q["question"]?.stringValue, !question.isEmpty,
              q["isSecret"] != .bool(true) else { return nil }
        return UserInput(questionID: id, toolInput: .object(["questions": .array([.object([
            "header": q["header"] ?? .string(""), "question": .string(question),
            "multiSelect": .bool(false), "options": q["options"] == .null ? .array([]) : q["options"] ?? .array([])
        ])])]))
    }

    public static func answer(questionID: String, text: String) -> JSONValue {
        .object(["answers": .object([questionID: .object(["answers": .array([.string(text)])])])])
    }

    public static func approval(_ decision: PermissionDecision) -> JSONValue? {
        switch decision {
        case .allow: .object(["decision": .string("accept")])
        case .allowAlways: .object(["decision": .string("acceptForSession")])
        case .deny, .askInTerminal: .object(["decision": .string("decline")])
        case .allowWithInput: nil
        }
    }
}
