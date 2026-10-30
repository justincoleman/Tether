import SwiftUI
import TetherProtocol

/// The plan's 5-hour and weekly limits as two small rings at the bottom of
/// the sidebar. A tick on each ring marks how far into its window you are;
/// a ring that has passed its tick is using the limit faster than it refills.
/// Hover for the numbers, click for the detail. Nothing shows until Claude
/// Code has reported limits.
struct LimitRings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("showLimitRings") private var showRings = true
    @AppStorage("showLimitPace") private var showPace = true
    @State private var showDetail = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            if showRings, let limits = model.usageLimits.flatMap({ SavedLimits.current($0, now: now) }) {
                let rows = Self.rows(limits)
                Button { showDetail.toggle() } label: {
                    HStack(spacing: 14) {
                        ForEach(rows, id: \.title) { row in
                            HStack(spacing: 6) {
                                Ring(used: row.limit.usedPercent,
                                     pace: showPace ? row.limit.paceFraction(in: row.window, now: now) : nil,
                                     ahead: row.limit.isAheadOfPace(in: row.window, now: now))
                                Text(row.short)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(rows.map(Self.summary).joined(separator: "\n"))
                .popover(isPresented: $showDetail, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Plan limits").font(.headline)
                        ForEach(rows, id: \.title) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(row.title): \(Int(row.limit.usedPercent.rounded()))% used")
                                    .font(.body.weight(.medium))
                                Text(Self.detail(row, now: now))
                                    .font(.callout)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Text("Reported by Claude Code after each reply, shared by every tab on your account.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(14)
                    .frame(width: 280, alignment: .leading)
                }
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

    private static func resets(_ limit: UsageLimit) -> String? {
        limit.resetsAt.map { "resets \($0.formatted(.relative(presentation: .named)))" }
    }

    static func summary(_ row: Row) -> String {
        "\(row.title): \(Int(row.limit.usedPercent.rounded()))% used"
            + (resets(row.limit).map { ", \($0)" } ?? "")
    }

    static func detail(_ row: Row, now: Date) -> String {
        var parts: [String] = []
        if let pace = row.limit.paceFraction(in: row.window, now: now) {
            parts.append("\(Int((pace * 100).rounded()))% of the window has passed")
            parts.append(row.limit.isAheadOfPace(in: row.window, now: now)
                         ? "using it faster than it refills" : "on pace")
        }
        if let reset = resets(row.limit) { parts.append(reset) }
        guard let first = parts.first else { return "No reset time reported yet" }
        return (first.prefix(1).uppercased() + first.dropFirst()) + parts.dropFirst().map { ", " + $0 }.joined()
    }

    /// A ring filled to `used` percent, with a tick at `pace` (0...1).
    private struct Ring: View {
        @Environment(\.theme) private var theme
        let used: Double
        let pace: Double?
        let ahead: Bool
        private let size: CGFloat = 20

        var body: some View {
            let fraction = min(max(used, 0), 100) / 100
            let tint = used >= 90 ? theme.red : ahead ? theme.claude : theme.secondaryText
            ZStack {
                Circle().stroke(theme.border, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                if let pace {
                    // A short radial line across the ring at the pace angle.
                    Capsule()
                        .fill(theme.text)
                        .frame(width: 1.5, height: 7)
                        .offset(y: -size / 2 + 1)
                        .rotationEffect(.degrees(pace * 360))
                }
            }
            .frame(width: size, height: size)
        }
    }
}
