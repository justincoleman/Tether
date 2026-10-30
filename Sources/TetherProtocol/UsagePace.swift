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

extension UsageLimits {
    /// These limits without any window whose reset time has passed (its
    /// percentage no longer means anything). Nil if nothing is left.
    public func live(at now: Date) -> UsageLimits? {
        func keep(_ limit: UsageLimit?) -> UsageLimit? {
            guard let limit else { return nil }
            if let reset = limit.resetsAt, reset <= now { return nil }
            return limit
        }
        let fiveHour = keep(self.fiveHour), sevenDay = keep(self.sevenDay)
        return fiveHour == nil && sevenDay == nil ? nil : UsageLimits(fiveHour: fiveHour, sevenDay: sevenDay)
    }
}

/// How old a plan limits reading is. Claude Code only reports `rate_limits`
/// from a session that has just made a request, so the age is how long since
/// any tab on the Mac last did.
public enum UsageAge {
    /// Past this the numbers may well have moved (another device, claude.ai).
    public static let staleAfter: TimeInterval = 30 * 60

    public static func isStale(since date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) >= staleAfter
    }

    /// "just now", "12m ago", "3h ago", "2d ago".
    public static func text(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}
