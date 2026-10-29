import Foundation

/// Short running times for the sidebar and the menu bar: "40s", "3m", "1h 5m".
public enum ElapsedTime {
    public static func short(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
