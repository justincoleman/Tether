import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

/// Collects router events from a @Sendable callback.
actor EventLog {
    private(set) var events: [HookEvent] = []
    func append(_ e: HookEvent) { events.append(e) }
    func count() -> Int { events.count }
}

@Suite struct HookRouterTests {
    let token = "secret"
    let pane = PaneID()

    private func request(path: String, body: String, token: String? = nil) -> HTTPRequest {
        var headers = [HookSettings.paneHeader: pane.uuidString]
        headers[HookSettings.tokenHeader] = token ?? self.token
        return HTTPRequest(method: "POST", path: path, headers: headers, body: Data(body.utf8))
    }

    private let stopBody = """
    {"session_id":"s1","cwd":"/p","hook_event_name":"Stop","last_assistant_message":"Done.","stop_hook_active":false}
    """
    private let permissionBody = """
    {"session_id":"s1","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash",
     "tool_input":{"command":"rm -rf node_modules"},
     "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}
    """

    @Test func wrongTokenIsIgnoredWithEmpty200() async {
        let log = EventLog()
        let router = HookRouter(token: token, registry: SessionRegistry(), broker: PermissionBroker()) { await log.append($0) }
        let response = await router.handle(request(path: HookSettings.hookPath, body: stopBody, token: "nope"))
        #expect(response == .empty)
        #expect(await log.count() == 0)
    }

    @Test func stateHookUpdatesRegistryAndEmits() async {
        let log = EventLog()
        let registry = SessionRegistry()
        let router = HookRouter(token: token, registry: registry, broker: PermissionBroker()) { await log.append($0) }
        let response = await router.handle(request(path: HookSettings.hookPath, body: stopBody))
        #expect(response == .empty)
        #expect(await registry.session(forPane: pane)?.state == .done)
        #expect(await log.count() == 1)
    }

    @Test func malformedBodyIsEmpty200() async {
        let router = HookRouter(token: token, registry: SessionRegistry(), broker: PermissionBroker()) { _ in }
        #expect(await router.handle(request(path: HookSettings.hookPath, body: "not json")) == .empty)
    }

    @Test func permissionAllowReturnsDecisionAndResumesWorking() async throws {
        let broker = PermissionBroker()
        let registry = SessionRegistry()
        // Answer as soon as the request is announced, like the Mac UI would.
        let router = HookRouter(token: token, registry: registry, broker: broker) { event in
            if case .permissionRequested(let p) = event { await broker.resolve(p.id, .allow) }
        }
        let response = await router.handle(request(path: HookSettings.permissionPath, body: permissionBody))
        let text = String(decoding: response.body, as: UTF8.self)
        #expect(text == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(await registry.session(forPane: pane)?.state == .working)
    }

    @Test func permissionAllowAlwaysPassesSuggestionsThrough() async {
        let broker = PermissionBroker()
        let router = HookRouter(token: token, registry: SessionRegistry(), broker: broker) { event in
            if case .permissionRequested(let p) = event { await broker.resolve(p.id, .allowAlways) }
        }
        let response = await router.handle(request(path: HookSettings.permissionPath, body: permissionBody))
        let text = String(decoding: response.body, as: UTF8.self)
        #expect(text.contains(#""updatedPermissions":[{"behavior":"allow","destination":"localSettings""#))
    }

    @Test func permissionTimeoutFallsBackToTerminal() async {
        let registry = SessionRegistry()
        let router = HookRouter(token: token, registry: registry, broker: PermissionBroker(),
                                permissionTimeout: .milliseconds(50)) { _ in }
        let response = await router.handle(request(path: HookSettings.permissionPath, body: permissionBody))
        #expect(response == .empty)
        #expect(await registry.session(forPane: pane)?.state == .needsInput)
    }

    @Test func denyCarriesMessage() {
        let r = HookRouter.response(for: .deny(message: "nope"), suggestions: nil)
        #expect(String(decoding: r.body, as: UTF8.self).contains(#""behavior":"deny","message":"nope""#))
    }
}

@Suite struct PermissionBrokerTests {
    @Test func firstAnswerWins() async {
        let broker = PermissionBroker()
        let p = PendingPermission(sessionId: "s", paneId: nil, toolName: "Bash", toolInput: nil, suggestions: nil)
        await broker.register(p)
        #expect(await broker.resolve(p.id, .allow))
        #expect(await broker.resolve(p.id, .deny(message: nil)) == false)
        #expect(await broker.wait(for: p.id, timeout: .seconds(1)) == .allow)
    }

    @Test func cancelAllReleasesPane() async {
        let broker = PermissionBroker()
        let pane = PaneID()
        let p = PendingPermission(sessionId: "s", paneId: pane, toolName: "Bash", toolInput: nil, suggestions: nil)
        await broker.register(p)
        #expect(await broker.cancelAll(paneId: pane) == [p.id])
        #expect(await broker.pendingRequests().isEmpty)
    }
}

@Suite struct HTTPParserTests {
    @Test func parsesCompleteRequest() {
        let raw = "POST /tether/hook?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Tether-Token: abc\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let r) = HTTPRequestParser.parse(Data(raw.utf8)) else {
            Issue.record("expected complete"); return
        }
        #expect(r.method == "POST")
        #expect(r.path == "/tether/hook")
        #expect(r.header("x-tether-token") == "abc")
        #expect(r.body == Data("{}".utf8))
    }

    @Test func waitsForHeadersAndBody() {
        #expect(HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nContent-Le".utf8)) == .incomplete)
        #expect(HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8)) == .incomplete)
    }

    @Test func rejectsGarbage() {
        #expect(HTTPRequestParser.parse(Data("hello\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .invalid)
    }

    @Test func serializesResponse() {
        let text = String(decoding: HTTPResponse(status: 200, body: Data("{}".utf8)).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}

@Suite struct HookSettingsTests {
    @Test func coversEveryEventWithPortAndHeaders() throws {
        let data = try HookSettings.settingsJSON(port: 54321)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        for event in HookSettings.observedEvents + ["PermissionRequest"] {
            #expect(root["hooks"]?[event] != nil, "missing \(event)")
        }
        guard case .array(let groups)? = root["hooks"]?["PermissionRequest"],
              case .array(let handlers)? = groups.first?["hooks"],
              let handler = handlers.first else { Issue.record("bad shape"); return }
        #expect(handler["url"]?.stringValue == "http://127.0.0.1:54321/tether/permission")
        #expect(handler["timeout"] == .number(600))
        #expect(handler["headers"]?[HookSettings.paneHeader]?.stringValue == "$TETHER_PANE_ID")
        #expect(handler["async"] == nil) // HTTP hooks do not support async
    }

    /// SessionStart accepts only command hooks; an http one is silently never run.
    @Test func sessionStartIsACurlCommand() throws {
        let root = try JSONDecoder().decode(JSONValue.self, from: HookSettings.settingsJSON(port: 54321))
        guard case .array(let groups)? = root["hooks"]?["SessionStart"],
              case .array(let handlers)? = groups.first?["hooks"],
              let handler = handlers.first else { Issue.record("bad shape"); return }
        #expect(handler["type"]?.stringValue == "command")
        let command = handler["command"]?.stringValue ?? ""
        #expect(command.hasPrefix("curl -s -o /dev/null"))
        #expect(command.contains(#"-H "X-Tether-Pane: $TETHER_PANE_ID""#))
        #expect(command.contains(#"-H "X-Tether-Token: $TETHER_TOKEN""#))
        #expect(command.contains("--data-binary @- http://127.0.0.1:54321/tether/hook"))
        #expect(command.hasSuffix("|| true"))
    }
}

@Suite struct PermissionSummaryTests {
    @Test func bashShowsCommand() {
        let s = PermissionSummary.describe(toolName: "Bash", input: .object(["command": .string("npm test")]))
        #expect(s == PermissionSummary(title: "Run a command", detail: "npm test"))
    }

    @Test func unknownToolShowsJSON() {
        let s = PermissionSummary.describe(toolName: "mcp__x__y", input: .object(["b": .number(1), "a": .bool(true)]))
        #expect(s.detail == #"{"a":true,"b":1}"#)
    }
}
