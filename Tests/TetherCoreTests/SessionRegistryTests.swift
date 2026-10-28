import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct SessionRegistryTests {
    private func hook(_ name: HookPayload.EventName, session: String = "s1",
                      notification: String? = nil, last: String? = nil) -> HookPayload {
        HookPayload(sessionId: session, cwd: "/tmp/proj", transcriptPath: "/tmp/t.jsonl",
                    hookEventName: name, notificationType: notification, lastAssistantMessage: last)
    }

    @Test func fullLifecycle() async {
        let r = SessionRegistry()
        let pane = PaneID()
        #expect(await r.apply(hook(.sessionStart), paneId: pane).state == .idle)
        #expect(await r.apply(hook(.userPromptSubmit), paneId: pane).state == .working)
        #expect(await r.apply(hook(.permissionRequest), paneId: pane).state == .needsInput)
        #expect(await r.apply(hook(.postToolUse), paneId: pane).state == .working)
        #expect(await r.apply(hook(.stop, last: "All done."), paneId: pane).state == .done)
        #expect(await r.paneFocused(pane)?.state == .idle)
        #expect(await r.apply(hook(.sessionEnd), paneId: pane).state == .detached)
    }

    @Test func permissionModeIsKeptUntilAHookReportsAnother() async throws {
        let r = SessionRegistry()
        func payload(_ json: String) throws -> HookPayload {
            try JSONDecoder().decode(HookPayload.self, from: Data(json.utf8))
        }
        let start = try payload(#"{"session_id":"s1","cwd":"/p","hook_event_name":"UserPromptSubmit","permission_mode":"auto"}"#)
        #expect(await r.apply(start, paneId: nil).permissionMode == "auto")
        // An event without the field leaves the last known mode alone.
        let note = try payload(#"{"session_id":"s1","cwd":"/p","hook_event_name":"Notification","notification_type":"idle_prompt"}"#)
        #expect(await r.apply(note, paneId: nil).permissionMode == "auto")
        let stop = try payload(#"{"session_id":"s1","cwd":"/p","hook_event_name":"Stop","permission_mode":"plan"}"#)
        #expect(await r.apply(stop, paneId: nil).permissionMode == "plan")
    }

    @Test func stopEndingInQuestionNeedsInput() async {
        let r = SessionRegistry()
        await r.apply(hook(.userPromptSubmit), paneId: nil)
        #expect(await r.apply(hook(.stop, last: "Want me to open a PR?\n"), paneId: nil).state == .needsInput)
    }

    @Test func onlyBlockingNotificationsFlipToNeedsInput() async {
        let r = SessionRegistry()
        await r.apply(hook(.userPromptSubmit), paneId: nil)
        #expect(await r.apply(hook(.notification, notification: "auth_success"), paneId: nil).state == .working)
        #expect(await r.apply(hook(.notification, notification: "permission_prompt"), paneId: nil).state == .needsInput)
    }

    @Test func idlePromptRecoversFromInterrupt() async {
        let r = SessionRegistry()
        await r.apply(hook(.userPromptSubmit), paneId: nil)
        // User pressed Esc: no Stop hook, then idle_prompt arrives.
        #expect(await r.apply(hook(.notification, notification: "idle_prompt"), paneId: nil).state == .idle)
    }

    @Test func idlePromptDoesNotClearDone() async {
        let r = SessionRegistry()
        await r.apply(hook(.stop, last: "Finished."), paneId: nil)
        #expect(await r.apply(hook(.notification, notification: "idle_prompt"), paneId: nil).state == .done)
    }

    @Test func paneFocusOnlyClearsDone() async {
        let r = SessionRegistry()
        let pane = PaneID()
        await r.apply(hook(.userPromptSubmit), paneId: pane)
        #expect(await r.paneFocused(pane) == nil)
        #expect(await r.session(forPane: pane)?.state == .working)
    }

    @Test func newSessionOnSamePaneReplacesOld() async {
        let r = SessionRegistry()
        let pane = PaneID()
        await r.apply(hook(.sessionStart, session: "old"), paneId: pane)
        await r.apply(hook(.sessionStart, session: "new"), paneId: pane)
        #expect(await r.sessions["old"] == nil)
        #expect(await r.session(forPane: pane)?.id == "new")
    }

    @Test func paneExitDetachesAndUnmaps() async {
        let r = SessionRegistry()
        let pane = PaneID()
        await r.apply(hook(.sessionStart), paneId: pane)
        #expect(await r.paneExited(pane)?.state == .detached)
        #expect(await r.session(forPane: pane) == nil)
    }
}
