import Foundation
import TetherProtocol

/// Turns Claude Code transcript JSONL records into MirrorEvents.
///
/// The format is not a public contract. This parser follows records observed
/// from Claude Code 2.1.308 (see docs/TRANSCRIPT.md) and skips anything it does
/// not recognise rather than failing.
public enum TranscriptParser {
    public static func events(fromLine line: String) -> [MirrorEvent] {
        guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let type = record["type"]?.stringValue,
              type == "user" || type == "assistant",
              record["isSidechain"] != .bool(true), // subagent turns
              record["isMeta"] != .bool(true),      // injected context, not typed by anyone
              let uuid = record["uuid"]?.stringValue,
              let message = record["message"] else { return [] }
        let at = date(record["timestamp"]?.stringValue)
        return type == "assistant"
            ? assistantEvents(message, uuid: uuid, at: at)
            : userEvents(message["content"], uuid: uuid, at: at)
    }

    // MARK: Assistant

    static func assistantEvents(_ message: JSONValue, uuid: String, at: Date) -> [MirrorEvent] {
        var events: [MirrorEvent] = []
        if case .array(let blocks)? = message["content"] {
            for (i, block) in blocks.enumerated() {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue, !text.trimmed.isEmpty {
                        events.append(.assistantText(id: "\(uuid)#\(i)", text: text, at: at))
                    }
                case "tool_use":
                    guard let id = block["id"]?.stringValue else { continue }
                    let name = block["name"]?.stringValue ?? "tool"
                    let s = PermissionSummary.describe(toolName: name, input: block["input"])
                    events.append(.toolUse(id: id, name: name,
                                           summary: s.detail.isEmpty ? s.title : s.detail, at: at))
                default:
                    continue // thinking, redacted_thinking, server tool blocks
                }
            }
        }
        if let usage = message["usage"], let u = contextUsage(usage) {
            events.append(.usage(u, at: at))
        }
        return events
    }

    static func contextUsage(_ usage: JSONValue) -> ContextUsage? {
        func n(_ key: String) -> Int {
            if case .number(let v)? = usage[key] { return Int(v) }
            return 0
        }
        let total = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
        guard total > 0 else { return nil }
        // The transcript does not record the window size. Past 200k the session
        // must be on a 1M-context model.
        return ContextUsage(inputTokens: total, contextWindow: total > 200_000 ? 1_000_000 : 200_000)
    }

    // MARK: User

    static func userEvents(_ content: JSONValue?, uuid: String, at: Date) -> [MirrorEvent] {
        switch content {
        case .string(let text)?:
            return userText(text, id: "\(uuid)#0", at: at).map { [$0] } ?? []
        case .array(let blocks)?:
            var events: [MirrorEvent] = []
            var texts: [String] = []
            var images = 0
            for (i, block) in blocks.enumerated() {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue {
                        if let e = userText(text, id: "\(uuid)#\(i)", at: at) {
                            if case .userText(_, let t, _) = e { texts.append(t) } else { events.append(e) }
                        }
                    }
                case "image":
                    images += 1
                case "tool_result":
                    guard let toolUseId = block["tool_use_id"]?.stringValue else { continue }
                    events.append(.toolResult(id: "\(uuid)#\(i)", toolUseId: toolUseId,
                                              summary: resultSummary(block["content"]),
                                              isError: block["is_error"] == .bool(true), at: at))
                default:
                    continue
                }
            }
            if images > 0 { texts.append(images == 1 ? "[image]" : "[\(images) images]") }
            if !texts.isEmpty {
                events.insert(.userText(id: "\(uuid)#text", text: texts.joined(separator: "\n"), at: at), at: 0)
            }
            return events
        default:
            return []
        }
    }

    /// Classifies one piece of user text: a prompt, a slash command, an
    /// interrupt notice, or tool plumbing to hide.
    static func userText(_ raw: String, id: String, at: Date) -> MirrorEvent? {
        let text = raw.trimmed
        if text.isEmpty { return nil }
        if text.hasPrefix("[Request interrupted by user") {
            return .notice(id: id, text: "Interrupted", at: at)
        }
        if let name = between(text, "<command-name>", "</command-name>") {
            let args = between(text, "<command-args>", "</command-args>") ?? ""
            return .userText(id: id, text: args.isEmpty ? name : "\(name) \(args)", at: at)
        }
        // <local-command-stdout>, <local-command-caveat>, <system-reminder>, <bash-input>…
        if text.hasPrefix("<") { return nil }
        return .userText(id: id, text: text, at: at)
    }

    static func resultSummary(_ content: JSONValue?) -> String {
        var text = ""
        switch content {
        case .string(let s)?: text = s
        case .array(let items)?:
            text = items.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined(separator: "\n")
        default: break
        }
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(firstLine.prefix(300))
    }

    // MARK: Helpers

    static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex)
        else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmed
    }

    static func date(_ s: String?) -> Date {
        guard let s else { return Date() }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
        return Date()
    }
}

/// Reads a session transcript off the main thread and parses new records.
/// The first poll returns the whole history.
public actor TranscriptFeed {
    private var tail: TranscriptTail

    public init(path: String) {
        tail = TranscriptTail(path: path, fromStart: true)
    }

    public func poll() -> [MirrorEvent] {
        tail.readNewLines().flatMap(TranscriptParser.events(fromLine:))
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
