import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite @MainActor struct PromptRetryTests {
    @Test func failedDeliveryStopsAfterFiveAttempts() async {
        let retries = PromptRetryScheduler(sleep: { await Task.yield() })
        var calls = 0
        let task = retries.schedule(for: PaneID()) {
            calls += 1
            return true
        }
        await task.value
        #expect(calls == 5)
    }

    @Test func recursiveSchedulingDoesNotResetBudgetOrBranch() async {
        let retries = PromptRetryScheduler(sleep: { await Task.yield() })
        let pane = PaneID()
        var calls = 0
        let task = retries.schedule(for: pane) {
            calls += 1
            retries.schedule(for: pane) { Issue.record("Duplicate task must not run"); return true }
            return true
        }
        await task.value
        #expect(calls == 5)
    }

    @Test func successStopsAndLaterWorkCanStartNewBurst() async {
        let retries = PromptRetryScheduler(sleep: { await Task.yield() })
        let pane = PaneID()
        var calls = 0
        await retries.schedule(for: pane) { calls += 1; return false }.value
        #expect(calls == 1)
        await retries.schedule(for: pane) { calls += 1; return calls < 4 }.value
        #expect(calls == 4)
    }

    @Test func cancellingPanePreventsDelivery() async {
        let retries = PromptRetryScheduler(sleep: { await Task.yield() })
        let pane = PaneID()
        let task = retries.schedule(for: pane) { Issue.record("Closed pane must not receive retries"); return true }
        retries.cancel(pane)
        await task.value
    }

    @Test func cancelledTaskCannotRemoveReplacement() async {
        let sleeper = RetrySleeper()
        let retries = PromptRetryScheduler(sleep: { await sleeper.sleep() })
        let pane = PaneID()
        let old = retries.schedule(for: pane) { Issue.record("Cancelled task ran"); return false }
        await sleeper.waitForPending(1)
        retries.cancel(pane)
        var calls = 0
        let replacement = retries.schedule(for: pane) { calls += 1; return false }
        await sleeper.waitForPending(2)
        sleeper.resumeFirst()
        await old.value
        let duplicate = retries.schedule(for: pane) { Issue.record("Old task erased replacement"); return false }
        sleeper.resumeFirst()
        await replacement.value
        await duplicate.value
        #expect(calls == 1)
    }

    @Test func panesHaveIndependentRetryBudgets() async {
        let retries = PromptRetryScheduler(sleep: { await Task.yield() })
        var a = 0, b = 0
        let first = retries.schedule(for: PaneID()) { a += 1; return true }
        let second = retries.schedule(for: PaneID()) { b += 1; return b < 2 }
        await first.value
        await second.value
        #expect(a == 5 && b == 2)
    }
}

@MainActor private final class RetrySleeper {
    private var pending: [CheckedContinuation<Void, Never>] = []
    func sleep() async { await withCheckedContinuation { pending.append($0) } }
    func waitForPending(_ count: Int) async {
        while pending.count < count { await Task.yield() }
    }
    func resumeFirst() { pending.removeFirst().resume() }
}
