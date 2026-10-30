import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct ReviewRoutingTests {
    private let project = ProjectID()
    private func comment(_ instruction: String) -> ReviewComment {
        ReviewComment(path: "Sources/App.swift", lines: [
            .init(kind: .add, oldNumber: nil, newNumber: 1, text: "let value = 1")
        ], instruction: instruction)
    }

    @Test func sameRelativeFileKeepsWorktreeDraftsSeparate() {
        let a = ReviewScope(projectId: project, worktreePath: "/repo/a")
        let b = ReviewScope(projectId: project, worktreePath: "/repo/b")
        var drafts = ReviewDrafts()
        let first = comment("Review A"), second = comment("Review B")
        drafts.add(first, in: a)
        drafts.add(second, in: b)
        #expect(drafts.comments(in: a) == [first])
        #expect(drafts.comments(in: b) == [second])
        drafts.remove(first.id, in: b)
        #expect(drafts.comments(in: a) == [first])
    }

    @Test func selectedWrongWorktreeCannotReceiveComments() {
        let a = ReviewScope(projectId: project, worktreePath: "/repo/a")
        let b = ReviewScope(projectId: project, worktreePath: "/repo/b")
        let paneA = PaneID(), paneB = PaneID()
        var drafts = ReviewDrafts()
        drafts.add(comment("Review A"), in: a)
        var delivered: PaneID?
        let sent = drafts.send(in: a, extra: nil, candidates: [
            .init(id: paneB, scope: b, isLive: true), .init(id: paneA, scope: a, isLive: true)
        ], selected: paneB) { pane, text in
            delivered = pane
            #expect(text.contains("Review A"))
            return true
        }
        #expect(sent == paneA)
        #expect(delivered == paneA)
        #expect(drafts.comments(in: a).isEmpty)
    }

    @Test func noLiveMatchingSessionPreservesDraftAndDoesNotSend() {
        let a = ReviewScope(projectId: project, worktreePath: "/repo/a")
        let b = ReviewScope(projectId: project, worktreePath: "/repo/b")
        var drafts = ReviewDrafts()
        let pending = comment("Keep draft")
        drafts.add(pending, in: a)
        let result = drafts.send(in: a, extra: comment("Current selection"), candidates: [
            .init(id: PaneID(), scope: a, isLive: false),
            .init(id: PaneID(), scope: b, isLive: true),
            .init(id: PaneID(), scope: .init(projectId: ProjectID(), worktreePath: a.worktreePath), isLive: true)
        ], selected: nil) { _, _ in
            Issue.record("No matching session must not send")
            return true
        }
        #expect(result == nil)
        #expect(drafts.comments(in: a) == [pending])
    }

    @Test func selectedLiveSessionInSameWorktreeWins() {
        let scope = ReviewScope(projectId: project, worktreePath: "/repo/a")
        let first = PaneID(), selected = PaneID()
        var drafts = ReviewDrafts()
        let result = drafts.send(in: scope, extra: comment("Selected"), candidates: [
            .init(id: first, scope: scope, isLive: true), .init(id: selected, scope: scope, isLive: true)
        ], selected: selected) { pane, _ in
            #expect(pane == selected)
            return true
        }
        #expect(result == selected)
    }

    @Test func deliveryFailurePreservesPendingComments() {
        let scope = ReviewScope(projectId: project, worktreePath: "/repo/a")
        var drafts = ReviewDrafts()
        let pending = comment("Keep draft")
        drafts.add(pending, in: scope)
        let result = drafts.send(in: scope, extra: nil, candidates: [
            .init(id: PaneID(), scope: scope, isLive: true)
        ], selected: nil) { _, _ in false }
        #expect(result == nil)
        #expect(drafts.comments(in: scope) == [pending])
    }
}
