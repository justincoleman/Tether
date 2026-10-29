import Foundation
import TetherProtocol

/// Messages waiting for a Claude session that is not ready to receive them.
public struct PromptQueue: Sendable, Equatable {
    private var items: [PaneID: [String]] = [:]

    public init() {}

    public mutating func enqueue(_ text: String, for pane: PaneID) {
        let clean = TerminalLaunch.promptText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        items[pane, default: []].append(clean)
    }

    /// The messages waiting for the pane, oldest first, as they will be typed.
    public func texts(for pane: PaneID) -> [String] {
        items[pane] ?? []
    }

    public func count(for pane: PaneID) -> Int {
        items[pane]?.count ?? 0
    }

    /// The next message for the pane, oldest first. Queued messages go in
    /// together so Claude sees them as one turn, but a slash command always
    /// goes alone: text joined to it would become its arguments.
    public mutating func drain(for pane: PaneID) -> String? {
        guard var queued = items[pane], !queued.isEmpty else { return nil }
        let take = Self.isCommand(queued[0]) ? 1 : (queued.firstIndex(where: Self.isCommand) ?? queued.count)
        let batch = queued.prefix(take).joined(separator: "\n\n")
        queued.removeFirst(take)
        items[pane] = queued.isEmpty ? nil : queued
        return batch
    }

    /// Returns a drained message to the front, when it could not be typed.
    public mutating func putBack(_ text: String, for pane: PaneID) {
        items[pane, default: []].insert(text, at: 0)
    }

    /// Whether the next message the pane would send is a slash command.
    public func nextIsCommand(for pane: PaneID) -> Bool {
        items[pane]?.first.map(Self.isCommand) ?? false
    }

    /// `/model opus` or `/clear`, but not a path like `/Users/me/App.swift`.
    public static func isCommand(_ text: String) -> Bool {
        text.range(of: #"^/[A-Za-z][\w:-]*(\s|$)"#, options: .regularExpression) != nil
    }

    public mutating func clear(pane: PaneID) {
        items[pane] = nil
    }
}

/// When it is safe to type a message into a Claude tab.
public enum PromptGate {
    /// Typing into a permission prompt or a dialog would answer it by accident,
    /// and typing while Claude works interrupts the turn.
    /// A slash command never answers a question: it would be submitted as
    /// the answer instead of running.
    public static func canSend(state: SessionState, attention: AttentionReason?, command: Bool = false) -> Bool {
        switch state {
        case .idle, .done, .error:
            true
        case .needsInput:
            attention == .question && !command
        case .working, .detached:
            false
        }
    }
}
