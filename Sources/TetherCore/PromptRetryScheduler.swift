import Foundation
import TetherProtocol

/// One bounded retry burst per pane. Calls made by an attempt itself coalesce
/// with that burst instead of spawning another task or resetting its budget.
@MainActor
public final class PromptRetryScheduler {
    private struct Pending {
        var id: UUID
        var task: Task<Void, Never>
    }
    private var pending: [PaneID: Pending] = [:]
    private let sleep: @MainActor () async throws -> Void

    public init(sleep: @escaping @MainActor () async throws -> Void = {
        try await Task.sleep(for: .seconds(1))
    }) {
        self.sleep = sleep
    }

    /// The attempt returns true only while more work needs a retry. Returning
    /// the task lets callers await a burst without starting another one.
    @discardableResult
    public func schedule(for pane: PaneID, attempt: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        if let existing = pending[pane] { return existing.task }
        let id = UUID()
        let sleep = self.sleep
        let task = Task { [weak self] in
            for _ in 0..<5 {
                do { try await sleep() } catch { break }
                guard !Task.isCancelled else { break }
                if !attempt() { break }
            }
            // Cancellation may have allowed a replacement burst to start.
            if self?.pending[pane]?.id == id { self?.pending[pane] = nil }
        }
        pending[pane] = Pending(id: id, task: task)
        return task
    }

    public func cancel(_ pane: PaneID) {
        pending.removeValue(forKey: pane)?.task.cancel()
    }
}
