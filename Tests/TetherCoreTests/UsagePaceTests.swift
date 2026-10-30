import Foundation
import Testing
import TetherProtocol

@Suite struct UsagePaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func paceIsTheShareOfTheWindowThatHasPassed() throws {
        // 2 hours left of 5: 60% of the window is gone.
        let limit = UsageLimit(usedPercent: 40, resetsAt: now.addingTimeInterval(2 * 3600))
        let pace = try #require(limit.paceFraction(in: .fiveHour, now: now))
        #expect(abs(pace - 0.6) < 0.0001)
        // 3.5 days left of 7: halfway.
        let week = UsageLimit(usedPercent: 10, resetsAt: now.addingTimeInterval(3.5 * 86_400))
        #expect(abs((week.paceFraction(in: .sevenDay, now: now) ?? 0) - 0.5) < 0.0001)
    }

    @Test func noResetTimeOrAStaleOneHasNoPace() {
        #expect(UsageLimit(usedPercent: 5, resetsAt: nil).paceFraction(in: .fiveHour, now: now) == nil)
        let stale = UsageLimit(usedPercent: 5, resetsAt: now.addingTimeInterval(9 * 3600))
        #expect(stale.paceFraction(in: .fiveHour, now: now) == nil)
        // A reset time already past clamps to the end of the window.
        let past = UsageLimit(usedPercent: 5, resetsAt: now.addingTimeInterval(-60))
        #expect(past.paceFraction(in: .fiveHour, now: now) == 1)
    }

    @Test func aheadOfPaceNeedsMoreThanAMargin() {
        let reset = now.addingTimeInterval(2.5 * 3600) // half the window gone
        #expect(UsageLimit(usedPercent: 70, resetsAt: reset).isAheadOfPace(in: .fiveHour, now: now))
        #expect(!UsageLimit(usedPercent: 51, resetsAt: reset).isAheadOfPace(in: .fiveHour, now: now))
        #expect(!UsageLimit(usedPercent: 20, resetsAt: reset).isAheadOfPace(in: .fiveHour, now: now))
        #expect(!UsageLimit(usedPercent: 90, resetsAt: nil).isAheadOfPace(in: .fiveHour, now: now))
    }
}
