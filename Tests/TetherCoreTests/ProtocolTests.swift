import Foundation
import TetherCore
import Testing
import TetherProtocol

@Suite struct ProtocolTests {
    @Test func macMessageRoundTrips() throws {
        let pane = UUID(), project = UUID()
        let snapshot = Snapshot(
            macName: "Mac mini",
            projects: [ProjectSummary(id: project, name: "Tether", branch: "main")],
            sessions: [SessionSummary(id: pane, projectId: project, sessionId: "s1", title: "Claude",
                                      state: .needsInput, attention: .permission, queued: 1,
                                      status: SessionStatus(modelId: "claude-opus-5-5", modelName: "Opus 5.5",
                                                            costUSD: 1.25))],
            permissions: [PermissionRequested(id: UUID(), paneId: pane, sessionId: "s1", toolName: "Bash",
                                              title: "Run a command", detail: "npm test")],
            limits: UsageLimits(fiveHour: UsageLimit(usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_793_200_000)),
                                sevenDay: nil))
        let data = try WireCodec.encoder().encode(MacMessage.snapshot(snapshot))
        let decoded = try WireCodec.decoder().decode(MacMessage.self, from: data)
        guard case .snapshot(let s) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(s == snapshot)
    }

    @Test func projectIconsRoundTrip() throws {
        let id = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let data = try WireCodec.encoder().encode(MacMessage.projectIcons([ProjectIcon(id: id, png: png)]))
        guard case .projectIcons(let icons) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(icons == [ProjectIcon(id: id, png: png)])
    }

    @Test func transcriptRoundTrips() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let original = MacMessage.transcript(sessionId: "s1", events: [
            .userText(id: "u1", text: "hi", at: at),
            .toolUse(id: "t1", name: "Bash", summary: "ls", at: at),
        ], reset: true)
        let data = try WireCodec.encoder().encode(original)
        guard case .transcript(let id, let events, let reset) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(id == "s1" && reset && events.count == 2)
        var model = TranscriptModel()
        model.apply(events)
        #expect(model.items.count == 2)
    }

    @Test func transcriptPreviewIsLatestMessageOnOneLine() {
        let at = Date(timeIntervalSince1970: 0)
        var model = TranscriptModel()
        #expect(model.preview() == nil)
        model.apply([
            .userText(id: "u1", text: "Fix the login bug", at: at),
            .assistantText(id: "a1", text: "## Done\n\nI **fixed** it in\n`Login.swift`.", at: at),
            .toolUse(id: "t1", name: "Bash", summary: "ls", at: at),
        ])
        #expect(model.preview() == "Done I fixed it in Login.swift.")
        model.apply(.userText(id: "u2", text: String(repeating: "a", count: 300), at: at))
        let long = model.preview(limit: 20)!
        #expect(long.count == 20 && long.hasPrefix("You: aaa") && long.hasSuffix("…"))
    }

    @Test func phoneMessageRoundTrips() throws {
        let pane = UUID()
        let original = PhoneMessage.sendMessage(paneId: pane, text: "ship it")
        let data = try WireCodec.encoder().encode(original)
        let decoded = try WireCodec.decoder().decode(PhoneMessage.self, from: data)
        guard case .sendMessage(let id, let text) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(id == pane)
        #expect(text == "ship it")
    }

    @Test func hookPayloadDecodesSnakeCase() throws {
        let json = """
        {"session_id":"abc","cwd":"/x","transcript_path":"/x/t.jsonl",
         "hook_event_name":"Notification","notification_type":"permission_prompt","extra":1}
        """
        let p = try JSONDecoder().decode(TetherCore.HookPayload.self, from: Data(json.utf8))
        #expect(p.hookEventName == .notification)
        #expect(p.notificationType == "permission_prompt")
    }
}
