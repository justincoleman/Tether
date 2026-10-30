import SwiftUI
import TetherCore
import TetherProtocol

/// The plan's 5-hour and weekly limits at the bottom of the sidebar. At rest,
/// two small colored rings; hover and they grow into a card with the percent
/// inside each ring, its name and the time until it resets. A tick on each ring
/// marks how far into its window you are, so a ring past its tick is using the
/// limit faster than it refills. Nothing shows until Claude Code has reported
/// limits. On a paired Mac they show that Mac's limits, not this one's.
struct LimitRings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("showLimitRings") private var showRings = true
    @AppStorage("showLimitPace") private var showPace = true
    @State private var hovering = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            // A paired Mac has its own account and its own limits.
            let reported = model.remote.selectedConnection.map { $0.snapshot?.limits } ?? model.usageLimits
            let reportedAt = model.remote.selectedConnection.map { $0.snapshot?.limitsAt } ?? model.usageLimitsAt
            let stale = reportedAt.map { UsageAge.isStale(since: $0, now: now) } ?? false
            if showRings, let limits = reported.flatMap({ SavedLimits.current($0, now: now) }) {
                let rows = Self.rows(limits)
                VStack(spacing: 8) {
                    HStack(spacing: hovering ? 28 : 14) {
                        ForEach(rows, id: \.title) { row in
                            VStack(spacing: 5) {
                                Ring(used: row.limit.usedPercent,
                                     pace: showPace ? row.limit.paceFraction(in: row.window, now: now) : nil,
                                     ahead: row.limit.isAheadOfPace(in: row.window, now: now),
                                     expanded: hovering)
                                if hovering {
                                    VStack(spacing: 1) {
                                        Text(row.short)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(theme.text)
                                        if let left = row.limit.timeLeftText(now: now) {
                                            Text(left)
                                                .font(.caption)
                                                .foregroundStyle(theme.secondaryText)
                                        }
                                    }
                                    .transition(.opacity)
                                }
                            }
                        }
                    }
                    // Dimmed once the reading is old: the numbers may have moved.
                    .opacity(stale && !hovering ? 0.5 : 1)
                    if hovering, showPace {
                        Text("Tick: how far through the window you are")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                            .transition(.opacity)
                    }
                    if hovering, let reportedAt {
                        Text(stale ? "Last reading \(UsageAge.text(since: reportedAt, now: now))"
                                   : "Updated \(UsageAge.text(since: reportedAt, now: now))")
                            .font(.caption2)
                            .foregroundStyle(stale ? theme.claude : theme.secondaryText)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, hovering ? 12 : 8)
                .frame(maxWidth: .infinity)
                .background(hovering ? theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.border.opacity(hovering ? 0.6 : 0), lineWidth: 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.smooth(duration: 0.28), value: hovering)
                .help(rows.map(Self.summary).joined(separator: "\n"))
            }
        }
    }

    struct Row {
        var title: String
        var short: String
        var window: UsageWindow
        var limit: UsageLimit
    }

    static func rows(_ limits: UsageLimits) -> [Row] {
        var rows: [Row] = []
        if let limit = limits.fiveHour { rows.append(Row(title: "5-hour", short: "5h", window: .fiveHour, limit: limit)) }
        if let limit = limits.sevenDay { rows.append(Row(title: "Weekly", short: "Week", window: .sevenDay, limit: limit)) }
        return rows
    }

    static func summary(_ row: Row) -> String {
        "\(row.title): \(Int(row.limit.usedPercent.rounded()))% used"
            + (row.limit.resetsAt.map { ", resets \($0.formatted(.relative(presentation: .named)))" } ?? "")
    }

    /// A ring filled to `used` percent, with a tick at `pace` (0...1). Green
    /// while you're within pace, orange once ahead of it, red from 90%.
    private struct Ring: View {
        @Environment(\.theme) private var theme
        let used: Double
        let pace: Double?
        let ahead: Bool
        let expanded: Bool

        var body: some View {
            let size: CGFloat = expanded ? 46 : 22
            let line: CGFloat = expanded ? 5 : 3.5
            let fraction = min(max(used, 0), 100) / 100
            let tint = used >= 90 ? theme.red : ahead ? theme.claude : theme.green
            ZStack {
                Circle().stroke(theme.border.opacity(0.7), lineWidth: line)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let pace {
                    // A short radial line across the ring at the pace angle.
                    Capsule()
                        .fill(theme.text)
                        .frame(width: 1.5, height: line + 3)
                        .offset(y: -size / 2 + line / 2)
                        .rotationEffect(.degrees(pace * 360))
                }
                if expanded {
                    Text("\(Int(used.rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.text)
                        .transition(.opacity)
                }
            }
            .frame(width: size, height: size)
        }
    }
}
