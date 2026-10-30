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
              let type = record["type"]?.stringValue else { return [] }
        // A background task that finished while Claude was busy arrives as a
        // queued command instead of a user record.
        if type == "attachment", record["isSidechain"] != .bool(true),
           record["attachment"]?["type"]?.stringValue == "queued_command",
           let prompt = record["attachment"]?["prompt"]?.stringValue {
            return taskNotification(prompt, at: date(record["timestamp"]?.stringValue)) ?? []
        }
        guard type == "user" || type == "assistant",
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
        // Placeholders Claude Code writes itself, e.g. after an interrupt.
        // They never appear in the terminal, so the mirror hides them too.
        if message["model"]?.stringValue == "<synthetic>" { return [] }
        var events: [MirrorEvent] = []
        if case .array(let blocks)? = message["content"] {
            for (i, block) in blocks.enumerated() {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue, !text.trimmed.isEmpty,
                       text.trimmed != "No response requested." {
                        events.append(.assistantText(id: "\(uuid)#\(i)", text: text, at: at))
                    }
                case "tool_use":
                    guard let id = block["id"]?.stringValue else { continue }
                    let name = block["name"]?.stringValue ?? "tool"
                    let s = PermissionSummary.describe(toolName: name, input: block["input"])
                    events.append(.toolUse(id: id, name: name,
                                           summary: s.detail.isEmpty ? s.title : s.detail, at: at))
                    if let detail = toolDetail(id: id, name: name, input: block["input"], at: at) {
                        events.append(detail)
                    }
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
        return ContextUsage(inputTokens: total, contextWindow: ContextWindow.size(used: total, configuredModel: nil))
    }

    // MARK: User

    static func userEvents(_ content: JSONValue?, uuid: String, at: Date) -> [MirrorEvent] {
        switch content {
        case .string(let text)?:
            if let task = taskNotification(text, at: at) { return task }
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
                    // A background agent or command: the step keeps running until
                    // its task notification (below) brings the real result.
                    if startedInBackground(resultText(block["content"])) { continue }
                    events.append(.toolResult(id: "\(uuid)#\(i)", toolUseId: toolUseId,
                                              summary: resultTail(block["content"]),
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

    // MARK: Background tasks

    /// The tool result Claude Code writes when an Agent or Bash call goes to
    /// the background: internal plumbing, not the call's outcome.
    static func startedInBackground(_ result: String) -> Bool {
        result.hasPrefix("Async agent launched successfully") || result.hasPrefix("Command running in background with ID:")
    }

    /// `<task-notification>` text: a background agent or command finished.
    /// Becomes a quiet notice with Claude Code's own summary, plus the result
    /// of the step that started it. Ids come from the task and its status, so
    /// the same notification seen twice (queued, then delivered) shows once.
    static func taskNotification(_ raw: String, at: Date) -> [MirrorEvent]? {
        let text = raw.trimmed
        guard text.hasPrefix("<task-notification>") else { return nil }
        let summary = between(text, "<summary>", "</summary>") ?? "A background task finished"
        let status = between(text, "<status>", "</status>") ?? "completed"
        let taskId = between(text, "<task-id>", "</task-id>") ?? summary
        let id = "task-\(taskId)-\(status)"
        var events: [MirrorEvent] = [.notice(id: id, text: summary, at: at)]
        if let toolUseId = between(text, "<tool-use-id>", "</tool-use-id>") {
            let exit = summary.range(of: #"exit code (\d+)"#, options: .regularExpression)
                .flatMap { Int(summary[$0].dropFirst("exit code ".count)) }
            let failed = status != "completed" || (exit ?? 0) != 0
            events.append(.toolResult(id: id, toolUseId: toolUseId, summary: summary, isError: failed, at: at))
        }
        return events
    }

    static func resultText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let s)?: s
        case .array(let items)?:
            items.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined(separator: "\n")
        default: ""
        }
    }

    /// The last few non-empty lines of a tool result, so a command shows how it
    /// ended. Views that want one line take the first of these.
    static func resultTail(_ content: JSONValue?, lines: Int = 6) -> String {
        let text = resultText(content)
        let kept = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .map { String($0.prefix(300)) }
        return kept.joined(separator: "\n")
    }

    // MARK: Tool detail

    /// The file and changed lines of Read, Edit, MultiEdit, Write and NotebookEdit.
    static func toolDetail(id: String, name: String, input: JSONValue?, at: Date) -> MirrorEvent? {
        func str(_ key: String) -> String? { input?[key]?.stringValue }
        let file = str("file_path") ?? str("notebook_path")
        var removed: [String] = []
        var added: [String] = []
        switch name {
        case "Read", "Artifact":
            break
        case "Edit":
            (removed, added) = changedLines(old: str("old_string"), new: str("new_string"))
        case "MultiEdit":
            if case .array(let edits)? = input?["edits"] {
                for edit in edits {
                    let (r, a) = changedLines(old: edit["old_string"]?.stringValue, new: edit["new_string"]?.stringValue)
                    removed += r
                    added += a
                }
                removed = capped(removed)
                added = capped(added)
            }
        case "Write":
            added = capped(lines(str("content")))
        case "NotebookEdit":
            added = capped(lines(str("new_source")))
        default:
            return nil
        }
        guard file != nil else { return nil }
        return .toolDetail(toolUseId: id, file: file, removed: removed, added: added, at: at)
    }

    /// The lines that differ between an edit's old and new text: the common
    /// leading and trailing lines are dropped.
    static func changedLines(old: String?, new: String?) -> (removed: [String], added: [String]) {
        var a = lines(old)
        var b = lines(new)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        a.removeFirst(head)
        b.removeFirst(head)
        var tail = 0
        while tail < a.count, tail < b.count, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        a.removeLast(tail)
        b.removeLast(tail)
        return (capped(a), capped(b))
    }

    private static func lines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.prefix(200)) }
    }

    private static func capped(_ lines: [String], limit: Int = 24) -> [String] {
        lines.count > limit ? Array(lines.prefix(limit)) + ["… \(lines.count - limit) more lines"] : lines
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
    private let settingsFile: URL

    /// How much of a long transcript the first read takes, from the end. Claude
    /// Code sessions write hundreds of megabytes; the chat shows the recent part.
    public static let defaultWindowBytes: UInt64 = 2 * 1024 * 1024

    private var announcedGap = false

    public init(path: String, settingsFile: URL = ContextWindow.defaultSettingsFile,
                windowBytes: UInt64 = TranscriptFeed.defaultWindowBytes) {
        tail = TranscriptTail(path: path, lastBytes: windowBytes)
        self.settingsFile = settingsFile
    }

    /// The newest mode record seen since `takeMode` was last called.
    private var seenMode: String?

    /// The permission mode Claude last announced in the transcript, once.
    public func takeMode() -> String? {
        defer { seenMode = nil }
        return seenMode
    }

    public func poll() -> [MirrorEvent] {
        let lines = tail.readNewLines()
        if let mode = lines.compactMap(TranscriptSignals.permissionMode).last { seenMode = mode }
        var events = lines.flatMap(TranscriptParser.events(fromLine:))
        if tail.skippedEarlier, !announcedGap {
            announcedGap = true
            events.insert(.notice(id: "earlier-left-out", text: "Earlier messages are left out", at: Date()), at: 0)
        }
        guard events.contains(where: { if case .usage = $0 { true } else { false } }) else { return events }
        // Read on each batch with usage, so a /model switch shows on the next reply.
        let model = ContextWindow.configuredModel(settings: try? Data(contentsOf: settingsFile))
        return events.map { event in
            guard case .usage(var u, let at) = event else { return event }
            u.contextWindow = ContextWindow.size(used: u.inputTokens, configuredModel: model)
            return .usage(u, at: at)
        }
    }
}

/// The context window a session runs with. The transcript records the API
/// model id ("claude-opus-5-5") but not whether the 1M variant is in use, so
/// this reads the `model` setting Claude Code saves ("opus[1m]") instead.
public enum ContextWindow {
    public static let standard = 200_000
    public static let large = 1_000_000

    public static var defaultSettingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// 1M when the configured model asks for it, or once usage passes 200k
    /// (only a 1M session can get there).
    public static func size(used: Int, configuredModel: String?) -> Int {
        if let m = configuredModel?.lowercased(), m.hasSuffix("[1m]") { return large }
        return used > standard ? large : standard
    }

    /// The `model` value from a Claude Code settings file, if any.
    public static func configuredModel(settings: Data?) -> String? {
        guard let settings, let json = try? JSONDecoder().decode(JSONValue.self, from: settings) else { return nil }
        return json["model"]?.stringValue
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
