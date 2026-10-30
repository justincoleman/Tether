import Foundation
import TetherProtocol

/// A review belongs to one project's worktree, even when file paths coincide.
public struct ReviewScope: Hashable, Sendable {
    public var projectId: ProjectID
    public var worktreePath: String

    public init(projectId: ProjectID, worktreePath: String) {
        self.projectId = projectId
        self.worktreePath = worktreePath
    }
}

public struct ReviewDestination: Sendable {
    public var id: PaneID
    public var scope: ReviewScope
    public var isLive: Bool

    public init(id: PaneID, scope: ReviewScope, isLive: Bool) {
        self.id = id
        self.scope = scope
        self.isLive = isLive
    }
}

/// Pending reviews stay in their worktree until delivery or queuing succeeds.
public struct ReviewDrafts: Sendable {
    private var items: [ReviewScope: [ReviewComment]] = [:]

    public init() {}

    public func comments(in scope: ReviewScope) -> [ReviewComment] {
        items[scope] ?? []
    }

    public mutating func add(_ comment: ReviewComment, in scope: ReviewScope) {
        items[scope, default: []].append(comment)
    }

    public mutating func remove(_ id: UUID, in scope: ReviewScope) {
        items[scope]?.removeAll { $0.id == id }
        if items[scope]?.isEmpty == true { items[scope] = nil }
    }

    /// `deliver` returns true when the message was sent or safely queued.
    public mutating func send(in scope: ReviewScope, extra: ReviewComment?,
                              candidates: [ReviewDestination], selected: PaneID?,
                              deliver: (PaneID, String) -> Bool) -> PaneID? {
        let matching = candidates.filter { $0.isLive && $0.scope == scope }
        guard let pane = matching.first(where: { $0.id == selected }) ?? matching.first else { return nil }
        var comments = comments(in: scope)
        if let extra { comments.append(extra) }
        let message = ReviewMessage.compose(comments)
        guard !message.isEmpty, deliver(pane.id, message) else { return nil }
        items[scope] = nil
        return pane.id
    }
}
