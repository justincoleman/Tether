import Foundation
import TetherProtocol

/// Messages waiting for a Claude session that is not ready to receive them.
public struct PromptQueue: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        var text: String
        /// Sent by itself and ahead of the rest: the user chose Send Now.
        var solo = false
    }

    private var items: [PaneID: [Entry]] = [:]

    public init() {}

    public mutating func enqueue(_ text: String, for pane: PaneID) {
        guard let clean = Self.clean(text) else { return }
        items[pane, default: []].append(Entry(text: clean))
    }

    /// The messages waiting for the pane, oldest first, as they will be typed.
    public func texts(for pane: PaneID) -> [String] {
        items[pane]?.map(\.text) ?? []
    }

    public func count(for pane: PaneID) -> Int {
        items[pane]?.count ?? 0
    }

    /// The next message for the pane, oldest first. Queued messages go in
    /// together so Claude sees them as one turn, but a slash command or a
    /// Send Now message always goes alone: text joined to a command would
    /// become its arguments.
    public mutating func drain(for pane: PaneID) -> String? {
        guard var queued = items[pane], !queued.isEmpty else { return nil }
        let alone = { (e: Entry) in e.solo || Self.isCommand(e.text) }
        let take = alone(queued[0]) ? 1 : (queued.firstIndex(where: alone) ?? queued.count)
        let batch = queued.prefix(take).map(\.text).joined(separator: "\n\n")
        queued.removeFirst(take)
        items[pane] = queued.isEmpty ? nil : queued
        return batch
    }

    /// Returns a drained message to the front, when it could not be typed.
    public mutating func putBack(_ text: String, for pane: PaneID, solo: Bool = false) {
        items[pane, default: []].insert(Entry(text: text, solo: solo), at: 0)
    }

    /// Whether the next message the pane would send is a slash command.
    public func nextIsCommand(for pane: PaneID) -> Bool {
        items[pane]?.first.map { Self.isCommand($0.text) } ?? false
    }

    /// Whether the next message the pane would send was marked Send Now.
    public func nextIsSolo(for pane: PaneID) -> Bool {
        items[pane]?.first?.solo ?? false
    }

    /// Changes a waiting message. `expected` guards against the queue having
    /// moved under the user: nothing changes unless that text is still at
    /// `index`. Blank text removes the message.
    @discardableResult
    public mutating func replace(at index: Int, expected: String, with text: String, for pane: PaneID) -> Bool {
        guard items[pane]?.indices.contains(index) == true, items[pane]?[index].text == expected else { return false }
        guard let clean = Self.clean(text) else { return remove(at: index, expected: expected, for: pane) }
        items[pane]?[index].text = clean
        return true
    }

    @discardableResult
    public mutating func remove(at index: Int, expected: String, for pane: PaneID) -> Bool {
        guard var queued = items[pane], queued.indices.contains(index), queued[index].text == expected else { return false }
        queued.remove(at: index)
        items[pane] = queued.isEmpty ? nil : queued
        return true
    }

    /// Moves a waiting message to the front, to be sent by itself as soon as
    /// Claude can take it. The others stay queued behind it.
    @discardableResult
    public mutating func sendNext(at index: Int, expected: String, for pane: PaneID) -> Bool {
        guard var queued = items[pane], queued.indices.contains(index), queued[index].text == expected else { return false }
        var entry = queued.remove(at: index)
        entry.solo = true
        queued.insert(entry, at: 0)
        items[pane] = queued
        return true
    }

    /// `/model opus` or `/clear`, but not a path like `/Users/me/App.swift`.
    public static func isCommand(_ text: String) -> Bool {
        text.range(of: #"^/[A-Za-z][\w:-]*(\s|$)"#, options: .regularExpression) != nil
    }

    public mutating func clear(pane: PaneID) {
        items[pane] = nil
    }

    private static func clean(_ text: String) -> String? {
        let clean = TerminalLaunch.promptText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
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
