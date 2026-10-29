import Foundation
import TetherProtocol

public enum HookEvent: Sendable {
    /// A session's state may have changed.
    case session(Session)
    case permissionRequested(PendingPermission)
    case permissionResolved(id: UUID, decision: PermissionDecision)
    /// The tab's status line redrew: model, cost and plan limits.
    case status(paneId: PaneID, StatusLineReport)
}

/// Turns hook HTTP requests into registry updates and permission decisions.
/// Transport-free so it is tested without sockets.
public struct HookRouter: Sendable {
    let token: String
    let registry: SessionRegistry
    let broker: PermissionBroker
    let permissionTimeout: Duration
    let onEvent: @Sendable (HookEvent) async -> Void

    public init(token: String, registry: SessionRegistry, broker: PermissionBroker,
                permissionTimeout: Duration = .seconds(HookSettings.permissionTimeoutSeconds - 15),
                onEvent: @escaping @Sendable (HookEvent) async -> Void) {
        self.token = token
        self.registry = registry
        self.broker = broker
        self.permissionTimeout = permissionTimeout
        self.onEvent = onEvent
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "POST" else { return HTTPResponse(status: 405) }
        // Anything that isn't one of our sessions gets "no decision", so it can
        // never break a Claude session, only fail to be tracked.
        guard request.header(HookSettings.tokenHeader) == token else { return .empty }
        let paneId = request.header(HookSettings.paneHeader).flatMap(UUID.init(uuidString:))
        if request.path == HookSettings.statusPath {
            // Not a hook: the status line relay. Keyed by pane, like the tab.
            if let paneId, let report = StatusLineReport(json: request.body) {
                await onEvent(.status(paneId: paneId, report))
            }
            return .empty
        }
        guard let payload = try? JSONDecoder().decode(HookPayload.self, from: request.body)
        else { return .empty }

        switch request.path {
        case HookSettings.hookPath:
            let session = await registry.apply(payload, paneId: paneId)
            await onEvent(.session(session))
            return .empty

        case HookSettings.permissionPath:
            let session = await registry.apply(payload, paneId: paneId)
            await onEvent(.session(session))
            let pending = PendingPermission(sessionId: payload.sessionId, paneId: paneId,
                                            toolName: payload.toolName ?? "tool",
                                            toolInput: payload.toolInput,
                                            suggestions: payload.permissionSuggestions)
            await broker.register(pending)
            await onEvent(.permissionRequested(pending))
            let decision = await broker.wait(for: pending.id, timeout: permissionTimeout)
            await onEvent(.permissionResolved(id: pending.id, decision: decision))
            if decision != .askInTerminal,
               let updated = await registry.setState(.working, for: payload.sessionId) {
                await onEvent(.session(updated))
            }
            return Self.response(for: decision, suggestions: pending.suggestions)

        default:
            return HTTPResponse(status: 404)
        }
    }

    /// The PermissionRequest hook output. `.askInTerminal` returns no decision.
    public static func response(for decision: PermissionDecision, suggestions: JSONValue?) -> HTTPResponse {
        var decisionObject: [String: JSONValue]
        switch decision {
        case .askInTerminal:
            return .empty
        case .allow:
            decisionObject = ["behavior": .string("allow")]
        case .allowAlways:
            decisionObject = ["behavior": .string("allow")]
            if case .array(let rules) = suggestions, !rules.isEmpty {
                decisionObject["updatedPermissions"] = .array(rules)
            }
        case .allowWithInput(let input):
            decisionObject = ["behavior": .string("allow"), "updatedInput": input]
        case .deny(let message):
            decisionObject = ["behavior": .string("deny"),
                              "message": .string(message ?? "Denied from Tether.")]
        }
        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decisionObject),
            ]),
        ])
        return HTTPResponse(status: 200, body: Data(output.compactString().utf8))
    }
}
