import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct APNsTests {
    let mac = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let pane = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func jwtHasHeaderClaimsAndBase64URLSignature() throws {
        let token = APNsJWT.make(teamId: "ABCDE12345", keyId: "ABC123DEFG",
                                 issuedAt: Date(timeIntervalSince1970: 1_700_000_000)) { _ in Data([0xFB, 0xFF, 0xFE]) }
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ s: String) -> String {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return String(decoding: Data(base64Encoded: b)!, as: UTF8.self)
        }
        #expect(decode(parts[0]) == #"{"alg":"ES256","kid":"ABC123DEFG"}"#)
        #expect(decode(parts[1]) == #"{"iss":"ABCDE12345","iat":1700000000}"#)
        #expect(parts[2] == "-__-") // no padding, URL-safe alphabet
    }

    func change(_ previous: SessionState?, _ state: SessionState, attention: AttentionReason? = nil) -> PushPlanner.Change {
        PushPlanner.Change(macId: mac, paneId: pane, projectName: "Tether", title: "Claude",
                           previous: previous, state: state, attention: attention,
                           preview: "All tests pass.", steps: 3, startedAt: Date(timeIntervalSince1970: 100))
    }

    @Test func plannerRules() {
        // Starting work starts a Live Activity, nothing else.
        let start = PushPlanner.intents(for: change(.idle, .working))
        #expect(start.count == 1)
        if case .activityStart(let a, let c)? = start.first {
            #expect(a.paneId == pane.uuidString && a.macId == mac.uuidString)
            #expect(c.state == "working" && c.steps == 3 && c.startedAt == 100)
        } else { Issue.record("expected activityStart") }

        // A permission prompt keeps the activity; its alert comes from the request.
        #expect(PushPlanner.intents(for: change(.working, .needsInput, attention: .permission))
                == [.activityUpdate(paneId: pane, change(.working, .needsInput).content)])

        // A question alerts and keeps the activity.
        let q = PushPlanner.intents(for: change(.working, .needsInput, attention: .question))
        #expect(q.first == .question(paneId: pane, projectName: "Tether", text: "All tests pass."))
        #expect(q.count == 2)

        // Finishing alerts and ends the activity.
        let done = PushPlanner.intents(for: change(.working, .done))
        #expect(done.first == .finished(paneId: pane, projectName: "Tether", text: "All tests pass."))
        if case .activityEnd? = done.last {} else { Issue.record("expected activityEnd") }

        // Looking at a finished tab (done → idle) and repeats are silent.
        #expect(PushPlanner.intents(for: change(.done, .idle)).isEmpty)
        #expect(PushPlanner.intents(for: change(.working, .working)).isEmpty)
    }

    @Test func permissionAlertPayload() throws {
        let request = PermissionRequested(id: UUID(), paneId: pane, sessionId: "s1", toolName: "Bash",
                                          title: "Run a command", detail: "npm test")
        let r = PushPayload.request(for: .permission(request, projectName: "Tether"), macId: mac)
        #expect(r.pushType == "alert" && r.priority == 10)
        #expect(r.headers(bundleId: "com.x.phone")["apns-topic"] == "com.x.phone")
        let body = try json(r.body)
        let aps = try #require(body["aps"] as? [String: Any])
        #expect(aps["category"] as? String == PushKeys.permissionCategory)
        #expect(aps["interruption-level"] as? String == "time-sensitive")
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Tether: Claude wants to run a command")
        #expect(alert["body"] as? String == "npm test")
        #expect(body[PushKeys.requestId] as? String == request.id.uuidString)
        #expect(body[PushKeys.macId] as? String == mac.uuidString)
        #expect(body[PushKeys.paneId] as? String == pane.uuidString)
    }

    @Test func codexStateAlertsUseCodexInsteadOfClaude() throws {
        let cases: [(SessionState, SessionState, AttentionReason?, String)] = [
            (.working, .needsInput, .question, "Tether: Codex asked you something"),
            (.working, .needsInput, .dialog, "Tether: Codex is waiting"),
            (.working, .done, nil, "Tether: Codex finished"),
            (.working, .error, nil, "Tether: Codex hit an error"),
        ]
        for (previous, state, attention, title) in cases {
            var c = change(previous, state, attention: attention)
            c.agent = .codex
            let intent = try #require(PushPlanner.intents(for: c).first)
            let aps = try #require(try json(PushPayload.request(for: intent, macId: mac).body)["aps"] as? [String: Any])
            let alert = try #require(aps["alert"] as? [String: Any])
            #expect(alert["title"] as? String == title)
        }
    }

    @Test func shortcutFailureNamesTheCommandAndExitCodeWithoutClaudeWording() throws {
        let request = PushPayload.request(for: .shortcutFailed(paneId: pane, projectName: "Tether",
            title: "Run tests", exitCode: 7, output: "captured stderr"), macId: mac)
        #expect(request.pushType == "alert")
        let body = try json(request.body)
        let aps = try #require(body["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Tether: Run tests failed (exit 7)")
        #expect(alert["body"] as? String == "captured stderr")
        #expect(!String(decoding: request.body, as: UTF8.self).contains("Claude"))
        #expect(body[PushKeys.macId] as? String == mac.uuidString)
        #expect(body[PushKeys.paneId] as? String == pane.uuidString)
    }

    @Test func liveActivityStartPayloadMatchesActivityKitShape() throws {
        let attributes = LiveActivityAttributes(macId: mac.uuidString, paneId: pane.uuidString,
                                                projectName: "Tether", title: "Claude")
        let content = LiveActivityContent(state: "working", detail: "Reading files", steps: 2, startedAt: 100)
        let r = PushPayload.request(for: .activityStart(attributes, content), macId: mac,
                                    now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(r.pushType == "liveactivity")
        #expect(r.topic(bundleId: "com.x.phone") == "com.x.phone.push-type.liveactivity")
        let aps = try #require(try json(r.body)["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "start")
        #expect(aps["timestamp"] as? Int == 1_700_000_000)
        #expect(aps["attributes-type"] as? String == "LiveActivityAttributes")
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Tether: Agent is working")
        let attrs = try #require(aps["attributes"] as? [String: Any])
        #expect(attrs["projectName"] as? String == "Tether" && attrs["paneId"] as? String == pane.uuidString)
        let state = try #require(aps["content-state"] as? [String: Any])
        #expect(state["state"] as? String == "working" && state["steps"] as? Int == 2)
        #expect(state["startedAt"] as? Double == 100)
        // What ActivityKit does with it: decode with a default JSONDecoder.
        let stateData = try JSONSerialization.data(withJSONObject: state)
        #expect(try JSONDecoder().decode(LiveActivityContent.self, from: stateData) == content)
    }

    @Test func stepsInCurrentTurnCountsSinceLastUserMessage() {
        let at = Date(timeIntervalSince1970: 0)
        var m = TranscriptModel()
        m.apply([
            .userText(id: "u1", text: "a", at: at),
            .toolUse(id: "t1", name: "Read", summary: "", at: at),
            .userText(id: "u2", text: "b", at: at),
            .toolUse(id: "t2", name: "Read", summary: "", at: at),
            .toolUse(id: "t3", name: "Bash", summary: "", at: at),
            .assistantText(id: "a1", text: "ok", at: at),
            .toolUse(id: "t4", name: "Edit", summary: "", at: at),
        ])
        #expect(m.stepsInCurrentTurn == 3)
    }
}
