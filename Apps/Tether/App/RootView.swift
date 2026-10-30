import SwiftUI
import TetherCore
import UniformTypeIdentifiers
import TetherProtocol

/// Header rows line up with the traffic lights, which the hidden title bar
/// leaves floating over the content.
enum ChromeMetrics {
    static let headerHeight: CGFloat = 44
    /// Room for the traffic lights at the window's leading edge.
    static let trafficLightsWidth: CGFloat = 78
    static let cardRadius: CGFloat = 10
}

/// Sidebar | terminal card | inspector, drawn by hand rather than with
/// NavigationSplitView so every surface takes the theme's colors.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0
    @AppStorage("inspectorWidth") private var inspectorWidth = 420.0

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(showSidebar: $showSidebar)
                    .frame(width: sidebarWidth)
                ColumnResizer(width: $sidebarWidth, range: 180...400, sign: 1)
            }
            detail
                .padding(.leading, showSidebar ? 0 : 8)
                .padding(.trailing, inspectorShown ? 0 : 8)
            if inspectorShown {
                ColumnResizer(width: $inspectorWidth, range: 300...720, sign: -1)
                if let connection = model.remote.selectedConnection, let paneId = model.remote.selectedPaneId {
                    RemoteInspectorView(connection: connection, paneId: paneId)
                        .frame(width: inspectorWidth)
                } else {
                    InspectorView()
                        .frame(width: inspectorWidth)
                }
            }
        }
        .background(theme.window)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.2), value: showSidebar)
        .animation(.snappy(duration: 0.2), value: inspectorShown)
        // Paired Macs show up as chips in the sidebar, so keep them connected.
        .onAppear { model.remote.retain() }
        .onDisappear { model.remote.release() }
        .confirmationDialog("Close this tab?", isPresented: Binding(get: { model.pendingClose != nil },
                                                                    set: { if !$0 { model.pendingClose = nil } }),
                            titleVisibility: .visible) {
            Button("Close Tab", role: .destructive) {
                if let id = model.pendingClose { Task { await model.closePane(id) } }
                model.pendingClose = nil
            }
        } message: {
            Text("Claude is working or waiting on you in this tab. Closing it stops Claude. The conversation stays in Claude's history.")
        }
        .fileImporter(isPresented: $model.addProjectRequested,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.addProject(at: url) }
            }
        }
    }

    /// Changes and Files follow the selected tab, so the Overview hides them
    /// without turning the setting off.
    private var inspectorShown: Bool {
        guard model.showInspector else { return false }
        // A paired Mac's panel needs one of its tabs open.
        if model.remote.selectedMacId != nil { return model.remote.selectedPaneId != nil }
        return !model.showOverview
    }

    private var activeLocalProject: ProjectID? {
        model.remote.selectedConnection == nil && !model.showOverview ? model.selectedProjectId : nil
    }

    private var detail: some View {
        ZStack {
            PersistentTerminalStack(items: model.projects, selection: activeLocalProject) { project, active in
                TerminalTabsView(project: project, isActive: active, showSidebar: $showSidebar)
            }
            if let connection = model.remote.selectedConnection {
                RemoteDetailView(connection: connection, showSidebar: $showSidebar)
            } else if model.showOverview {
                OverviewView(showSidebar: $showSidebar)
            } else if !model.projects.contains(where: { $0.id == model.selectedProjectId }) {
                VStack(spacing: 0) {
                    HStack {
                        if !showSidebar {
                            ChromeButton(systemImage: "sidebar.left", help: "Show sidebar (⌃⌘S)") { showSidebar = true }
                        }
                        Spacer()
                    }
                    .padding(.leading, showSidebar ? 0 : ChromeMetrics.trafficLightsWidth)
                    .frame(height: ChromeMetrics.headerHeight)
                    ContentUnavailableView("No project selected",
                                           systemImage: "folder",
                                           description: Text("Add a project with ⇧⌘N."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
                        .padding(.bottom, 8)
                }
            }
        }
    }

}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Binding var showSidebar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                ChromeButton(systemImage: "sidebar.left", help: "Hide sidebar (⌃⌘S)") { showSidebar = false }
            }
            .padding(.leading, ChromeMetrics.trafficLightsWidth)
            .padding(.trailing, 8)
            .frame(height: ChromeMetrics.headerHeight)

            MacChips()
                .padding(.top, 4)

            if let connection = model.remote.selectedConnection {
                RemoteProjectList(connection: connection)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    OverviewButton()
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                    HStack {
                        Text("Projects")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                        Spacer()
                        Button { model.addProjectRequested = true } label: {
                            Image(systemName: "plus").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .help("Add project (⇧⌘N)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                    // A List rather than a stack for its native drag-to-reorder; rows draw
                    // their own selection, so List selection stays off.
                    List {
                        ForEach(model.projects) { project in
                            ProjectRow(project: project,
                                       selected: !model.showOverview && model.selectedProjectId == project.id)
                                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        .onMove { from, to in
                            var ids = model.projects.map(\.id)
                            ids.move(fromOffsets: from, toOffset: to)
                            Task { await model.reorderProjects(ids) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }

            if let connection = model.remote.selectedConnection {
                MacNoticeCard(connection: connection)
            }

            if let message = model.hookStatusMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .padding(12)
            }

            if let update = model.updater.available {
                Button {
                    UserDefaults.standard.set("updates", forKey: "settingsTab")
                    openSettings()
                } label: {
                    Label("Tether \(update.version.description) is available", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .padding(12)
            }

            if model.releases.showToast, let latest = model.releases.unseen.first {
                WhatsNewToast(version: latest.version) {
                    openWindow(id: "whats-new")
                } dismiss: {
                    model.releases.markSeen()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.releases.showToast)
    }
}

/// Top of the sidebar: every Claude tab across projects, as a grid.
private struct OverviewButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let selected = model.showOverview
        let waiting = model.paneStates.values.filter { $0 == .needsInput }.count
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? theme.text : theme.secondaryText)
                .frame(width: 30, height: 22)
            Text("Overview")
                .font(.body.weight(.medium))
            Spacer(minLength: 4)
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.avatarText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.blue, in: Capsule())
                    .help(waiting == 1 ? "1 tab needs you" : "\(waiting) tabs need you")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(selected ? theme.elevated : hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.closeOverlays()
            model.showOverview = true
        }
        .onHover { hovering = $0 }
        .help("Every Claude tab at a glance (⌘0)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let project: Project
    let selected: Bool
    @State private var hovering = false
    @AppStorage("useProjectIcons") private var useProjectIcons = true
    @State private var renaming = false
    @State private var newName = ""
    /// Inline rename, started by double-clicking the name.
    @State private var editing = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 2) {
            projectLine
            ForEach(model.branchWorktrees(for: project.id)) { worktree in
                WorktreeRow(worktree: worktree)
            }
        }
    }

    private var projectLine: some View {
        let state = model.sessionStates[project.id] ?? .idle
        return HStack(spacing: 10) {
            ProjectAvatar(name: project.name, state: state,
                          icon: useProjectIcons ? model.projectIcons[project.id] : nil)
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .focused($nameFocused)
                        .onAppear { nameFocused = true }
                        .onSubmit(commitRename)
                        .onExitCommand { editing = false }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused, editing { commitRename() }
                        }
                } else {
                    Text(project.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(model.branchLabel(for: project))
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(theme.secondaryText)
                    if let pr = model.pullRequest(forPath: project.path) {
                        PullRequestBadge(status: pr)
                    }
                }
            }
            Spacer(minLength: 4)
            if let start = model.turnStart(of: model.panes(for: project.id)) {
                RunningTime(start: start)
            }
            StatusBadge(state: state)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedProjectId = project.id }
        // Simultaneous, so a single click selects without waiting to see
        // whether a second click follows.
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginInlineRename() })
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") {
                newName = project.name
                renaming = true
            }
            Divider()
            Button("Remove Project", role: .destructive) {
                Task { await model.removeProject(project.id) }
            }
        }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = newName
                Task { await model.renameProject(project.id, to: name) }
            }
        } message: {
            Text("Changes the name Tether shows. The folder isn't renamed.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func beginInlineRename() {
        newName = project.name
        editing = true
    }

    private func commitRename() {
        editing = false
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != project.name else { return }
        Task { await model.renameProject(project.id, to: name) }
    }

    private var rowFill: Color {
        if selected { return theme.elevated }
        return hovering ? theme.hover : .clear
    }
}

/// A branch worktree under its project: its branch, its tab's status, and
/// a way to remove it once the work is merged.
private struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let worktree: Worktree
    @State private var hovering = false
    @State private var confirming = false
    @State private var dirty = false
    @State private var note: String?

    var body: some View {
        let panes = model.panes(onWorktree: worktree.id)
        let state = panes.map { model.paneStates[$0.id] ?? .idle }.max { $0.urgency < $1.urgency } ?? .idle
        let selected = panes.contains { $0.id == model.selectedPaneId }
        let pr = model.pullRequest(forPath: worktree.path)
        // A squash merge leaves the branch unmerged as far as git can tell.
        let merged = model.isMerged(worktree) || pr?.state == .merged
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(worktree.branch)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let pr {
                PullRequestBadge(status: pr)
            }
            Spacer(minLength: 4)
            // Hover offers removal; otherwise a quiet check marks a merged branch.
            if hovering {
                Button { confirming = true } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(merged ? theme.green : theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(merged ? "Merged into the base branch. Remove the worktree and branch."
                             : "Remove the worktree")
            } else if merged {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(theme.green)
                    .help("Merged into the base branch. Hover to remove.")
            } else if panes.isEmpty {
                Text("no tab").font(.caption2).foregroundStyle(theme.secondaryText)
            }
            if let start = model.turnStart(of: panes) {
                RunningTime(start: start)
            }
            StatusBadge(state: state).scaleEffect(0.8)
        }
        .padding(.leading, 38)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(selected ? theme.elevated : hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture {
            if panes.isEmpty {
                // Reopen a Claude tab on the worktree.
                Task { await model.startSession(worktree: worktree) }
            } else {
                model.selectWorktree(worktree)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove Worktree…", role: .destructive) { confirming = true }
        }
        .confirmationDialog("Remove the worktree for “\(worktree.branch)”?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { remove(force: false) }
        } message: {
            Text("Closes its tabs and deletes the folder. The branch is deleted too if it's merged; otherwise it's kept.")
        }
        .alert("Uncommitted changes", isPresented: $dirty) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Anyway", role: .destructive) { remove(force: true) }
        } message: {
            Text("“\(worktree.branch)” has changes that aren't committed. Removing it deletes them.")
        }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK") {}
        }
    }

    private func remove(force: Bool) {
        Task {
            do {
                note = try await model.removeWorktree(worktree.id, force: force)
            } catch WorktreeCreator.Failure.dirty {
                dirty = true
            } catch {
                note = "\(error)"
            }
        }
    }
}

/// Letter tile in a color derived from the project name. A ring in the
/// status color shows across the room when Claude needs you or is done.
struct ProjectAvatar: View {
    @Environment(\.theme) private var theme
    let name: String
    let state: SessionState
    /// The project's own app icon, when one was found in its folder.
    var icon: NSImage?

    var body: some View {
        tile
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if let ring = state.ringColor(theme) {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(ring, lineWidth: 2)
                        .padding(-3)
                }
            }
            .padding(3)
    }

    @ViewBuilder
    private var tile: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(theme.avatarText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.avatar(for: name))
        }
    }
}
