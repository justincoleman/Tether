import Foundation
import TetherProtocol

public enum PermissionDecision: Sendable, Equatable {
    case allow
    /// Allow and apply Claude Code's own `permission_suggestions` so it stops asking.
    case allowAlways
    /// Allow with a changed tool input, e.g. the answer to a question.
    case allowWithInput(JSONValue)
    case deny(message: String?)
    /// Return no decision, so Claude Code shows its normal prompt in the terminal.
    case askInTerminal
}

public struct PendingPermission: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sessionId: SessionID
    public var paneId: PaneID?
    public var toolName: String
    public var toolInput: JSONValue?
    public var suggestions: JSONValue?
    public var createdAt: Date

    public init(id: UUID = UUID(), sessionId: SessionID, paneId: PaneID?, toolName: String,
                toolInput: JSONValue?, suggestions: JSONValue?, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.paneId = paneId
        self.toolName = toolName
        self.toolInput = toolInput
        self.suggestions = suggestions
        self.createdAt = createdAt
    }

    public var canAllowAlways: Bool {
        if case .array(let a) = suggestions { return !a.isEmpty }
        return false
    }
}

/// Parks a hook request until someone answers it: the Mac UI, a phone
/// (phase 5), or the timeout. First answer wins; later ones return false.
public actor PermissionBroker {
    private var pending: [UUID: PendingPermission] = [:]
    private var waiters: [UUID: CheckedContinuation<PermissionDecision, Never>] = [:]
    private var early: [UUID: PermissionDecision] = [:]

    public init() {}

    public func register(_ request: PendingPermission) {
        pending[request.id] = request
    }

    public func pendingRequests() -> [PendingPermission] {
        pending.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Waits for a decision on a registered request. Falls back to
    /// `.askInTerminal` after `timeout`.
    public func wait(for id: UUID, timeout: Duration) async -> PermissionDecision {
        if let decided = early.removeValue(forKey: id) { return decided }
        guard pending[id] != nil else { return .askInTerminal }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { _ = await self.resolve(id, .askInTerminal) }
        }
        let decision = await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }
        timer.cancel()
        return decision
    }

    /// Returns false if the request was already answered or never existed.
    @discardableResult
    public func resolve(_ id: UUID, _ decision: PermissionDecision) -> Bool {
        guard pending.removeValue(forKey: id) != nil else { return false }
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: decision)
        } else {
            early[id] = decision
        }
        return true
    }

    /// Releases every request from a pane that went away.
    public func cancelAll(paneId: PaneID) -> [UUID] {
        let ids = pending.values.filter { $0.paneId == paneId }.map(\.id)
        for id in ids { resolve(id, .askInTerminal) }
        return ids
    }
}
