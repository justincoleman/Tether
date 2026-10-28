import Foundation

public typealias ProjectID = UUID
public typealias WorktreeID = UUID
public typealias PaneID = UUID
/// Claude Code's own session identifier, as delivered in hook payloads.
public typealias SessionID = String

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectID
    public var name: String
    public var path: String
    public var baseBranch: String
    public var order: Int
    public var remoteHost: String?

    public init(id: ProjectID = UUID(), name: String, path: String,
                baseBranch: String = "main", order: Int = 0, remoteHost: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.baseBranch = baseBranch
        self.order = order
        self.remoteHost = remoteHost
    }
}

public struct Worktree: Codable, Hashable, Sendable, Identifiable {
    public var id: WorktreeID
    public var projectId: ProjectID
    public var path: String
    public var branch: String
    public var isPrimary: Bool

    public init(id: WorktreeID = UUID(), projectId: ProjectID, path: String,
                branch: String, isPrimary: Bool) {
        self.id = id
        self.projectId = projectId
        self.path = path
        self.branch = branch
        self.isPrimary = isPrimary
    }
}

/// What the sidebar badge shows. See PLAN.md section 3.2 for the transitions.
public enum SessionState: String, Codable, Hashable, Sendable {
    case idle
    case working
    case needsInput
    case done
    case error
    case detached
}

/// Why a session is in `needsInput`. A permission prompt or dialog must be
/// answered in place; a question is answered by typing a message.
public enum AttentionReason: String, Codable, Hashable, Sendable {
    case permission
    case question
    case dialog
}

public struct ContextUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var contextWindow: Int

    public init(inputTokens: Int, contextWindow: Int) {
        self.inputTokens = inputTokens
        self.contextWindow = contextWindow
    }

    /// This usage measured against the window the status line reported, if any.
    public func reported(window: Int?) -> ContextUsage {
        guard let window, window > 0 else { return self }
        return ContextUsage(inputTokens: inputTokens, contextWindow: window)
    }
}

/// What Claude Code's status line reports about a session that hooks don't.
public struct SessionStatus: Codable, Hashable, Sendable {
    /// e.g. "claude-opus-5-5".
    public var modelId: String?
    /// e.g. "Opus 5.5".
    public var modelName: String?
    /// Estimated cost of the session so far, in US dollars.
    public var costUSD: Double?
    /// The context window Claude Code reports, e.g. 1_000_000. The transcript
    /// can't tell a 1M session from a 200k one, so this wins when present.
    public var contextWindow: Int?

    public init(modelId: String? = nil, modelName: String? = nil, costUSD: Double? = nil,
                contextWindow: Int? = nil) {
        self.modelId = modelId
        self.modelName = modelName
        self.costUSD = costUSD
        self.contextWindow = contextWindow
    }
}

/// One plan usage window.
public struct UsageLimit: Codable, Hashable, Sendable {
    /// 0...100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Plan usage limits. Shared by every session on the account; only reported
/// for Claude subscriptions, not API keys.
public struct UsageLimits: Codable, Hashable, Sendable {
    public var fiveHour: UsageLimit?
    public var sevenDay: UsageLimit?

    public init(fiveHour: UsageLimit?, sevenDay: UsageLimit?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct Session: Codable, Hashable, Sendable, Identifiable {
    public var id: SessionID
    public var worktreeId: WorktreeID?
    public var paneId: PaneID?
    public var cwd: String
    public var transcriptPath: String?
    public var state: SessionState
    public var startedAt: Date
    public var lastEventAt: Date
    public var usage: ContextUsage?
    /// Set only while `state == .needsInput`.
    public var attention: AttentionReason?
    /// Claude Code's permission mode as of the last hook that reported it.
    public var permissionMode: String?

    public init(id: SessionID, worktreeId: WorktreeID? = nil, paneId: PaneID? = nil,
                cwd: String, transcriptPath: String? = nil, state: SessionState = .idle,
                startedAt: Date, lastEventAt: Date, usage: ContextUsage? = nil,
                attention: AttentionReason? = nil) {
        self.id = id
        self.worktreeId = worktreeId
        self.paneId = paneId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.state = state
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.usage = usage
        self.attention = attention
    }
}
