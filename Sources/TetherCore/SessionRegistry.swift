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
        var session = sessions[hook.sessionId] ?? Session(
            id: hook.sessionId, paneId: paneId, cwd: hook.cwd,
            transcriptPath: hook.transcriptPath, startedAt: t, lastEventAt: t)
        session.lastEventAt = t
        if let path = hook.transcriptPath { session.transcriptPath = path }
        if let paneId {
            // /clear and resume give the same pane a new session id; drop the old one.
            if let previous = paneToSession[paneId], previous != hook.sessionId {
                sessions[previous] = nil
            }
            session.paneId = paneId
            paneToSession[paneId] = hook.sessionId
        }
        session.state = Self.nextState(from: session.state, on: hook)
        sessions[hook.sessionId] = session
        return session
    }

    static func nextState(from current: SessionState, on hook: HookPayload) -> SessionState {
        switch hook.hookEventName {
        case .sessionStart:
            return .idle
        case .userPromptSubmit:
            return .working
        case .permissionRequest:
            return .needsInput
        case .postToolUse:
            // A tool ran, so any permission prompt was answered and Claude is moving.
            return current == .detached ? current : .working
        case .notification:
            guard let type = hook.notificationType else { return current }
            if HookPayload.needsInputNotifications.contains(type) { return .needsInput }
            // Stop does not fire on a user interrupt; idle_prompt is the recovery signal.
            if type == "idle_prompt", current == .working { return .idle }
            return current
        case .stop:
            // Heuristic: a turn that ends on a question is waiting on the user.
            if let text = hook.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.hasSuffix("?") {
                return .needsInput
            }
            return .done
        case .stopFailure:
            return .error
        case .sessionEnd:
            return .detached
        }
    }

    /// Set state directly, e.g. after a permission decision made in Tether.
    @discardableResult
    public func setState(_ state: SessionState, for sessionId: SessionID) -> Session? {
        guard var s = sessions[sessionId] else { return nil }
        s.state = state
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
        s.lastEventAt = now()
        sessions[id] = s
        paneToSession[paneId] = nil
        return s
    }
}
