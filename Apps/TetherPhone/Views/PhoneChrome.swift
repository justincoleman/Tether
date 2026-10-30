import SwiftUI
import TetherProtocol
import UIKit

/// A tab's state, drawn like the Mac sidebar's StatusBadge: drifting sparkles
/// while Claude works, a pulsing blue dot when it needs you, a check when it
/// finished. A quiet tab gets a dim dot, not an empty ring that reads as a
/// checkbox.
struct PhoneStatusBadge: View {
    @Environment(\.phoneTheme) private var theme
    let state: SessionState
    var size: CGFloat = 22

    var body: some View {
        Group {
            switch state {
            case .working:
                WorkingSparkles(color: theme.claude, scale: size / 22)
            case .needsInput:
                PulsingDot(color: theme.blue, diameter: size * 0.4)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(theme.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(theme.red)
            case .idle, .detached:
                Circle()
                    .fill(theme.tertiaryText.opacity(0.7))
                    .frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.phoneAccessibilityText)
    }
}

extension SessionState {
    var phoneAccessibilityText: String {
        switch self {
        case .working: "Claude is working"
        case .needsInput: "Claude needs your input"
        case .done: "Claude finished"
        case .error: "Claude hit an error"
        case .idle: "Idle"
        case .detached: "Ended"
        }
    }
}

private struct WorkingSparkles: View {
    let color: Color
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * 1.6 + Double(i) * 2.1
                    Image(systemName: "sparkle")
                        .font(.system(size: (7 + 4 * CGFloat((sin(phase) + 1) / 2)) * scale))
                        .foregroundStyle(color)
                        .opacity(0.35 + 0.65 * (sin(phase * 1.3) + 1) / 2)
                        .offset(x: CGFloat(cos(phase * 0.7)) * 6 * scale, y: CGFloat(sin(phase * 0.9)) * 6 * scale)
                }
            }
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    var diameter: CGFloat = 9
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(color.opacity(0.35)).scaleEffect(pulsing ? 2.4 : 1).opacity(pulsing ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulsing = true }
            }
    }
}

/// Small "Auto" / "Plan" chip for a tab's current mode.
struct PermissionModeTag: View {
    @Environment(\.phoneTheme) private var theme
    let mode: String

    private var risky: Bool { mode == "bypassPermissions" }

    var body: some View {
        // An HStack, not a Label: inside a list row a Label takes the row's
        // wide icon spacing.
        HStack(spacing: 3) {
            Image(systemName: PermissionModeName.symbol(mode))
                .font(.system(size: 9, weight: .bold))
            Text(PermissionModeName.label(mode))
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(risky ? theme.red : theme.secondaryText)
        .background(risky ? theme.red.opacity(0.15) : theme.elevated, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(PermissionModeName.label(mode)) mode")
    }
}

/// Capsule buttons for cards: `prominent` fills with the tint, otherwise a
/// quiet fill. Not the system styles, so several can sit in one list row and
/// each takes its own taps.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.phoneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    var prominent = false
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        let color = tint ?? theme.blue
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, controlSize == .large ? 13 : 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Color.white : (tint ?? theme.text))
            .background(prominent ? color : theme.elevated, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A permission or question waiting on you, with its answer buttons right
/// there. Tapping the text opens the full request.
struct NeedsYouCard: View {
    @Environment(\.phoneTheme) private var theme
    let connection: MacConnection
    let request: PermissionRequested
    /// "Tether · Claude": which tab is asking, when that isn't obvious.
    var context: String?
    /// Draws its own tinted card and border. Off inside a List, which draws
    /// `NeedsYouCard.rowBackground` instead so its rounded clip can't cut the border.
    var framed = true
    let open: () -> Void

    private var icon: String {
        if request.isFolderTrust { return "folder.badge.questionmark" }
        if request.question != nil { return "questionmark.bubble.fill" }
        return "hand.raised.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(theme.blue, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        if let context {
                            Text(context)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.blue)
                                .lineLimit(1)
                        }
                        Text(request.heading)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if request.question == nil, !request.detail.isEmpty {
                            Text(request.detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.top, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the whole request")

            HStack(spacing: 8) {
                if request.question != nil {
                    Button("Skip") { decide(false) }
                        .buttonStyle(PillButtonStyle())
                    Button("Answer", action: open)
                        .buttonStyle(PillButtonStyle(prominent: true))
                } else {
                    Button(request.isFolderTrust ? "Don't Trust" : "Deny") { decide(false) }
                        .buttonStyle(PillButtonStyle(tint: theme.red))
                    Button(request.isFolderTrust ? "Trust Folder" : "Allow") { decide(true) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .disabled(connection.status != .online)
        }
        .padding(framed ? 14 : 2)
        .padding(.vertical, framed ? 0 : 6)
        .background {
            if framed {
                Self.rowBackground(theme)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.blue.opacity(0.4)))
            }
        }
    }

    /// The card's blue-washed fill, for `.listRowBackground`.
    static func rowBackground(_ theme: PhoneTheme) -> some View {
        theme.card.overlay(theme.blue.opacity(0.12))
    }

    private func decide(_ allow: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(allow ? .success : .warning)
        connection.decide(request.id, allow: allow)
    }
}

/// The 5-hour and weekly plan limits as two rings, like the Mac sidebar's:
/// small and colored at rest, and a tap opens them into percent, name, time to
/// reset and how fresh the reading is. A tick on each ring marks how far into
/// its window you are.
struct UsageCard: View {
    @Environment(\.phoneTheme) private var theme
    let limits: UsageLimits
    /// When the Mac's status line last reported them, if it says.
    var updatedAt: Date?
    var macName: String?
    @State private var expanded = false

    private struct Row {
        var title: String
        var short: String
        var window: UsageWindow
        var limit: UsageLimit
    }

    var body: some View {
        // Re-evaluated each minute: a window can end, and the reading ages,
        // with no new snapshot from the Mac.
        TimelineView(.everyMinute) { context in
            let now = context.date
            let live = limits.live(at: now)
            let stale = updatedAt.map { UsageAge.isStale(since: $0, now: now) } ?? false
            VStack(spacing: expanded ? 12 : 0) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text(macName.map { "Plan usage · \($0)" } ?? "Plan usage")
                    Spacer(minLength: 8)
                    if let live, !expanded {
                        HStack(spacing: 10) {
                            ForEach(rows(live), id: \.title) { row in ring(row, now: now, size: 26) }
                        }
                        .opacity(stale ? 0.5 : 1)
                    } else if live == nil {
                        Text("Reset").font(.caption2)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                if expanded {
                    if let live {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(rows(live), id: \.title) { row in
                                VStack(spacing: 5) {
                                    ring(row, now: now, size: 62)
                                    Text(row.title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                                    if let left = row.limit.timeLeftText(now: now) {
                                        Text("resets in \(left)").font(.caption).foregroundStyle(theme.secondaryText)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .opacity(stale ? 0.6 : 1)
                    } else {
                        Text("Those windows have reset. New numbers arrive with the next reply in a Claude tab on the Mac.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    if let updatedAt {
                        Text(stale ? "Last reading \(UsageAge.text(since: updatedAt, now: now))"
                                   : "Updated \(UsageAge.text(since: updatedAt, now: now))")
                            .font(.caption2)
                            .foregroundStyle(stale ? theme.claude : theme.tertiaryText)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .animation(.smooth(duration: 0.28), value: expanded)
            .accessibilityElement(children: .combine)
            .accessibilityHint(expanded ? "Collapse" : "Expand")
        }
    }

    private func rows(_ limits: UsageLimits) -> [Row] {
        var rows: [Row] = []
        if let limit = limits.fiveHour { rows.append(Row(title: "5-hour", short: "5h", window: .fiveHour, limit: limit)) }
        if let limit = limits.sevenDay { rows.append(Row(title: "Weekly", short: "Week", window: .sevenDay, limit: limit)) }
        return rows
    }

    /// Green within pace, orange once ahead of it, red from 90%.
    private func ring(_ row: Row, now: Date, size: CGFloat) -> some View {
        let used = row.limit.usedPercent
        let fraction = min(max(used, 0), 100) / 100
        let line: CGFloat = size > 40 ? 6 : 4
        let ahead = row.limit.isAheadOfPace(in: row.window, now: now)
        let tint = used >= 90 ? theme.red : ahead ? theme.claude : theme.green
        return ZStack {
            Circle().stroke(theme.border.opacity(0.7), lineWidth: line)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let pace = row.limit.paceFraction(in: row.window, now: now) {
                Capsule()
                    .fill(theme.text)
                    .frame(width: 1.5, height: line + 3)
                    .offset(y: -size / 2 + line / 2)
                    .rotationEffect(.degrees(pace * 360))
            }
            if size > 40 {
                Text("\(Int(used.rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(row.title) limit")
        .accessibilityValue("\(Int(used.rounded())) percent used")
    }
}

/// One chip per paired Mac with a status dot, like the Mac sidebar's chips.
struct MacStatusChip: View {
    @Environment(\.phoneTheme) private var theme
    let connection: MacConnection

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Image(systemName: "desktopcomputer").font(.caption2)
            Text(connection.mac.name).font(.caption.weight(.semibold)).lineLimit(1)
            if connection.status != .online {
                Text(statusText).font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.border.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private var dot: Color {
        switch connection.status {
        case .online: theme.green
        case .connecting: theme.claude
        case .offline, .updateNeeded, .rejected: theme.red
        }
    }

    private var statusText: String {
        switch connection.status {
        case .online: "Online"
        case .connecting: "Connecting…"
        case .offline: "Offline"
        case .updateNeeded: "Update needed"
        case .rejected: "Not paired"
        }
    }
}

/// Why a Mac isn't connected, as a quiet card under the chips.
struct MacNotice: View {
    @Environment(\.phoneTheme) private var theme
    let connection: MacConnection

    private var notice: (icon: String, title: String, detail: String)? {
        let name = connection.mac.name
        switch connection.status {
        case .online, .connecting:
            return nil
        case .offline(let reason):
            return ("wifi.slash", "Can't reach \(name)", "\(reason). Is Tether open there and Tailscale on?")
        case .updateNeeded:
            return ("arrow.down.circle", "\(name) needs an update", "Update Tether on the Mac and this iPhone so they match.")
        case .rejected(let reason):
            return ("exclamationmark.triangle", "\(name) turned this iPhone away", "\(reason) Pair again from the menu.")
        }
    }

    var body: some View {
        if let notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.claude)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                    Text(notice.detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Dims and shrinks a little while pressed, for buttons that draw their own card.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A question Claude asked, as the phone shows it: each option a numbered
/// card (the numbers match the terminal's), then a field for an answer of
/// your own. The Mac keeps the shared, more compact QuestionOptionsView.
struct PhoneQuestionView: View {
    @Environment(\.phoneTheme) private var theme
    let question: QuestionPrompt
    let answer: (String) -> Void
    let skip: () -> Void
    @State private var other = ""

    private var canSendOther: Bool { !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(theme.blue, in: Circle())
                    Text(question.header.isEmpty ? "Claude asks" : question.header)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.blue)
                }
                Text(question.question)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button { answer(option.label) } label: {
                        optionCard(number: index + 1, option: option)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            HStack(spacing: 4) {
                TextField("Something else…", text: $other)
                    .foregroundStyle(theme.text)
                    .submitLabel(.send)
                    .onSubmit(sendOther)
                    .padding(.leading, 14)
                    .padding(.vertical, 11)
                Button(action: sendOther) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSendOther ? Color.white : theme.tertiaryText)
                        .frame(width: 32, height: 32)
                        .background(canSendOther ? theme.blue : theme.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSendOther)
                .padding(4)
                .accessibilityLabel("Send answer")
            }
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border.opacity(0.7)))
            Button("Skip Question", action: skip)
                .buttonStyle(PillButtonStyle(tint: theme.red))
        }
    }

    private func optionCard(number: Int, option: QuestionPrompt.Option) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(theme.blue)
                .frame(width: 26, height: 26)
                .background(theme.blue.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.text)
                if !option.description.isEmpty, option.description != option.label {
                    Text(option.description)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.top, 2)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.tertiaryText)
                .padding(.top, 7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border.opacity(0.7)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sendOther() {
        let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer(text)
    }
}
