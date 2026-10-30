import Foundation
import Testing
import TetherProtocol

@Suite struct CompanionDraftTests {
    @Test func keepsTextAndPhotoUntilMatchingAcceptance() throws {
        var draft = CompanionDraft(text: "look at this", image: Data([1, 2, 3]))
        let started = draft.beginSending()
        let id = try #require(started)
        #expect(draft.text == "look at this")
        #expect(draft.image == Data([1, 2, 3]))
        let duplicate = draft.beginSending()
        #expect(duplicate == nil)
        draft.complete(requestId: UUID(), outcome: "sent")
        #expect(draft.isSending)
        draft.complete(requestId: id, outcome: "queued")
        #expect(!draft.isSending)
        #expect(draft.text.isEmpty && draft.image == nil)
        #expect(draft.outcome == "queued")
    }

    @Test func rejectionKeepsDraftAvailableForRetry() throws {
        var draft = CompanionDraft(text: "retry me", image: Data([4]))
        let started = draft.beginSending()
        let id = try #require(started)
        draft.complete(requestId: id, outcome: "failed")
        #expect(draft.text == "retry me" && draft.image == Data([4]))
        #expect(!draft.isSending)
        let retried = draft.beginSending()
        #expect(retried != nil)
    }

    @Test func disconnectOrTimeoutKeepsDraftAndIgnoresLateReceipt() throws {
        var draft = CompanionDraft(text: "keep me", image: Data([5]))
        let started = draft.beginSending()
        let first = try #require(started)
        draft.deliveryUnconfirmed(requestId: first)
        #expect(draft.text == "keep me" && draft.image == Data([5]))
        #expect(draft.outcome == "unconfirmed" && !draft.isSending)
        let retried = draft.beginSending()
        let second = try #require(retried)
        draft.complete(requestId: first, outcome: "sent")
        #expect(draft.isSending && draft.text == "keep me")
        draft.complete(requestId: second, outcome: "sent")
        #expect(draft.text.isEmpty && draft.image == nil)
    }

    @Test func acknowledgmentDoesNotClearNewerEdits() throws {
        var draft = CompanionDraft(text: "first", image: Data([1]))
        let started = draft.beginSending()
        let id = try #require(started)
        draft.text = "next"
        draft.image = Data([2])
        draft.complete(requestId: id, outcome: "sent")
        #expect(draft.text == "next" && draft.image == Data([2]))
    }
}
