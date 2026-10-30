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

@Suite struct UsageFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func windowsThatHaveResetDropOut() throws {
        let limits = UsageLimits(fiveHour: UsageLimit(usedPercent: 40, resetsAt: now.addingTimeInterval(-1)),
                                 sevenDay: UsageLimit(usedPercent: 10, resetsAt: now.addingTimeInterval(3600)))
        let live = try #require(limits.live(at: now))
        #expect(live.fiveHour == nil)
        #expect(live.sevenDay?.usedPercent == 10)
        let both = UsageLimits(fiveHour: limits.fiveHour, sevenDay: UsageLimit(usedPercent: 1, resetsAt: now))
        #expect(both.live(at: now) == nil)
    }

    @Test func ageReadsInTheLargestUnit() {
        func text(_ seconds: TimeInterval) -> String { UsageAge.text(since: now.addingTimeInterval(-seconds), now: now) }
        #expect(text(5) == "just now")
        #expect(text(12 * 60) == "12m ago")
        #expect(text(3 * 3600 + 59) == "3h ago")
        #expect(text(2 * 86_400) == "2d ago")
        // A clock a little behind the Mac's doesn't read as the future.
        #expect(text(-30) == "just now")
    }

    @Test func staleAfterHalfAnHour() {
        #expect(!UsageAge.isStale(since: now.addingTimeInterval(-29 * 60), now: now))
        #expect(UsageAge.isStale(since: now.addingTimeInterval(-30 * 60), now: now))
    }

    @Test func snapshotCarriesWhenLimitsWereReported() throws {
        let reported = now.addingTimeInterval(-600)
        let snapshot = Snapshot(macName: "m", projects: [], sessions: [], permissions: [],
                                limits: UsageLimits(fiveHour: UsageLimit(usedPercent: 3, resetsAt: nil), sevenDay: nil),
                                limitsAt: reported)
        let data = try WireCodec.encoder().encode(MacMessage.snapshot(snapshot))
        guard case .snapshot(let decoded) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(decoded.limitsAt == reported)
        // An older Mac's snapshot has no such key.
        let old = try WireCodec.encoder().encode(MacMessage.snapshot(
            Snapshot(macName: "m", projects: [], sessions: [], permissions: [])))
        guard case .snapshot(let oldDecoded) = try WireCodec.decoder().decode(MacMessage.self, from: old) else {
            Issue.record("wrong case"); return
        }
        #expect(oldDecoded.limitsAt == nil)
    }
}

@Suite struct UsageTimeLeftTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func timeLeftReadsInTheLargestTwoUnits() {
        func left(_ seconds: TimeInterval) -> String? {
            UsageLimit(usedPercent: 1, resetsAt: now.addingTimeInterval(seconds)).timeLeftText(now: now)
        }
        #expect(left(12 * 60 + 5) == "12m")
        #expect(left(3 * 3600 + 34 * 60) == "3h 34m")
        #expect(left(31 * 3600) == "1d 7h")
        #expect(left(30) == nil)
        #expect(left(-5) == nil)
        #expect(UsageLimit(usedPercent: 1, resetsAt: nil).timeLeftText(now: now) == nil)
    }
}
