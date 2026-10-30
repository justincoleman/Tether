import Foundation

/// A compose draft survives delivery failure. Only the matching Mac receipt
/// may clear what was sent; edits made since sending belong to the next reply.
public struct CompanionDraft: Sendable {
    public var text: String
    public var image: Data?
    public private(set) var requestId: UUID?
    public private(set) var outcome: String?
    private var sentText: String?
    private var sentImage: Data?

    public init(text: String = "", image: Data? = nil) {
        self.text = text
        self.image = image
    }

    public var isSending: Bool { requestId != nil }

    public mutating func beginSending() -> UUID? {
        guard !isSending, image != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = UUID()
        requestId = id
        sentText = text
        sentImage = image
        outcome = nil
        return id
    }

    public mutating func complete(requestId: UUID, outcome: String) {
        guard self.requestId == requestId else { return }
        guard ["sent", "queued", "failed"].contains(outcome) else { return }
        if outcome == "sent" || outcome == "queued" {
            if text == sentText { text = "" }
            if image == sentImage { image = nil }
        }
        self.outcome = outcome
        finish()
    }

    public mutating func deliveryUnconfirmed(requestId: UUID) {
        guard self.requestId == requestId else { return }
        outcome = "unconfirmed"
        finish()
    }

    private mutating func finish() {
        requestId = nil
        sentText = nil
        sentImage = nil
    }
}
