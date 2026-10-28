import Foundation
import TetherProtocol

/// The subset of a Claude Code hook's JSON body that Tether consumes.
/// Unknown fields are ignored. See docs/HOOKS.md for the shapes.
public struct HookPayload: Codable, Sendable, Hashable {
    public enum EventName: String, Codable, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case notification = "Notification"
        case sessionEnd = "SessionEnd"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
    }

    public var sessionId: SessionID
    public var cwd: String
    public var transcriptPath: String?
    public var hookEventName: EventName
    /// SessionStart: startup, resume, clear, compact, fork.
    public var source: String?
    /// UserPromptSubmit.
    public var prompt: String?
    /// Notification.
    public var notificationType: String?
    public var message: String?
    public var title: String?
    /// Tool events and PermissionRequest.
    public var toolName: String?
    public var toolInput: JSONValue?
    public var permissionSuggestions: JSONValue?
    /// Stop: Claude's final text for the turn. StopFailure: the API error text.
    public var lastAssistantMessage: String?
    /// StopFailure: error type, e.g. "rate_limit".
    public var error: String?
    /// Most events: "default", "acceptEdits", "plan", "auto", "dontAsk" or
    /// "bypassPermissions". No hook fires when only the mode changes.
    public var permissionMode: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case hookEventName = "hook_event_name"
        case source, prompt, message, title, error
        case notificationType = "notification_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
        case lastAssistantMessage = "last_assistant_message"
        case permissionMode = "permission_mode"
    }

    public init(sessionId: SessionID, cwd: String, transcriptPath: String? = nil,
                hookEventName: EventName, source: String? = nil, prompt: String? = nil,
                notificationType: String? = nil, message: String? = nil, title: String? = nil,
                toolName: String? = nil, toolInput: JSONValue? = nil,
                permissionSuggestions: JSONValue? = nil,
                lastAssistantMessage: String? = nil, error: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.hookEventName = hookEventName
        self.source = source
        self.prompt = prompt
        self.notificationType = notificationType
        self.message = message
        self.title = title
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionSuggestions = permissionSuggestions
        self.lastAssistantMessage = lastAssistantMessage
        self.error = error
    }
}
