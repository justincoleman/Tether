import Foundation

/// How far into a plan window the clock is, to compare with how much of it
/// has been used. Not on the wire: the windows' lengths are fixed.
public enum UsageWindow: Sendable {
    case fiveHour, sevenDay

    public var length: TimeInterval {
        switch self {
        case .fiveHour: 5 * 3600
        case .sevenDay: 7 * 86_400
        }
    }
}

extension UsageLimit {
    /// The share (0...1) of `window` that has passed at `now`, from the reset
    /// time. Nil without a reset time, or when it's more than a window away
    /// (a stale reading).
    public func paceFraction(in window: UsageWindow, now: Date) -> Double? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining <= window.length else { return nil }
        return min(max(1 - remaining / window.length, 0), 1)
    }

    /// Used more of the window than the time that has passed, by more than a
    /// couple of points: at this rate the limit runs out before it refills.
    public func isAheadOfPace(in window: UsageWindow, now: Date) -> Bool {
        guard let pace = paceFraction(in: window, now: now) else { return false }
        return usedPercent / 100 > pace + 0.02
    }
}
