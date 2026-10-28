import Foundation
import TetherProtocol

/// The subset of a Claude Code hook's JSON body that Tether consumes.
/// Unknown fields are ignored; see docs/HOOKS.md (phase 2) for captured examples.
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
    public var notificationType: String?
    public var toolName: String?
    public var lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case hookEventName = "hook_event_name"
        case notificationType = "notification_type"
        case toolName = "tool_name"
        case lastAssistantMessage = "last_assistant_message"
    }

    public init(sessionId: SessionID, cwd: String, transcriptPath: String? = nil,
                hookEventName: EventName, notificationType: String? = nil,
                toolName: String? = nil, lastAssistantMessage: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.hookEventName = hookEventName
        self.notificationType = notificationType
        self.toolName = toolName
        self.lastAssistantMessage = lastAssistantMessage
    }

    /// Notification types that mean "Claude is waiting on a human".
    static let needsInputNotifications: Set<String> = [
        "permission_prompt", "idle_prompt", "agent_needs_input",
        "elicitation_dialog", "elicitation_url_dialog",
    ]
}
