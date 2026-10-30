import Foundation
import TetherProtocol

/// Public conversation and tool records in Codex rollout JSONL files.
/// Private reasoning, agent messages and duplicated event messages are excluded.
public enum CodexTranscriptParser {
    public static func events(fromLine line: String) -> [MirrorEvent] {
        guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let payload = record["payload"], let kind = payload["type"]?.stringValue else { return [] }
        let id = payload["id"]?.stringValue ?? stableID(line)
        let at = timestamp(record["timestamp"]?.stringValue)
        switch record["type"]?.stringValue {
        case "response_item":
            switch kind {
            case "message":
                guard let role = payload["role"]?.stringValue, role == "user" || role == "assistant",
                      payload["phase"]?.stringValue != "analysis",
                      payload["recipient"]?.stringValue == nil || payload["recipient"]?.stringValue == "all",
                      case .array(let content)? = payload["content"] else { return [] }
                let text = content.compactMap { block -> String? in
                    guard ["input_text", "output_text", "text"].contains(block["type"]?.stringValue ?? "") else { return nil }
                    return block["text"]?.stringValue
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return [] }
                if role == "user" {
                    let injected = ["<environment_context>", "<user_instructions>", "<permissions instructions>", "<turn_aborted>", "# AGENTS.md instructions", "<agent-message", "<subagent_notification>"]
                    guard !injected.contains(where: text.hasPrefix) else { return [] }
                    return [.userText(id: id, text: text, at: at)]
                }
                return [.assistantText(id: id, text: text, at: at)]
            case "function_call", "custom_tool_call":
                guard let call = payload["call_id"]?.stringValue, let name = payload["name"]?.stringValue else { return [] }
                let raw = payload[kind == "function_call" ? "arguments" : "input"]
                let input = raw?.stringValue.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? raw
                let isCommand = ["exec_command", "shell_command", "shell"].contains(name)
                let summary = isCommand ? (input?["cmd"]?.stringValue ?? input?["command"]?.stringValue ?? "") : PermissionSummary.describe(toolName: name, input: input).detail
                return [.toolUse(id: call, name: isCommand ? "Bash" : name, summary: String(summary.prefix(500)), at: at)]
            case "function_call_output", "custom_tool_call_output":
                guard let call = payload["call_id"]?.stringValue else { return [] }
                let output = payload["output"]
                let text = output?.stringValue ?? output?.compactString() ?? ""
                let failurePrefix = text.lowercased().hasPrefix("failed") || text.lowercased().hasPrefix("error:")
                let nonzeroExit = text.range(of: #"(?:Process exited with code |Exit code: )-?[1-9][0-9]*\b"#, options: .regularExpression) != nil
                let exitCode = integer(output?["exit_code"]) ?? 0
                return [.toolResult(id: id, toolUseId: call, summary: TranscriptParser.resultTail(.string(text)), isError: failurePrefix || nonzeroExit || exitCode != 0, at: at)]
            default: return []
            }
        case "event_msg":
            if kind == "turn_aborted" { return [.notice(id: id, text: "Interrupted", at: at)] }
            guard kind == "token_count", let info = payload["info"],
                  let input = integer(info["last_token_usage"]?["input_tokens"]), input >= 0,
                  let window = integer(info["model_context_window"]), window > 0 else { return [] }
            // Codex input_tokens already includes cached_input_tokens.
            return [.usage(ContextUsage(inputTokens: input, contextWindow: window), at: at)]
        default: return []
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite,
              number > Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func timestamp(_ value: String?) -> Date {
        guard let value else { return Date(timeIntervalSince1970: 0) }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value)) ?? Date(timeIntervalSince1970: 0)
    }

    /// FNV-1a is deterministic across processes, unlike Swift's Hasher.
    private static func stableID(_ line: String) -> String {
        let hash = line.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "codex-" + String(hash, radix: 16)
    }
}
