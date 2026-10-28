import Foundation

/// A single rendered unit of a session transcript, as shown in the chat mirror.
public enum MirrorEvent: Codable, Hashable, Sendable {
    case userText(id: String, text: String, at: Date)
    case assistantText(id: String, text: String, at: Date)
    case toolUse(id: String, name: String, summary: String, at: Date)
    case toolResult(id: String, toolUseId: String, summary: String, isError: Bool, at: Date)
    case usage(ContextUsage, at: Date)
    /// A muted system line, e.g. "Interrupted".
    case notice(id: String, text: String, at: Date)
}

public struct Hello: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var appVersion: String
    public var deviceName: String

    public init(protocolVersion: Int = ProtocolVersion.current, appVersion: String, deviceName: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.deviceName = deviceName
    }
}

/// A project as the phone lists it.
public struct ProjectSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectID
    public var name: String
    /// Branch label as the Mac sidebar shows it, e.g. "main".
    public var branch: String?

    public init(id: ProjectID, name: String, branch: String?) {
        self.id = id
        self.name = name
        self.branch = branch
    }
}

/// One Claude tab on the Mac. Keyed by pane because a tab keeps its place in
/// the list while `/clear` gives it a new Claude session.
public struct SessionSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: PaneID
    public var projectId: ProjectID
    /// Nil until the tab's Claude session is known.
    public var sessionId: SessionID?
    public var title: String
    public var state: SessionState
    public var attention: AttentionReason?
    /// Messages held on the Mac until Claude can take them.
    public var queued: Int
    /// The latest message in the conversation, shortened, so tabs are
    /// recognisable in a list. See `TranscriptModel.preview`.
    public var preview: String?
    /// Permission mode from hooks, e.g. "auto". Nil until a hook reports it.
    public var permissionMode: String?

    public init(id: PaneID, projectId: ProjectID, sessionId: SessionID?, title: String,
                state: SessionState, attention: AttentionReason?, queued: Int, preview: String? = nil,
                permissionMode: String? = nil) {
        self.id = id
        self.projectId = projectId
        self.sessionId = sessionId
        self.title = title
        self.state = state
        self.attention = attention
        self.queued = queued
        self.preview = preview
        self.permissionMode = permissionMode
    }
}

public struct PermissionRequested: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var paneId: PaneID?
    public var sessionId: SessionID
    public var toolName: String
    /// "Run a command", "Edit a file", ...
    public var title: String
    /// The command, path or input, already formatted for display.
    public var detail: String

    public init(id: UUID, paneId: PaneID?, sessionId: SessionID, toolName: String,
                title: String, detail: String) {
        self.id = id
        self.paneId = paneId
        self.sessionId = sessionId
        self.toolName = toolName
        self.title = title
        self.detail = detail
    }
}

/// The Mac's whole state for the phone. Small, so it is resent in full on
/// every change instead of diffed.
public struct Snapshot: Codable, Hashable, Sendable {
    public var macName: String
    public var projects: [ProjectSummary]
    public var sessions: [SessionSummary]
    public var permissions: [PermissionRequested]

    public init(macName: String, projects: [ProjectSummary], sessions: [SessionSummary],
                permissions: [PermissionRequested]) {
        self.macName = macName
        self.projects = projects
        self.sessions = sessions
        self.permissions = permissions
    }
}

/// Mac → phone. See docs/PROTOCOL.md.
public enum MacMessage: Codable, Sendable {
    case hello(Hello)
    /// Pairing succeeded. The phone keeps `token` for every later connection.
    case paired(macId: UUID, macName: String, token: String)
    case authenticated(macId: UUID, macName: String)
    /// The Mac closes the connection after this.
    case authFailed(reason: String)
    case snapshot(Snapshot)
    /// Transcript events for a subscribed session. `reset` replaces what the
    /// phone holds (sent first after subscribing); otherwise append.
    case transcript(sessionId: SessionID, events: [MirrorEvent], reset: Bool)
    /// Answer to `sendMessage`: "sent", "queued" or "failed".
    case sendResult(paneId: PaneID, outcome: String)
    /// Answer to `startSession`: the new tab, or why it couldn't start.
    case startResult(requestId: UUID, paneId: PaneID?, error: String?)
    case error(message: String)
}

/// Phone → Mac. See docs/PROTOCOL.md.
public enum PhoneMessage: Codable, Sendable {
    case hello(Hello)
    /// First connection: the one-time code from the Mac's QR.
    case pair(code: String)
    /// Every later connection.
    case authenticate(token: String)
    /// Stream this session's transcript; nil stops streaming.
    case subscribe(sessionId: SessionID?)
    case sendMessage(paneId: PaneID, text: String)
    case permissionDecision(requestId: UUID, allow: Bool)
    /// Opens a Claude tab in the project, on a new worktree branch when
    /// `branch` is set, starting on `prompt` when it isn't empty, in
    /// `permissionMode` when set (otherwise the user's configured default).
    case startSession(requestId: UUID, projectId: ProjectID, branch: String?, prompt: String,
                      permissionMode: String?)
    /// Sidebar order, all of the Mac's project ids.
    case reorderProjects(ids: [ProjectID])
    // Phase 6b.
    case registerPush(deviceToken: String, liveActivityPushToStartToken: String?)
}

/// Shared encoder/decoder configuration so both sides agree on date format.
public enum WireCodec {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
