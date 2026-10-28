import Foundation
import TetherProtocol

/// Owns the session table and the sidebar state machine. Pure logic, no I/O.
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

    /// Applies a hook and returns the session's state afterwards, or nil if the hook
    /// is one that carries no state transition (e.g. `PostToolUse`).
    @discardableResult
    public func apply(_ hook: HookPayload, paneId: PaneID?) -> SessionState? {
        let t = now()
        var session = sessions[hook.sessionId] ?? Session(
            id: hook.sessionId, paneId: paneId, cwd: hook.cwd,
            transcriptPath: hook.transcriptPath, startedAt: t, lastEventAt: t)
        session.lastEventAt = t
        if let paneId {
            session.paneId = paneId
            paneToSession[paneId] = hook.sessionId
        }
        if let path = hook.transcriptPath { session.transcriptPath = path }

        switch hook.hookEventName {
        case .sessionStart:
            session.state = .idle
        case .userPromptSubmit:
            session.state = .working
        case .permissionRequest:
            session.state = .needsInput
        case .notification:
            if let type = hook.notificationType,
               HookPayload.needsInputNotifications.contains(type) {
                session.state = .needsInput
            }
        case .stop:
            session.state = .done
        case .stopFailure:
            session.state = .error
        case .sessionEnd:
            session.state = .detached
        case .postToolUse:
            // Content, not state. The transcript tailer handles it.
            sessions[hook.sessionId] = session
            return nil
        }
        sessions[hook.sessionId] = session
        return session.state
    }

    /// The user looked at the tab: a green "done" badge has served its purpose.
    @discardableResult
    public func paneFocused(_ paneId: PaneID) -> SessionState? {
        guard let id = paneToSession[paneId], var s = sessions[id] else { return nil }
        if s.state == .done { s.state = .idle }
        sessions[id] = s
        return s.state
    }

    /// The pty's child process exited.
    @discardableResult
    public func paneExited(_ paneId: PaneID) -> SessionState? {
        guard let id = paneToSession[paneId], var s = sessions[id] else { return nil }
        s.state = .detached
        s.lastEventAt = now()
        sessions[id] = s
        paneToSession[paneId] = nil
        return s.state
    }
}
