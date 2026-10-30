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
                        remote.selectedProjectId = nil
                    }
                }
                Button {
                    UserDefaults.standard.set("macs", forKey: "settingsTab")
                    openSettings()
                } label: {
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
    @State private var showingNewTab = false
    @State private var newTabProjectId: ProjectID?
    @State private var showInactive = false

    var body: some View {
        let snapshot = connection.snapshot
        let projects = snapshot?.projects ?? []
        let inactive = projects.filter { !$0.active }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projects on \(connection.mac.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button {
                    newTabProjectId = projects.first?.id
                    showingNewTab = true
                } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .disabled(connection.status != .online || projects.isEmpty)
                .help("New Claude or Codex tab on \(connection.mac.name)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if connection.status == .online, projects.isEmpty {
                Text("No projects open on \(connection.mac.name).")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            List {
                // The other Mac sends pinned, then Active, then Inactive.
                ForEach(projects.filter(\.active)) { project in
                    row(project, sessions: snapshot?.sessions ?? [])
                }
                if !inactive.isEmpty {
                    InactiveHeader(count: inactive.count, expanded: $showInactive)
                        .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 2, trailing: 8))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if showInactive {
                        ForEach(inactive) { project in
                            row(project, sessions: snapshot?.sessions ?? [])
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showingNewTab) {
            NewRemoteTabSheet(connection: connection, projectId: newTabProjectId)
        }
    }
}

extension RemoteProjectList {
    private func row(_ project: ProjectSummary, sessions all: [SessionSummary]) -> some View {
        RemoteProjectRow(connection: connection, project: project,
                         sessions: all.filter { $0.projectId == project.id }) {
            newTabProjectId = project.id
            showingNewTab = true
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// Something wrong with the selected Mac, as a quiet card at the bottom of
/// the sidebar. The chip's dot already says it's not connected; this says
/// why and can be closed.
struct MacNoticeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let connection: MacConnection

    private struct Notice {
        var key: String
        var icon: String
        var title: String
        var detail: String
    }

    private var notice: Notice? {
        let name = connection.mac.name
        let id = connection.id.uuidString
        switch connection.status {
        case .online, .connecting:
            return nil
        case .updateNeeded(let version):
            return Notice(key: "\(id)-update-\(version)", icon: "arrow.down.circle",
                          title: "\(name) needs an update",
                          detail: "Update Tether on both Macs so they match.")
        case .offline(let reason):
            return Notice(key: "\(id)-offline", icon: "wifi.slash",
                          title: "Can't reach \(name)",
                          detail: "\(reason). Is Tether open there and Tailscale on?")
        case .rejected(let reason):
            return Notice(key: "\(id)-rejected", icon: "exclamationmark.triangle",
                          title: "\(name) turned us away",
                          detail: "\(reason) Pair again in Settings → Macs.")
        }
    }

    var body: some View {
        if let notice, !model.remote.dismissedNotices.contains(notice.key) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.claude)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(.callout.weight(.semibold))
                    Text(notice.detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    model.remote.dismissedNotices.insert(notice.key)
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("Hide")
            }
            .padding(10)
            .background(theme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .transition(.opacity)
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
    let newTab: () -> Void
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
                remote.selectedProjectId = project.id
                remote.selectedPaneId = first?.id
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("New Claude or Codex Tab…", action: newTab)
                    .disabled(connection.status != .online)
                Divider()
                Button(project.pinned ? "Unpin" : "Pin to Top") {
                    connection.setProjectPinned(project.id, !project.pinned)
                }
                .disabled(connection.status != .online)
                Button(project.active ? "Move to Inactive" : "Make Active") {
                    connection.setProjectActive(project.id, !project.active)
                }
                .disabled(connection.status != .online)
            }
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
                    .onTapGesture {
                        remote.selectedProjectId = project.id
                        remote.selectedPaneId = session.id
                    }
                }
            }
        }
    }
}

/// The main area while a paired Mac is selected. Laid out like a local
/// project: a strip of that project's Claude tabs with the same buttons, over
/// the chat card. The terminal itself stays on the other Mac.
struct RemoteDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let connection: MacConnection
    @Binding var showSidebar: Bool
    @State private var showNewTab = false
    @State private var showHistory = false
    @State private var starting = false
    @State private var showStart = false

    private var sessions: [SessionSummary] { connection.snapshot?.sessions ?? [] }

    /// The project the strip shows: the picked one, else the selected tab's.
    private var projectId: ProjectID? {
        model.remote.selectedProjectId
            ?? sessions.first { $0.id == model.remote.selectedPaneId }?.projectId
    }

    private var project: ProjectSummary? {
        projectId.flatMap { id in connection.snapshot?.projects.first { $0.id == id } }
    }

    var body: some View {
        let paneId = model.remote.selectedPaneId
        let tabs = sessions.filter { $0.projectId == projectId }
        VStack(spacing: 0) {
            header(tabs: tabs)
            Group {
                let hasTab = paneId.map { id in sessions.contains { $0.id == id } } ?? false
                if let project, showStart || !hasTab {
                    RemoteStartPage(connection: connection, project: project, hasTabs: hasTab,
                                    start: { start($0) }, newBranch: { showNewTab = true },
                                    close: { showStart = false })
                        .id(project.id)
                } else if let paneId, hasTab {
                    RemoteSessionView(connection: connection, paneId: paneId, showsHeader: false)
                        .id(paneId)
                } else {
                    ContentUnavailableView("Pick a project",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Choose a project on \(connection.mac.name) in the sidebar."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5))
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showNewTab) {
            NewRemoteTabSheet(connection: connection, projectId: projectId)
        }
        // Picking a tab or another project leaves the start page.
        .onChange(of: model.remote.selectedPaneId) { showStart = false }
        .onChange(of: projectId) { showStart = false }
    }

    private func header(tabs: [SessionSummary]) -> some View {
        let online = connection.status == .online
        let canStart = online && projectId != nil && !starting
        return HStack(spacing: 4) {
            if !showSidebar {
                ChromeButton(systemImage: "sidebar.left", help: "Show sidebar (⌃⌘S)") { showSidebar = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { session in
                        RemoteTabButton(session: session, selected: session.id == model.remote.selectedPaneId) {
                            model.remote.selectedPaneId = session.id
                        } close: {
                            connection.closeSession(paneId: session.id)
                            if model.remote.selectedPaneId == session.id { model.remote.selectedPaneId = nil }
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            ToolbarPill(title: "Claude", systemImage: "sparkles", iconColor: theme.claude,
                        help: "New Claude tab on \(connection.mac.name)") { start(.claude) }
                .disabled(!canStart)
            ToolbarPill(title: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", iconColor: theme.codex,
                        help: "New Codex tab on \(connection.mac.name)") { start(.codex) }
                .disabled(!canStart)
            ToolbarPill(title: "History", systemImage: "clock.arrow.circlepath",
                        help: "Past sessions on \(connection.mac.name)") { showHistory.toggle() }
                .disabled(!online || projectId == nil)
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    if let projectId {
                        RemoteHistoryPopover(connection: connection, projectId: projectId) { showHistory = false }
                            .environment(model)
                            .environment(\.theme, theme)
                    }
                }
            ChromeButton(systemImage: "plus", active: showStart,
                         help: "New tab on \(connection.mac.name)") { showStart.toggle() }
                .disabled(!online || projectId == nil)
            ChromeButton(systemImage: "sidebar.right", active: model.showInspector,
                         help: "Changes on \(connection.mac.name)") { model.toggleInspector() }
                .disabled(model.remote.selectedPaneId == nil)
        }
        .padding(.leading, showSidebar ? 0 : ChromeMetrics.trafficLightsWidth)
        .frame(height: ChromeMetrics.headerHeight)
    }

    private func start(_ agent: AgentKind) {
        guard let projectId else { return }
        starting = true
        Task {
            if case .started(let paneId) = await connection.startSession(
                projectId: projectId, branch: nil, prompt: "", permissionMode: nil, agent: agent) {
                model.remote.selectedPaneId = paneId
                showStart = false
            }
            starting = false
        }
    }
}

/// One of a paired Mac's Claude tabs, drawn like a local tab.
private struct RemoteTabButton: View {
    @Environment(\.theme) private var theme
    let session: SessionSummary
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.agent == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkles")
                .font(.caption)
                .foregroundStyle(session.agent == .codex ? theme.codex : theme.claude)
            Text(session.title)
                .font(.callout.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? theme.text : theme.secondaryText)
                .lineLimit(1)
            StatusBadge(state: session.state).scaleEffect(0.75)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .opacity(hovering || selected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? theme.elevated : hovering ? theme.hover : .clear, in: Capsule())
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .contextMenu { Button("Close Tab", action: close) }
    }
}

/// Start a Claude or Codex tab on a paired Mac: pick the project, optionally
/// a new branch (the other Mac makes the worktree), and say what to do.
struct NewRemoteTabSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let connection: MacConnection
    @State private var projectId: ProjectID?
    @State private var agent: AgentKind = .claude
    @State private var onBranch = false
    @State private var branch = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var starting = false

    init(connection: MacConnection, projectId: ProjectID?) {
        self.connection = connection
        _projectId = State(initialValue: projectId)
    }

    private var projects: [ProjectSummary] { connection.snapshot?.projects ?? [] }

    private var canStart: Bool {
        !starting && projectId != nil && connection.status == .online
            && (!onBranch || !branch.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New \(agent.displayName) tab on \(connection.mac.name)").font(.title2.bold())
            AgentPicker(agent: $agent)
            Picker("Project", selection: $projectId) {
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            Toggle("On a new branch", isOn: $onBranch)
            if onBranch {
                TextField("Branch name, e.g. fix-login", text: $branch)
                    .textFieldStyle(.roundedBorder)
            }
            Text(onBranch
                 ? "\(connection.mac.name) creates a separate worktree, so the main checkout isn't touched."
                 : "Runs in the project's main folder, next to any open tabs.")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
            TextField("What should \(agent.displayName) do? (optional)", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).foregroundStyle(theme.red).font(.callout)
            }
            HStack {
                Spacer()
                if starting { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func start() {
        guard let projectId else { return }
        starting = true
        error = nil
        let branchName = onBranch ? branch.trimmingCharacters(in: .whitespaces) : nil
        Task {
            switch await connection.startSession(projectId: projectId, branch: branchName, prompt: prompt,
                                                 permissionMode: nil, agent: agent) {
            case .started(let paneId):
                model.remote.selectedProjectId = projectId
                model.remote.selectedPaneId = paneId
                dismiss()
            case .failed(let message):
                error = message
            }
            starting = false
        }
    }
}
