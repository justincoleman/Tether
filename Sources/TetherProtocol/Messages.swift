import Foundation

/// A single rendered unit of a session transcript, as shown in the chat mirror.
public enum MirrorEvent: Codable, Hashable, Sendable {
    case userText(id: String, text: String, at: Date)
    case assistantText(id: String, text: String, at: Date)
    case toolUse(id: String, name: String, summary: String, at: Date)
    case toolResult(id: String, toolUseId: String, summary: String, isError: Bool, at: Date)
    case usage(ContextUsage, at: Date)
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

public struct Snapshot: Codable, Hashable, Sendable {
    public var projects: [Project]
    public var worktrees: [Worktree]
    public var sessions: [Session]

    public init(projects: [Project], worktrees: [Worktree], sessions: [Session]) {
        self.projects = projects
        self.worktrees = worktrees
        self.sessions = sessions
    }
}

public struct PermissionRequested: Codable, Hashable, Sendable {
    public var requestId: UUID
    public var sessionId: SessionID
    public var toolName: String
    public var summary: String
    public var detail: String?

    public init(requestId: UUID = UUID(), sessionId: SessionID, toolName: String, summary: String, detail: String? = nil) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
    }
}

/// Mac → phone.
public enum MacMessage: Codable, Sendable {
    case hello(Hello)
    case snapshot(Snapshot)
    case sessionEvent(sessionId: SessionID, event: MirrorEvent)
    case sessionState(sessionId: SessionID, state: SessionState)
    case permissionRequested(PermissionRequested)
    case permissionResolved(requestId: UUID, resolvedBy: String, allowed: Bool)
    case messageQueued(sessionId: SessionID, text: String)
    case error(message: String)
}

/// Phone → Mac.
public enum PhoneMessage: Codable, Sendable {
    case hello(Hello)
    case sendMessage(sessionId: SessionID, text: String)
    case startSession(projectId: ProjectID, branch: String?, prompt: String)
    case permissionDecision(requestId: UUID, allow: Bool, reason: String?)
    case reorderProjects(ids: [ProjectID])
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
