import Foundation
import TetherProtocol

/// One HTTP/2 request to APNs, without transport or credentials.
public struct APNsRequest: Sendable, Equatable {
    /// `alert` or `liveactivity`.
    public var pushType: String
    /// Live Activity pushes go to `<bundleId>.push-type.liveactivity`.
    public var topicSuffix: String
    /// 10 delivers now; 5 lets the system batch (Live Activity updates).
    public var priority: Int
    /// Replaces an earlier notification with the same id (≤ 64 bytes).
    public var collapseId: String?
    public var body: Data

    public func topic(bundleId: String) -> String { bundleId + topicSuffix }

    public static func host(sandbox: Bool) -> String {
        sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com"
    }

    /// Request headers, minus `authorization`.
    public func headers(bundleId: String) -> [String: String] {
        var h = [
            "apns-push-type": pushType,
            "apns-topic": topic(bundleId: bundleId),
            "apns-priority": String(priority),
        ]
        if let collapseId { h["apns-collapse-id"] = collapseId }
        return h
    }
}

/// The provider token APNs expects: an ES256 JWT with the key id in the
/// header and the team id and issue time as claims. Signing is injected so
/// this stays testable on Linux; the Mac signs with CryptoKit.
public enum APNsJWT {
    /// APNs rejects tokens older than an hour and throttles refreshing more
    /// often than every 20 minutes.
    public static let lifetime: TimeInterval = 50 * 60

    public static func make(teamId: String, keyId: String, issuedAt: Date,
                            sign: (Data) throws -> Data) rethrows -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyId)"}"#
        let claims = #"{"iss":"\#(teamId)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#
        let input = base64url(Data(header.utf8)) + "." + base64url(Data(claims.utf8))
        let signature = try sign(Data(input.utf8))
        return input + "." + base64url(signature)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A notification the Mac wants a phone to show.
public enum PushIntent: Equatable, Sendable {
    case permission(PermissionRequested, projectName: String)
    case question(paneId: PaneID, projectName: String, text: String, agent: AgentKind = .claude)
    case dialog(paneId: PaneID, projectName: String, agent: AgentKind = .claude)
    case finished(paneId: PaneID, projectName: String, text: String, agent: AgentKind = .claude)
    case failed(paneId: PaneID, projectName: String, text: String, agent: AgentKind = .claude)
    case shortcutFailed(paneId: PaneID, projectName: String, title: String, exitCode: Int32, output: String)
    case activityStart(LiveActivityAttributes, LiveActivityContent)
    case activityUpdate(paneId: PaneID, LiveActivityContent)
    case activityEnd(paneId: PaneID, LiveActivityContent)
}

/// Decides which pushes a tab's state change deserves. Pure, so the rules
/// are tested; `CompanionHub` delivers them.
public enum PushPlanner {
    public struct Change: Sendable {
        public var macId: UUID
        public var paneId: PaneID
        public var projectName: String
        public var title: String
        public var previous: SessionState?
        public var state: SessionState
        public var attention: AttentionReason?
        /// Latest message, one line.
        public var preview: String?
        public var steps: Int
        public var startedAt: Date
        public var agent: AgentKind

        public init(macId: UUID, paneId: PaneID, projectName: String, title: String,
                    previous: SessionState?, state: SessionState, attention: AttentionReason?,
                    preview: String?, steps: Int, startedAt: Date, agent: AgentKind = .claude) {
            self.macId = macId
            self.paneId = paneId
            self.projectName = projectName
            self.title = title
            self.previous = previous
            self.state = state
            self.attention = attention
            self.preview = preview
            self.steps = steps
            self.startedAt = startedAt
            self.agent = agent
        }

        var content: LiveActivityContent {
            LiveActivityContent(state: state.rawValue, detail: preview ?? "", steps: steps,
                                startedAt: startedAt.timeIntervalSince1970)
        }
    }

    public static func intents(for change: Change) -> [PushIntent] {
        let c = change
        guard c.previous != c.state else { return [] }
        var out: [PushIntent] = []
        let text = c.preview ?? ""

        // Alerts. Permission prompts come from the PermissionRequest itself,
        // which carries the command.
        switch c.state {
        case .needsInput where c.attention == .question:
            out.append(.question(paneId: c.paneId, projectName: c.projectName, text: text, agent: c.agent))
        case .needsInput where c.attention == .dialog:
            out.append(.dialog(paneId: c.paneId, projectName: c.projectName, agent: c.agent))
        case .done where c.previous == .working:
            out.append(.finished(paneId: c.paneId, projectName: c.projectName, text: text, agent: c.agent))
        case .error:
            out.append(.failed(paneId: c.paneId, projectName: c.projectName, text: text, agent: c.agent))
        default:
            break
        }

        // Live Activity: one per working stretch, kept through permission
        // prompts and questions, ended when the turn is over.
        let active: Set<SessionState> = [.working, .needsInput]
        let wasActive = c.previous.map(active.contains) ?? false
        if c.state == .working, !wasActive {
            let attributes = LiveActivityAttributes(macId: c.macId.uuidString, paneId: c.paneId.uuidString,
                                                    projectName: c.projectName, title: c.title)
            out.append(.activityStart(attributes, c.content))
        } else if active.contains(c.state) {
            out.append(.activityUpdate(paneId: c.paneId, c.content))
        } else if wasActive {
            out.append(.activityEnd(paneId: c.paneId, c.content))
        }
        return out
    }
}

/// APNs JSON for each intent.
public enum PushPayload {
    public static func request(for intent: PushIntent, macId: UUID, now: Date = Date()) -> APNsRequest {
        switch intent {
        case .permission(let p, let project):
            var info: [String: Any] = [PushKeys.macId: macId.uuidString, PushKeys.requestId: p.id.uuidString]
            if let pane = p.paneId { info[PushKeys.paneId] = pane.uuidString }
            return alert(title: "\(project): \(p.heading)",
                         body: p.detail.isEmpty ? p.toolName : p.detail,
                         category: PushKeys.permissionCategory, timeSensitive: true,
                         thread: p.paneId?.uuidString, collapseId: nil, info: info)
        case .question(let pane, let project, let text, let agent):
            return alert(title: "\(project): \(agent.displayName) asked you something", body: text.isEmpty ? "Open to answer." : text,
                         category: PushKeys.replyCategory, timeSensitive: true, thread: pane.uuidString,
                         collapseId: "q-" + pane.uuidString,
                         info: [PushKeys.macId: macId.uuidString, PushKeys.paneId: pane.uuidString])
        case .dialog(let pane, let project, let agent):
            return alert(title: "\(project): \(agent.displayName) is waiting", body: "A prompt on the Mac needs an answer.",
                         category: nil, timeSensitive: true, thread: pane.uuidString,
                         collapseId: "q-" + pane.uuidString,
                         info: [PushKeys.macId: macId.uuidString, PushKeys.paneId: pane.uuidString])
        case .finished(let pane, let project, let text, let agent):
            return alert(title: "\(project): \(agent.displayName) finished", body: text.isEmpty ? "Done." : text,
                         category: PushKeys.replyCategory, timeSensitive: false, thread: pane.uuidString,
                         collapseId: "s-" + pane.uuidString,
                         info: [PushKeys.macId: macId.uuidString, PushKeys.paneId: pane.uuidString])
        case .failed(let pane, let project, let text, let agent):
            return alert(title: "\(project): \(agent.displayName) hit an error", body: text.isEmpty ? "Open to see what happened." : text,
                         category: nil, timeSensitive: false, thread: pane.uuidString,
                         collapseId: "s-" + pane.uuidString,
                         info: [PushKeys.macId: macId.uuidString, PushKeys.paneId: pane.uuidString])
        case .shortcutFailed(let pane, let project, let title, let code, let output):
            return alert(title: "\(project): \(title) failed (exit \(code))", body: String(output.suffix(400)),
                         category: nil, timeSensitive: false, thread: pane.uuidString,
                         collapseId: "s-" + pane.uuidString,
                         info: [PushKeys.macId: macId.uuidString, PushKeys.paneId: pane.uuidString])
        case .activityStart(let attributes, let content):
            return activity(event: "start", content: content, now: now, extra: [
                "attributes-type": LiveActivityAttributes.typeName,
                "attributes": jsonObject(attributes),
                "alert": ["title": "\(attributes.projectName): Agent is working", "body": attributes.title],
            ])
        case .activityUpdate(_, let content):
            // A stale date marks the card stale if the Mac goes quiet.
            return activity(event: "update", content: content, now: now,
                            extra: ["stale-date": Int(now.timeIntervalSince1970) + 30 * 60], priority: 5)
        case .activityEnd(_, let content):
            return activity(event: "end", content: content, now: now,
                            extra: ["dismissal-date": Int(now.timeIntervalSince1970) + 15 * 60])
        }
    }

    static func alert(title: String, body: String, category: String?, timeSensitive: Bool,
                      thread: String?, collapseId: String?, info: [String: Any]) -> APNsRequest {
        var aps: [String: Any] = [
            "alert": ["title": title, "body": String(body.prefix(400))],
            "sound": "default",
            "interruption-level": timeSensitive ? "time-sensitive" : "active",
        ]
        if let category { aps["category"] = category }
        if let thread { aps["thread-id"] = thread }
        var payload = info
        payload["aps"] = aps
        return APNsRequest(pushType: "alert", topicSuffix: "", priority: 10, collapseId: collapseId,
                           body: encode(payload))
    }

    static func activity(event: String, content: LiveActivityContent, now: Date,
                         extra: [String: Any], priority: Int = 10) -> APNsRequest {
        var aps: [String: Any] = [
            "event": event,
            "timestamp": Int(now.timeIntervalSince1970),
            "content-state": jsonObject(content),
        ]
        for (k, v) in extra { aps[k] = v }
        return APNsRequest(pushType: "liveactivity", topicSuffix: ".push-type.liveactivity",
                           priority: priority, collapseId: nil, body: encode(["aps": aps]))
    }

    static func jsonObject<T: Encodable>(_ value: T) -> Any {
        // Default JSONEncoder: the same key names ActivityKit's decoder expects.
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
