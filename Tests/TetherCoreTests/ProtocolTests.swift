import Foundation
import TetherCore
import Testing
import TetherProtocol

@Suite struct ProtocolTests {
    @Test func macMessageRoundTrips() throws {
        let original = MacMessage.permissionRequested(
            PermissionRequested(sessionId: "s1", toolName: "Bash", summary: "npm test"))
        let data = try WireCodec.encoder().encode(original)
        let decoded = try WireCodec.decoder().decode(MacMessage.self, from: data)
        guard case .permissionRequested(let p) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(p.toolName == "Bash")
        #expect(p.summary == "npm test")
    }

    @Test func phoneMessageRoundTrips() throws {
        let original = PhoneMessage.sendMessage(sessionId: "s1", text: "ship it")
        let data = try WireCodec.encoder().encode(original)
        let decoded = try WireCodec.decoder().decode(PhoneMessage.self, from: data)
        guard case .sendMessage(let id, let text) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(id == "s1")
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
