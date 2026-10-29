import SwiftUI
import TetherProtocol

/// "This Mac" and one chip per paired Mac, at the top of the sidebar. Picking
/// a paired Mac swaps the sidebar to that Mac's projects and Claude tabs.
struct MacChips: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let remote = model.remote
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("This Mac", dot: nil, selected: remote.selectedMacId == nil) {
                    remote.selectedMacId = nil
                }
                ForEach(remote.connections) { connection in
                    chip(connection.mac.name, dot: color(of: connection.status),
                         selected: remote.selectedMacId == connection.id) {
                        remote.selectedMacId = connection.id
                        remote.selectedPaneId = nil
                    }
                }
                Button { openSettings() } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(theme.border))
                }
                .buttonStyle(.plain)
                .help("Pair another Mac in Settings → Macs")
            }
            .padding(.horizontal, 8)
        }
    }

    private func chip(_ title: String, dot: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? theme.text : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? theme.elevated : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? theme.border : .clear))
        }
        .buttonStyle(.plain)
    }

    private func color(of status: MacConnection.Status) -> Color {
        switch status {
        case .online: theme.green
        case .connecting: theme.claude
        case .offline, .updateNeeded, .rejected: theme.red
        }
    }
}

/// A paired Mac's projects, each with its Claude tabs, in the sidebar.
struct RemoteProjectList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let connection: MacConnection

    var body: some View {
        let snapshot = connection.snapshot
        let projects = snapshot?.projects ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects on \(connection.mac.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if let message = statusMessage(projectCount: projects.count) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(projects) { project in
                    let sessions = (snapshot?.sessions ?? []).filter { $0.projectId == project.id }
                    RemoteProjectRow(connection: connection, project: project, sessions: sessions)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func statusMessage(projectCount: Int) -> String? {
        switch connection.status {
        case .online:
            return projectCount == 0 ? "No projects open on \(connection.mac.name)." : nil
        case .connecting:
            return "Connecting to \(connection.mac.name)…"
        case .offline(let reason):
            return "Can't reach \(connection.mac.name): \(reason). Is Tether open there and Tailscale on?"
        case .updateNeeded:
            return "Update Tether on both Macs to the same version."
        case .rejected(let reason):
            return "\(reason) Pair again in Settings → Macs."
        }
    }
}

private struct RemoteProjectRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("useProjectIcons") private var useProjectIcons = true
    let connection: MacConnection
    let project: ProjectSummary
    let sessions: [SessionSummary]
    @State private var hovering = false

    var body: some View {
        let remote = model.remote
        let state = sessions.map(\.state).max { $0.urgency < $1.urgency } ?? .idle
        let first = sessions.max { $0.state.urgency < $1.state.urgency }
        let selected = sessions.contains { $0.id == remote.selectedPaneId }
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                ProjectAvatar(name: project.name, state: state,
                              icon: useProjectIcons ? connection.projectIcons[project.id] : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(project.branch ?? (sessions.isEmpty ? "No Claude tab" : ""))
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 4)
                StatusBadge(state: state)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? theme.elevated : hovering ? theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border) }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let first { remote.selectedPaneId = first.id }
            }
            .onHover { hovering = $0 }
            // More than one tab: list each, so any of them can be opened.
            if sessions.count > 1 {
                ForEach(sessions) { session in
                    HStack(spacing: 8) {
                        StatusBadge(state: session.state).scaleEffect(0.8)
                        Text(session.preview ?? session.title)
                            .font(.callout)
                            .lineLimit(1)
                            .foregroundStyle(remote.selectedPaneId == session.id ? theme.text : theme.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 38)
                    .padding(.trailing, 10)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { remote.selectedPaneId = session.id }
                }
            }
        }
    }
}

/// The main area while a paired Mac is selected: the chosen Claude tab's
/// conversation, with permissions and a message box.
struct RemoteDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let connection: MacConnection
    @Binding var showSidebar: Bool

    var body: some View {
        let paneId = model.remote.selectedPaneId
        VStack(spacing: 0) {
            HStack {
                if !showSidebar {
                    ChromeButton(systemImage: "sidebar.left", help: "Show sidebar (⌃⌘S)") { showSidebar = true }
                }
                Spacer()
            }
            .padding(.leading, showSidebar ? 0 : ChromeMetrics.trafficLightsWidth)
            .frame(height: ChromeMetrics.headerHeight)
            Group {
                if let paneId {
                    RemoteSessionView(connection: connection, paneId: paneId)
                        .id(paneId)
                } else {
                    ContentUnavailableView("Pick a Claude tab", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Choose a project on \(connection.mac.name) in the sidebar."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
            .padding(.bottom, 8)
        }
    }
}
