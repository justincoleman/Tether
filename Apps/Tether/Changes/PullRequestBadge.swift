import AppKit
import SwiftUI
import TetherCore

/// "#12" with the checks' state. Clicking opens the pull request on GitHub.
struct PullRequestBadge: View {
    @Environment(\.theme) private var theme
    let status: PullRequestStatus

    var body: some View {
        Button {
            if let url = URL(string: status.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(status.isDraft ? "#\(status.number) draft" : "#\(status.number)")
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.caption)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Pull request \(status.number), \(stateText). \(status.checksSummary)")
    }

    private var symbol: String {
        switch status.state {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .open:
            switch status.checks {
            case .failing: return "xmark.circle.fill"
            case .pending: return "clock.fill"
            case .passing: return "checkmark.circle.fill"
            case .none: return "arrow.triangle.pull"
            }
        }
    }

    private var color: Color {
        guard status.state == .open else { return theme.secondaryText }
        switch status.checks {
        case .failing: return theme.red
        case .pending: return theme.claude
        case .passing: return theme.green
        case .none: return theme.secondaryText
        }
    }

    private var stateText: String {
        switch status.state {
        case .merged: return "merged"
        case .closed: return "closed"
        case .open: return status.isDraft ? "draft" : "open"
        }
    }

    private var help: String {
        "#\(status.number) \(status.title) (\(stateText))\n\(status.checksSummary)\nClick to open on GitHub."
    }
}
