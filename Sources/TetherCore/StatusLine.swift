import Foundation
import TetherProtocol

/// Claude Code's status line input: the only place it reports the model, the
/// session cost and plan limits. Tether's relay posts it here (see
/// `HookSettings.statusLine`); field names are in docs/HOOKS.md.
public struct StatusLineReport: Sendable, Hashable {
    public var sessionId: SessionID
    public var status: SessionStatus
    /// Nil when Claude Code doesn't report limits (API key, or before the
    /// first response of the session).
    public var limits: UsageLimits?

    public init(sessionId: SessionID, status: SessionStatus, limits: UsageLimits?) {
        self.sessionId = sessionId
        self.status = status
        self.limits = limits
    }

    public init?(json data: Data) {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let sessionId = root["session_id"]?.stringValue, !sessionId.isEmpty
        else { return nil }
        self.sessionId = sessionId
        status = SessionStatus(modelId: root["model"]?["id"]?.stringValue,
                               modelName: root["model"]?["display_name"]?.stringValue,
                               costUSD: Self.number(root["cost"]?["total_cost_usd"]))
        let fiveHour = Self.limit(root["rate_limits"]?["five_hour"])
        let sevenDay = Self.limit(root["rate_limits"]?["seven_day"])
        limits = fiveHour == nil && sevenDay == nil ? nil : UsageLimits(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    static func number(_ value: JSONValue?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    static func limit(_ value: JSONValue?) -> UsageLimit? {
        guard let used = number(value?["used_percentage"]) else { return nil }
        var resetsAt: Date?
        if let seconds = number(value?["resets_at"]) {
            resetsAt = Date(timeIntervalSince1970: seconds)
        } else if let text = value?["resets_at"]?.stringValue {
            resetsAt = ISO8601DateFormatter().date(from: text)
        }
        return UsageLimit(usedPercent: used, resetsAt: resetsAt)
    }
}

/// The text typed into a tab to switch its model from the phone. Only alias
/// and model-id characters pass, so the phone can't type anything else.
public enum ModelCommand {
    static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_[]")

    public static func text(for model: String) -> String? {
        let name = model.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return "/model \(name)"
    }
}
