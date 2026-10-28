import ActivityKit
import SwiftUI
import TetherProtocol
import WidgetKit

@main
struct TetherWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionActivityWidget()
    }
}

/// A running Claude tab on the Lock Screen and in the Dynamic Island:
/// project, status, elapsed time, steps and the latest message.
struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, content: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(deepLink(context.attributes))
        } dynamicIsland: { context in
            let content = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.projectName, systemImage: content.symbol)
                        .font(.headline)
                        .foregroundStyle(content.tint)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(content: content).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.statusLine).font(.subheadline.weight(.semibold))
                        if !content.detail.isEmpty {
                            Text(content.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: content.symbol).foregroundStyle(content.tint)
            } compactTrailing: {
                ElapsedText(content: content).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: content.symbol).foregroundStyle(content.tint)
            }
            .widgetURL(deepLink(context.attributes))
        }
    }

    private func deepLink(_ a: LiveActivityAttributes) -> URL? {
        URL(string: "tether://session?mac=\(a.macId)&pane=\(a.paneId)")
    }
}

private struct LockScreenView: View {
    let attributes: LiveActivityAttributes
    let content: LiveActivityContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: content.symbol).foregroundStyle(content.tint)
                Text(attributes.projectName).font(.headline).foregroundStyle(.white)
                Text(attributes.title).font(.subheadline).foregroundStyle(.white.opacity(0.6))
                Spacer()
                ElapsedText(content: content)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(content.statusLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(content.tint)
            if !content.detail.isEmpty {
                Text(content.detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
    }
}

/// Counts up while Claude works; a fixed duration once it's over.
private struct ElapsedText: View {
    let content: LiveActivityContent

    var body: some View {
        let start = Date(timeIntervalSince1970: content.startedAt)
        if content.isActive {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
        } else {
            Text(Duration.seconds(max(0, Date().timeIntervalSince(start))),
                 format: .time(pattern: .minuteSecond))
        }
    }
}

extension LiveActivityContent {
    var isActive: Bool { state == "working" || state == "needsInput" }

    var symbol: String {
        switch state {
        case "working": "sparkles"
        case "needsInput": "hand.raised.fill"
        case "done": "checkmark.circle.fill"
        case "error": "exclamationmark.triangle.fill"
        default: "circle"
        }
    }

    var tint: Color {
        switch state {
        case "working": .orange
        case "needsInput": .blue
        case "done": .green
        case "error": .red
        default: .gray
        }
    }

    var statusLine: String {
        let stepText = steps == 1 ? "1 step" : "\(steps) steps"
        switch state {
        case "working": return steps > 0 ? "Working · \(stepText)" : "Working"
        case "needsInput": return "Needs you"
        case "done": return steps > 0 ? "Done · \(stepText)" : "Done"
        case "error": return "Hit an error"
        default: return "Stopped"
        }
    }
}
