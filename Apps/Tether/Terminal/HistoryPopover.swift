import SwiftUI
import TetherCore
import TetherProtocol

/// Past Claude sessions in this project, newest first, with search. Picking
/// one selects its tab, or resumes it in a new Claude tab.
struct HistoryPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let project: Project
    let dismiss: () -> Void
    @State private var sessions: [PastSession]?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = (sessions ?? []).filter { $0.matches(query) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Past Sessions")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            TextField("Search titles and prompts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = shown.first { resume(first) } }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if sessions == nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if shown.isEmpty {
                Text(query.isEmpty ? "No sessions in \(project.name) yet." : "No sessions match.")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { session in
                            HistoryRow(session: session, isOpen: model.pane(forSession: session.id) != nil) {
                                resume(session)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 440)
        .task {
            searchFocused = true
            sessions = await model.pastSessions(for: project.id)
        }
    }

    private func resume(_ session: PastSession) {
        dismiss()
        Task { await model.openPastSession(session, projectId: project.id) }
    }
}

private struct HistoryRow: View {
    @Environment(\.theme) private var theme
    let session: PastSession
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // The prompt under a generated title says what was asked.
                    if session.title != nil, let prompt = session.firstPrompt {
                        Text(prompt)
                            .font(.callout)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        Text(RelativeTime.string(session.lastActivity))
                        if let branch = session.branch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 8)
                if hovering {
                    Text(isOpen ? "Show" : "Open")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.accent)
                } else if isOpen {
                    Text("In a tab")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.firstPrompt ?? session.displayTitle)
    }
}
