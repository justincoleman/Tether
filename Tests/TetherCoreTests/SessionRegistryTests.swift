import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct SessionRegistryTests {
    private func hook(_ name: HookPayload.EventName, notification: String? = nil) -> HookPayload {
        HookPayload(sessionId: "s1", cwd: "/tmp/proj", transcriptPath: "/tmp/t.jsonl",
                    hookEventName: name, notificationType: notification)
    }

    @Test func fullLifecycle() async {
        let r = SessionRegistry()
        let pane = PaneID()
        #expect(await r.apply(hook(.sessionStart), paneId: pane) == .idle)
        #expect(await r.apply(hook(.userPromptSubmit), paneId: pane) == .working)
        #expect(await r.apply(hook(.postToolUse), paneId: pane) == nil)
        #expect(await r.apply(hook(.permissionRequest), paneId: pane) == .needsInput)
        #expect(await r.apply(hook(.stop), paneId: pane) == .done)
        #expect(await r.paneFocused(pane) == .idle)
        #expect(await r.apply(hook(.sessionEnd), paneId: pane) == .detached)
    }

    @Test func onlyWaitingNotificationsFlipState() async {
        let r = SessionRegistry()
        await r.apply(hook(.userPromptSubmit), paneId: nil)
        #expect(await r.apply(hook(.notification, notification: "auth_success"), paneId: nil) == .working)
        #expect(await r.apply(hook(.notification, notification: "idle_prompt"), paneId: nil) == .needsInput)
    }

    @Test func paneExitDetachesAndUnmaps() async {
        let r = SessionRegistry()
        let pane = PaneID()
        await r.apply(hook(.sessionStart), paneId: pane)
        #expect(await r.paneExited(pane) == .detached)
        #expect(await r.session(forPane: pane) == nil)
    }
}
