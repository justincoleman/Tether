import Foundation
import Testing
@testable import TetherCore

@Suite struct ElapsedTimeTests {
    @Test func formats() {
        let start = Date(timeIntervalSince1970: 1_000)
        func after(_ s: TimeInterval) -> String { ElapsedTime.short(since: start, now: start.addingTimeInterval(s)) }
        #expect(after(-5) == "0s")
        #expect(after(40) == "40s")
        #expect(after(59.9) == "59s")
        #expect(after(60) == "1m")
        #expect(after(3599) == "59m")
        #expect(after(3600) == "1h 0m")
        #expect(after(3900) == "1h 5m")
    }
}
