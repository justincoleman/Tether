import Foundation

/// What a phone tells each Mac so the Mac can push to it directly (APNs,
/// token auth). Sent after every authentication and whenever a token changes.
public struct PushRegistration: Codable, Hashable, Sendable {
    /// APNs device token, hex.
    public var deviceToken: String
    /// ActivityKit push-to-start token for `LiveActivityAttributes`, hex.
    public var pushToStartToken: String?
    /// The phone app's bundle id: the APNs topic.
    public var bundleId: String
    /// Development builds get sandbox tokens (api.sandbox.push.apple.com).
    public var sandbox: Bool

    public init(deviceToken: String, pushToStartToken: String?, bundleId: String, sandbox: Bool) {
        self.deviceToken = deviceToken
        self.pushToStartToken = pushToStartToken
        self.bundleId = bundleId
        self.sandbox = sandbox
    }
}

/// Static data of a session's Live Activity. The phone conforms it to
/// ActivityKit's `ActivityAttributes`; the Mac encodes it in push-to-start
/// payloads, whose `attributes-type` is this type's name. Field names are the
/// JSON keys, so renaming one breaks pushes to installed phones.
public struct LiveActivityAttributes: Codable, Hashable, Sendable {
    public var macId: String
    public var paneId: String
    public var projectName: String
    public var title: String

    public init(macId: String, paneId: String, projectName: String, title: String) {
        self.macId = macId
        self.paneId = paneId
        self.projectName = projectName
        self.title = title
    }

    public static let typeName = "LiveActivityAttributes"
}

/// The changing part of a Live Activity. No `Date` fields: ActivityKit
/// decodes content-state with a default JSONDecoder, whose date format the
/// Mac would have to mirror exactly. Times are Unix seconds.
public struct LiveActivityContent: Codable, Hashable, Sendable {
    /// `SessionState` raw value.
    public var state: String
    /// Latest message, one line.
    public var detail: String
    /// Tool steps in the current turn.
    public var steps: Int
    /// When this turn started working, Unix seconds.
    public var startedAt: Double

    public init(state: String, detail: String, steps: Int, startedAt: Double) {
        self.state = state
        self.detail = detail
        self.steps = steps
        self.startedAt = startedAt
    }
}

/// Identifiers shared by the Mac's push payloads and the phone's handlers.
public enum PushKeys {
    public static let permissionCategory = "TETHER_PERMISSION"
    public static let replyCategory = "TETHER_REPLY"
    public static let allowAction = "TETHER_ALLOW"
    public static let denyAction = "TETHER_DENY"
    public static let replyAction = "TETHER_REPLY_TEXT"
    public static let macId = "macId"
    public static let paneId = "paneId"
    public static let requestId = "requestId"
}
