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

    public func count(for pane: PaneID) -> Int {
        items[pane]?.count ?? 0
    }

    /// Everything queued for the pane as one message, oldest first. Several
    /// queued messages go in together so Claude sees them as one turn.
    public mutating func drain(for pane: PaneID) -> String? {
        guard let queued = items.removeValue(forKey: pane), !queued.isEmpty else { return nil }
        return queued.joined(separator: "\n\n")
    }

    public mutating func clear(pane: PaneID) {
        items[pane] = nil
    }
}

/// When it is safe to type a message into a Claude tab.
public enum PromptGate {
    /// Typing into a permission prompt or a dialog would answer it by accident,
    /// and typing while Claude works interrupts the turn.
    public static func canSend(state: SessionState, attention: AttentionReason?) -> Bool {
        switch state {
        case .idle, .done, .error:
            true
        case .needsInput:
            attention == .question
        case .working, .detached:
            false
        }
    }
}
