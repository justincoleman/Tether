import Foundation
import TetherProtocol

/// Owns the session table and the sidebar state machine. Pure logic, no I/O.
/// Transitions are documented in docs/HOOKS.md; keep the two in sync.
public actor SessionRegistry {
    public private(set) var sessions: [SessionID: Session] = [:]
    private var paneToSession: [PaneID: SessionID] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func session(forPane paneId: PaneID) -> Session? {
        paneToSession[paneId].flatMap { sessions[$0] }
    }

    public func allSessions() -> [Session] {
        sessions.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Applies a hook and returns the session as it stands afterwards.
    @discardableResult
    public func apply(_ hook: HookPayload, paneId: PaneID?) -> Session {
        let t = now()
        if hook.hookEventName == .sessionEnd, let paneId, let current = paneToSession[paneId],
           current != hook.sessionId {
            // A late SessionEnd from the session this pane already replaced (/clear,
            // a resume that forks): the pane has moved on, so it must not be pulled
            // back to the old id and marked ended. Returned without a pane.
            var ended = sessions.removeValue(forKey: hook.sessionId) ?? Session(
                id: hook.sessionId, paneId: nil, cwd: hook.cwd,
                transcriptPath: hook.transcriptPath, startedAt: t, lastEventAt: t)
            ended.paneId = nil
            ended.state = .detached
            ended.attention = nil
            ended.lastEventAt = t
            return ended
        }
        var session = sessions[hook.sessionId] ?? Session(
            id: hook.sessionId, paneId: paneId, cwd: hook.cwd,
            transcriptPath: hook.transcriptPath, startedAt: t, lastEventAt: t)
        session.lastEventAt = t
        if let path = hook.transcriptPath { session.transcriptPath = path }
        if let mode = hook.permissionMode { session.permissionMode = mode }
        if let paneId {
            // /clear and resume give the same pane a new session id; drop the old one.
            if let previous = paneToSession[paneId], previous != hook.sessionId {
                sessions[previous] = nil
            }
            session.paneId = paneId
            paneToSession[paneId] = hook.sessionId
        }
        let next = Self.transition(from: session.state, attention: session.attention, on: hook)
        session.state = next.state
        session.attention = next.attention
        sessions[hook.sessionId] = session
        return session
    }

    /// The state a hook leads to, and for `needsInput` why: a permission or
    /// dialog must be answered in place, a question is answered by typing.
    static func transition(from current: SessionState, attention: AttentionReason?,
                           on hook: HookPayload) -> (state: SessionState, attention: AttentionReason?) {
        func stay() -> (SessionState, AttentionReason?) { (current, attention) }
        switch hook.hookEventName {
        case .sessionStart:
            return (.idle, nil)
        case .userPromptSubmit:
            return (.working, nil)
        case .permissionRequest:
            return (.needsInput, .permission)
        case .postToolUse:
            // A tool ran, so any permission prompt was answered and Claude is moving.
            if current == .detached { return stay() }
            return (.working, nil)
        case .notification:
            guard let type = hook.notificationType else { return stay() }
            switch type {
            case "permission_prompt": return (.needsInput, .permission)
            case "agent_needs_input": return (.needsInput, .question)
            case "elicitation_dialog", "elicitation_url_dialog": return (.needsInput, .dialog)
            // Stop does not fire on a user interrupt; idle_prompt is the recovery signal.
            case "idle_prompt" where current == .working: return (.idle, nil)
            default: return stay()
            }
        case .stop:
            // Heuristic: a turn that ends on a question is waiting on the user.
            if let text = hook.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.hasSuffix("?") {
                return (.needsInput, .question)
            }
            return (.done, nil)
        case .stopFailure:
            return (.error, nil)
        case .sessionEnd:
            return (.detached, nil)
        }
    }

    /// Set state directly, e.g. after a permission decision made in Tether.
    @discardableResult
    public func setState(_ state: SessionState, for sessionId: SessionID) -> Session? {
        guard var s = sessions[sessionId] else { return nil }
        s.state = state
        s.attention = nil
        s.lastEventAt = now()
        sessions[sessionId] = s
        return s
    }

    /// The user looked at the tab: a green "done" badge has served its purpose.
    @discardableResult
    public func paneFocused(_ paneId: PaneID) -> Session? {
        guard let id = paneToSession[paneId], var s = sessions[id] else { return nil }
        guard s.state == .done else { return nil }
        s.state = .idle
        sessions[id] = s
        return s
    }

    /// The pty's child process exited.
    @discardableResult
    public func paneExited(_ paneId: PaneID) -> Session? {
        guard let id = paneToSession[paneId], var s = sessions[id] else { return nil }
        s.state = .detached
        s.attention = nil
        s.lastEventAt = now()
        sessions[id] = s
        paneToSession[paneId] = nil
        return s
    }
}
