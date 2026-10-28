import Foundation

/// One tool call and, once it arrives, its result.
public struct ToolStep: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var result: String?
    public var isError: Bool
    public var at: Date

    public init(id: String, name: String, summary: String, result: String? = nil,
                isError: Bool = false, at: Date) {
        self.id = id
        self.name = name
        self.summary = summary
        self.result = result
        self.isError = isError
        self.at = at
    }

    public var isRunning: Bool { result == nil }
}

/// What the chat mirror renders. Consecutive tool calls collapse into one
/// `steps` row, like "10 steps · ran 5, used 5".
public enum TranscriptItem: Hashable, Sendable, Identifiable {
    case user(id: String, text: String, at: Date)
    case assistant(id: String, text: String, at: Date)
    case steps(id: String, steps: [ToolStep])
    case notice(id: String, text: String, at: Date)

    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _, _), .notice(let id, _, _): id
        case .steps(let id, _): id
        }
    }
}

/// Folds MirrorEvents into display items. Shared by the Mac mirror and the
/// phone so both group steps the same way. Applying an event twice is a no-op.
public struct TranscriptModel: Sendable, Equatable {
    public private(set) var items: [TranscriptItem] = []
    public private(set) var usage: ContextUsage?
    private var stepIndex: [String: Int] = [:]
    private var seen: Set<String> = []

    public init() {}

    public mutating func apply(_ events: [MirrorEvent]) {
        for event in events { apply(event) }
    }

    public mutating func apply(_ event: MirrorEvent) {
        if let key = event.dedupeKey {
            guard seen.insert(key).inserted else { return }
        }
        switch event {
        case .userText(let id, let text, let at):
            items.append(.user(id: id, text: text, at: at))
        case .assistantText(let id, let text, let at):
            items.append(.assistant(id: id, text: text, at: at))
        case .notice(let id, let text, let at):
            items.append(.notice(id: id, text: text, at: at))
        case .usage(let u, _):
            usage = u
        case .toolUse(let id, let name, let summary, let at):
            let step = ToolStep(id: id, name: name, summary: summary, at: at)
            if case .steps(let groupId, var steps)? = items.last {
                steps.append(step)
                items[items.count - 1] = .steps(id: groupId, steps: steps)
            } else {
                items.append(.steps(id: "steps-\(id)", steps: [step]))
            }
            stepIndex[id] = items.count - 1
        case .toolResult(_, let toolUseId, let summary, let isError, _):
            guard let index = stepIndex[toolUseId],
                  case .steps(let groupId, var steps) = items[index],
                  let s = steps.firstIndex(where: { $0.id == toolUseId }) else { return }
            steps[s].result = summary
            steps[s].isError = isError
            items[index] = .steps(id: groupId, steps: steps)
        }
    }
}

extension TranscriptModel {
    /// The latest user or assistant message on one line, at most `limit`
    /// characters, markdown markers and extra whitespace removed.
    public func preview(limit: Int = 140) -> String? {
        for item in items.reversed() {
            let text: String
            switch item {
            case .user(_, let t, _): text = "You: " + t
            case .assistant(_, let t, _): text = t
            case .steps, .notice: continue
            }
            let words = text
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "*", with: "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "#" || $0 == ">" || $0 == "-" } }
            guard !words.isEmpty else { continue }
            let line = words.joined(separator: " ")
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return nil
    }
}

extension MirrorEvent {
    var dedupeKey: String? {
        switch self {
        case .userText(let id, _, _), .assistantText(let id, _, _), .notice(let id, _, _): "t:\(id)"
        case .toolUse(let id, _, _, _): "u:\(id)"
        case .toolResult(let id, _, _, _, _): "r:\(id)"
        case .usage: nil
        }
    }
}
