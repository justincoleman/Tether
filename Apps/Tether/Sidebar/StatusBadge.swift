import SwiftUI
import TetherProtocol

/// Per-project status: drifting sparkles while Claude works, a pulsing blue
/// dot when it needs you, a green check when it finished.
struct StatusBadge: View {
    @Environment(\.theme) private var theme
    let state: SessionState

    var body: some View {
        Group {
            switch state {
            case .working:
                WorkingSparkles(color: theme.claude)
            case .needsInput:
                PulsingDot(color: theme.blue)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(theme.red)
            case .idle, .detached:
                EmptyView()
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(state.accessibilityText)
    }
}

extension SessionState {
    var accessibilityText: String {
        switch self {
        case .working: "Claude is working"
        case .needsInput: "Claude needs your input"
        case .done: "Claude finished"
        case .error: "Claude hit an error"
        case .idle, .detached: ""
        }
    }

    /// Ring around the project's avatar in the sidebar.
    func ringColor(_ theme: Theme) -> Color? {
        switch self {
        case .working: theme.claude.opacity(0.7)
        case .needsInput: theme.blue
        case .done: theme.green
        case .error: theme.red
        case .idle, .detached: nil
        }
    }
}

private struct WorkingSparkles: View {
    let color: Color

    var body: some View {
        // TimelineView pauses on its own when the window is occluded.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * 1.6 + Double(i) * 2.1
                    Image(systemName: "sparkle")
                        .font(.system(size: 6 + 3 * CGFloat((sin(phase) + 1) / 2)))
                        .foregroundStyle(color)
                        .opacity(0.35 + 0.65 * (sin(phase * 1.3) + 1) / 2)
                        .offset(x: CGFloat(cos(phase * 0.7)) * 5, y: CGFloat(sin(phase * 0.9)) * 5)
                }
            }
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.35)).scaleEffect(pulsing ? 2.2 : 1).opacity(pulsing ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulsing = true }
            }
    }
}
