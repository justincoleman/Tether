import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct ReviewMessageTests {
    private func add(_ n: Int, _ text: String) -> DiffLine { .init(kind: .add, oldNumber: nil, newNumber: n, text: text) }
    private func ctx(_ o: Int, _ n: Int, _ text: String) -> DiffLine { .init(kind: .context, oldNumber: o, newNumber: n, text: text) }
    private func del(_ o: Int, _ text: String) -> DiffLine { .init(kind: .delete, oldNumber: o, newNumber: nil, text: text) }

    @Test func singleCommentOnNewLines() {
        let comment = ReviewComment(path: "Sources/App.swift",
                                    lines: [add(28, "let x = 1"), ctx(20, 29, "let y = 2")],
                                    instruction: "Rename x to count.")
        #expect(ReviewMessage.compose([comment]) == """
        In `Sources/App.swift`, lines 28–29:

        ```swift
        let x = 1
        let y = 2
        ```

        Rename x to count.
        """)
    }

    @Test func singleLineSaysLine() {
        let comment = ReviewComment(path: "a.py", lines: [add(7, "x")], instruction: "Why?")
        #expect(ReviewMessage.compose([comment]).hasPrefix("In `a.py`, line 7:"))
    }

    @Test func removedLinesAreLabelledAsThePreviousVersion() {
        let comment = ReviewComment(path: "a.txt", lines: [del(10, "old"), del(11, "older")], instruction: "Restore these.")
        let text = ReviewMessage.compose([comment])
        #expect(text.hasPrefix("In `a.txt`, removed lines 10–11 (previous version):"))
        #expect(text.contains("old\nolder"))
    }

    @Test func mixedSelectionIsShownAsADiff() {
        let comment = ReviewComment(path: "a.txt", lines: [del(2, "two"), add(2, "TWO")], instruction: "Keep lowercase.")
        let text = ReviewMessage.compose([comment])
        #expect(text.contains("including removed lines (shown as a diff)"))
        #expect(text.contains("```diff\n-two\n+TWO\n```"))
    }

    @Test func severalCommentsAreNumbered() {
        let a = ReviewComment(path: "a.txt", lines: [add(1, "x")], instruction: "First.")
        let b = ReviewComment(path: "b.txt", lines: [add(5, "y")], instruction: "Second.")
        let text = ReviewMessage.compose([a, b])
        #expect(text.hasPrefix("Please address these review comments on the current changes:\n\n1. In `a.txt`, line 1:"))
        #expect(text.contains("\n\n2. In `b.txt`, line 5:"))
        #expect(text.hasSuffix("Second."))
    }

    @Test func fenceGrowsAroundBackticksInTheCode() {
        let comment = ReviewComment(path: "README.md", lines: [add(1, "```bash"), add(2, "make")], instruction: "Fix.")
        let text = ReviewMessage.compose([comment])
        #expect(text.contains("````markdown\n```bash\nmake\n````"))
    }

    @Test func commentsWithoutInstructionsAreDropped() {
        let blank = ReviewComment(path: "a.txt", lines: [add(1, "x")], instruction: "  ")
        #expect(ReviewMessage.compose([blank]).isEmpty)
        #expect(ReviewMessage.compose([]).isEmpty)
    }

    @Test func shortLabelNamesTheFileAndLines() {
        let comment = ReviewComment(path: "Sources/Deep/App.swift", lines: [add(3, "a"), add(4, "b")], instruction: "x")
        #expect(comment.shortLabel == "App.swift · lines 3–4")
    }
}

@Suite struct PromptQueueTests {
    @Test func drainsEverythingAsOneMessageOldestFirst() {
        var queue = PromptQueue()
        let pane = PaneID()
        queue.enqueue("first\n", for: pane)
        queue.enqueue("second", for: pane)
        #expect(queue.count(for: pane) == 2)
        #expect(queue.drain(for: pane) == "first\n\nsecond")
        #expect(queue.count(for: pane) == 0)
        #expect(queue.drain(for: pane) == nil)
    }

    @Test func blankMessagesAreIgnoredAndPanesAreSeparate() {
        var queue = PromptQueue()
        let a = PaneID(), b = PaneID()
        queue.enqueue("   \n", for: a)
        queue.enqueue("for b", for: b)
        #expect(queue.count(for: a) == 0)
        #expect(queue.drain(for: a) == nil)
        queue.clear(pane: b)
        #expect(queue.drain(for: b) == nil)
    }
}

@Suite struct PromptGateTests {
    @Test func sendsOnlyWhenTypingIsSafe() {
        #expect(PromptGate.canSend(state: .idle, attention: nil))
        #expect(PromptGate.canSend(state: .done, attention: nil))
        #expect(PromptGate.canSend(state: .error, attention: nil))
        #expect(PromptGate.canSend(state: .needsInput, attention: .question))
        #expect(!PromptGate.canSend(state: .needsInput, attention: .permission))
        #expect(!PromptGate.canSend(state: .needsInput, attention: .dialog))
        #expect(!PromptGate.canSend(state: .needsInput, attention: nil))
        #expect(!PromptGate.canSend(state: .working, attention: nil))
        #expect(!PromptGate.canSend(state: .detached, attention: nil))
    }
}

@Suite struct AttentionReasonTests {
    private func hook(_ name: HookPayload.EventName, notification: String? = nil, last: String? = nil) -> HookPayload {
        HookPayload(sessionId: "s", cwd: "/p", hookEventName: name, notificationType: notification, lastAssistantMessage: last)
    }

    @Test func permissionQuestionAndDialogAreDistinguished() async {
        let r = SessionRegistry()
        #expect(await r.apply(hook(.permissionRequest), paneId: nil).attention == .permission)
        await r.apply(hook(.userPromptSubmit), paneId: nil)
        #expect(await r.apply(hook(.stop, last: "Shall I continue?"), paneId: nil).attention == .question)
        await r.apply(hook(.userPromptSubmit), paneId: nil)
        #expect(await r.apply(hook(.notification, notification: "elicitation_dialog"), paneId: nil).attention == .dialog)
        await r.apply(hook(.userPromptSubmit), paneId: nil)
        #expect(await r.apply(hook(.notification, notification: "agent_needs_input"), paneId: nil).attention == .question)
    }

    @Test func attentionClearsWhenClaudeMovesOn() async {
        let r = SessionRegistry()
        await r.apply(hook(.permissionRequest), paneId: nil)
        #expect(await r.apply(hook(.postToolUse), paneId: nil).attention == nil)
        await r.apply(hook(.permissionRequest), paneId: nil)
        #expect(await r.setState(.working, for: "s")?.attention == nil)
        #expect(await r.apply(hook(.stop, last: "Done."), paneId: nil).attention == nil)
    }

    @Test func unrelatedNotificationKeepsTheCurrentReason() async {
        let r = SessionRegistry()
        await r.apply(hook(.permissionRequest), paneId: nil)
        let after = await r.apply(hook(.notification, notification: "auth_success"), paneId: nil)
        #expect(after.state == .needsInput && after.attention == .permission)
    }
}
