import SwiftUI
import TetherCore
import TetherProtocol

/// A paired Mac's project with no tab open, and what + shows there: the same
/// page as on this Mac, minus what the companion protocol can't do on another
/// Mac yet (shell tabs, the dev server, shortcuts, ssh).
struct RemoteStartPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let project: ProjectSummary
    /// Whether tabs are open to go back to.
    let hasTabs: Bool
    let start: (AgentKind) -> Void
    let newBranch: () -> Void
    let close: () -> Void
    @State private var recent: [PastSessionInfo]?
    @State private var error: String?

    private static let recentLimit = 5

    var body: some View {
        let online = connection.status == .online
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(spacing: 10) {
                    StartButton(title: "Start Claude", systemImage: "sparkles", shortcut: "", tint: theme.claude) {
                        start(.claude)
                    }
                    StartButton(title: "Start Codex", systemImage: "chevron.left.forwardslash.chevron.right",
                                shortcut: "", tint: theme.codex) {
                        start(.codex)
                    }
                }
                .disabled(!online)
                section("More") {
                    FlowRow {
                        StartPill(title: "Agent on a Branch…", systemImage: "arrow.triangle.branch",
                                  help: "A new branch in its own worktree on \(connection.mac.name), with its own Claude tab") {
                            newBranch()
                        }
                        .disabled(!online)
                    }
                }
                section("Pick up where you left off") { recentList }
                if let error {
                    Text(error).font(.callout).foregroundStyle(theme.red)
                }
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: project.id) {
            guard connection.status == .online else { recent = []; return }
            if case .success(let sessions) = await connection.history(for: project.id) {
                recent = Array(sessions.prefix(Self.recentLimit))
            } else {
                recent = []
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(project.name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(theme.avatarText)
                .frame(width: 56, height: 56)
                .background(theme.avatar(for: project.name), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let branch = project.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Label(connection.mac.name, systemImage: "desktopcomputer")
                        .lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if hasTabs {
                Button("Back to Tabs", action: close)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close this page (Esc)")
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if let recent {
            if recent.isEmpty {
                Text("No conversations in \(project.name) yet.")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            } else {
                let open = Set((connection.snapshot?.sessions ?? []).compactMap(\.sessionId))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent) { session in
                        HistoryRow(title: session.title, firstPrompt: session.firstPrompt,
                                   displayTitle: session.displayTitle, branch: session.branch,
                                   lastActivity: session.lastActivity,
                                   isOpen: open.contains(session.id)) {
                            resume(session)
                        }
                    }
                }
                .padding(.horizontal, -10)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            content()
        }
    }

    private func resume(_ session: PastSessionInfo) {
        error = nil
        Task {
            switch await connection.resumeSession(session.id, projectId: project.id) {
            case .started(let paneId):
                model.remote.selectedProjectId = project.id
                model.remote.selectedPaneId = paneId
                close()
            case .failed(let message):
                error = message
            }
        }
    }
}
