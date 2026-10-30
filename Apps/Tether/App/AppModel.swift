import AppKit
import Foundation
import Observation
import TetherCore
import TetherProtocol

/// Main-actor façade over the TetherCore actors. Views bind to this; it owns
/// the live terminal panes, the hook server, and the permission queue.
@MainActor
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
    private(set) var remoteHosts: [RemoteHost] = []
    /// Icons found in project folders (see `ProjectIconFinder`), by project.
    private(set) var projectIcons: [ProjectID: NSImage] = [:]
    @ObservationIgnored private var iconStamps: [ProjectID: String] = [:]
    /// The same icons as PNG data, for the phone.
    @ObservationIgnored private var iconData: [ProjectID: Data] = [:]
    @ObservationIgnored private var lastIconScan = Date.distantPast
    /// Every worktree, primary ones included. Branch worktrees nest under
    /// their project in the sidebar.
    private(set) var worktrees: [Worktree] = []
    /// Last use, pin and Inactive state per project, mirrored from the store.
    private(set) var projectActivity: [ProjectID: ProjectActivity] = [:]
    @ObservationIgnored private var lastActivityScan = Date.distantPast
    /// Most urgent state across a project's panes, for the sidebar.
    private(set) var sessionStates: [ProjectID: SessionState] = [:]
    /// Per-pane state, for tab badges.
    private(set) var paneStates: [PaneID: SessionState] = [:]
    /// Permission requests waiting on an answer, oldest first.
    private(set) var pendingPermissions: [PendingPermission] = []
    /// Non-nil when hooks could not be set up; shown in the sidebar footer.
    private(set) var hookStatusMessage: String?
    /// Why each waiting pane is waiting: a permission, a question, or a dialog.
    private(set) var paneAttention: [PaneID: AttentionReason] = [:]
    /// Messages held back per pane until Claude can take them.
    private(set) var queuedCounts: [PaneID: Int] = [:]
    /// What each tab is holding for Claude, oldest first, so the chat can show it.
    private(set) var queuedMessages: [PaneID: [String]] = [:]
    /// What's typed in each tab's chat box, kept while you look elsewhere.
    var drafts: [PaneID: ComposeDraft] = [:]
    /// Claude Code's suggested next prompt per tab, shown faintly in the chat box.
    private(set) var suggestions: [PaneID: String] = [:]
    /// When each tab's current turn started, while Claude works or waits on
    /// you mid-turn. Shown as elapsed time in the Overview.
    private(set) var turnStartedAt: [PaneID: Date] = [:]
    /// Tabs shown together. The app's copy is authoritative: it also holds
    /// splits with unpersisted shortcut tabs, which the store drops.
    private(set) var splits: [PaneSplit] = []

    var selectedProjectId: ProjectID? {
        didSet {
            showOverview = false
            selectFirstPaneIfNeeded()
            updateChangesFocus()
        }
    }
    var selectedPaneId: PaneID? {
        didSet {
            if selectedPaneId != oldValue { updateChangesFocus() }
            guard let id = selectedPaneId, id != oldValue else { return }
            Task { await self.paneFocused(id) }
        }
    }
    var addProjectRequested = false
    /// Set once at launch when this is a first run, so the window opens the welcome.
    var needsWelcome = false
    /// The Overview grid replaces the tabs in the detail column. Picking a
    /// project, or opening or switching a tab, leaves it.
    var showOverview = false
    /// Right-hand panel, showing Changes, Files or Preview.
    var showInspector = false
    var inspectorTab: InspectorTab = .changes
    /// The project whose + was pressed: its start page covers the current tab
    /// until something is picked or another tab is clicked.
    var newTabPage: ProjectID?
    /// Shortcut commands for every project, shown in the top bar.
    private(set) var quickActions: [QuickAction] = []

    private(set) var commandRuns: [PaneID: CommandRunSummary] = [:]
    private var commandMonitors: [PaneID: Task<Void, Never>] = [:]
    private(set) var nativeLiveText: [PaneID: String] = [:]
    private var codexChats: [PaneID: CodexChatDriver] = [:]
    private var codexGenerations: [PaneID: UUID] = [:]
    private(set) var codexErrors: [PaneID: String] = [:]
    private(set) var codexMissingReports: Set<PaneID> = []
    private var codexLaunches: [PaneID: Date] = [:]
    private var codexReports: [PaneID: Date] = [:]
    private var prActionsInFlight: Set<String> = []

    let mirror = MirrorStore()
    let releases = ReleaseNotesStore()
    let changes = ChangesStore()
    let pullRequests = PullRequestStore()
    let preview = PreviewStore()
    let remote = RemoteStore()
    let companion = CompanionHub()
    let updater = Updater()

    /// The diff open over the terminal, if any.
    private(set) var openDiffTarget: OpenDiff?
    /// A file from the Files panel open over the terminal, if any.
    private(set) var openFileTarget: OpenFile?
    /// Whether new Claude tabs open as a chat rather than a terminal.
    private(set) var chatByDefault: Bool = UserDefaults.standard.object(forKey: "chatByDefault") as? Bool
        ?? UserDefaults.standard.bool(forKey: "showChat")
    /// Tabs whose view differs from what the default would give them.
    private var chatOverrides: [PaneID: Bool] = [:]
    /// Comments collected on diffs, waiting to be sent to Claude as one message.
    private(set) var reviewComments = ReviewDrafts()

    /// Live panes keyed by id. Descriptors persist in the store; this does not.
    private var panes: [PaneID: TerminalPane] = [:]
    private var paneOrder: [PaneID] = []
    private var recordedSessions: [PaneID: SessionID] = [:]
    /// Session id Tether chose (or resumed) when it launched each Claude tab,
    /// known before any hook fires.
    private var launchSessions: [PaneID: SessionID] = [:]
    /// Polls a working session's transcript for the Esc-interrupt record,
    /// since Claude Code fires no hook when the user interrupts.
    private var interruptWatchers: [SessionID: Task<Void, Never>] = [:]
    /// The folder each Claude tab works in, for its Changes panel.
    private var paneWorktreePaths: [PaneID: String] = [:]
    private var promptQueue = PromptQueue()
    @ObservationIgnored private let promptRetries = PromptRetryScheduler()
    /// The task a new Claude tab starts on, passed as `claude "<prompt>"`.
    private var initialPrompts: [PaneID: String] = [:]
    /// `--permission-mode` for a tab started from the phone. Not persisted:
    /// a resumed tab gets the user's default again (issue #3).
    private var initialModes: [PaneID: String] = [:]
    /// Permission mode per tab, as last reported by a hook.
    private(set) var paneModes: [PaneID: String] = [:]
    /// Model and cost per tab, from the status line relay.
    private(set) var paneStatus: [PaneID: SessionStatus] = [:]
    /// Plan limits from the latest status line that reported them, kept
    /// across restarts (`SavedLimits`).
    private(set) var usageLimits: UsageLimits? = SavedLimits.decode(
        UserDefaults.standard.data(forKey: "usageLimits"), now: Date())
    /// When a status line last reported them. Claude Code only does that from
    /// a tab that has just made a request, so this is the limits' real age.
    private(set) var usageLimitsAt: Date? = {
        let seconds = UserDefaults.standard.double(forKey: "usageLimitsAt")
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }()

    private let store = ProjectStore(fileURL: ProjectStore.defaultFileURL())
    let registry = SessionRegistry()
    let broker = PermissionBroker()
    private var hookServer: HookServer?
    private var hookSettingsPath: String?
    /// The hook server's port, handed to Codex tabs through their environment.
    private var hookPort: UInt16?
    /// Per-launch secret handed to every pty and echoed back by hooks.
    let launchToken = UUID().uuidString
    /// `claude` and `codex` by absolute path, plus the shell's PATH: found once
    /// per launch, since an app opened from Finder can't rely on PATH.
    @ObservationIgnored private var toolPathsTask: Task<ToolPaths, Never>?
    /// Claude and Codex tabs whose tool wasn't found. They show
    /// `MissingToolView` over the terminal instead of a shell error.
    private(set) var missingTools: [PaneID: AgentKind] = [:]

    init() {
        companion.model = self
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePolling()
                    if name == NSApplication.didBecomeActiveNotification {
                        self?.refreshProjectIconsIfStale()
                        self?.scanOutsideActivityIfStale()
                    }
                }
            }
        }
        mirror.onMode = { [weak self] sessionId, mode in
            guard let self, let pane = self.pane(forSession: sessionId), self.paneModes[pane] != mode else { return }
            self.paneModes[pane] = mode
            self.companion.setNeedsSnapshot()
        }
        mirror.onEvents = { [weak self] sessionId, events in
            self?.companion.publish(events, sessionId: sessionId)
            self?.companion.setNeedsSnapshot() // previews
            self?.activityContentChanged(sessionId: sessionId)
        }
        Task { await restore() }
    }

    // MARK: Projects

    func reload() async {
        projects = await store.orderedProjects()
        remoteHosts = await store.state.remoteHosts
        worktrees = await store.state.worktrees
        projectActivity = await store.state.activity
        quickActions = await store.state.quickActions
        if selectedProjectId == nil { selectedProjectId = projects.first?.id }
        // Branch worktrees too, or their tabs' Changes panels never load.
        var watched: [String: String] = [:]
        for project in projects { watched[project.path] = project.baseBranch }
        for wt in worktrees where !wt.isPrimary {
            if let project = projects.first(where: { $0.id == wt.projectId }) {
                watched[wt.path] = watched[wt.path] ?? project.baseBranch
            }
        }
        changes.sync(watched)
        refreshProjectIcons()
        scanOutsideActivityIfStale()
        updateChangesFocus()
        companion.setNeedsSnapshot()
    }

    // MARK: Active and Inactive projects

    /// Settings → General: days without use before a project moves to Inactive.
    var inactiveAfterDays: Int {
        let days = UserDefaults.standard.integer(forKey: "inactiveAfterDays")
        return days > 0 ? days : ProjectActivity.defaultInactiveAfterDays
    }

    /// The sidebar's Pinned, Active and Inactive groups as of `now`.
    func projectSections(now: Date = Date()) -> ProjectSections {
        ProjectSections(projects: projects, activity: projectActivity, now: now, inactiveAfterDays: inactiveAfterDays)
    }

    /// A prompt, a new tab or a Claude turn in the project.
    func touchProject(_ id: ProjectID?, at date: Date = Date()) {
        guard let id, projects.contains(where: { $0.id == id }) else { return }
        let wasActive = projectActivity[id]?.isActive(now: date, inactiveAfterDays: inactiveAfterDays) ?? false
        projectActivity[id, default: ProjectActivity()].touch(at: date)
        Task { try? await store.touchProject(id, at: date) }
        if !wasActive { companion.setNeedsSnapshot() }
    }

    func setProjectPinned(_ id: ProjectID, _ pinned: Bool) async {
        try? await store.setPinned(id, pinned)
        await reload()
    }

    func setProjectActive(_ id: ProjectID, _ active: Bool) async {
        try? await store.setActive(id, active)
        await reload()
    }

    /// Claude Code use outside Tether counts too: the newest transcript in
    /// each project's folders. At most every five minutes.
    func scanOutsideActivityIfStale() {
        guard Date().timeIntervalSince(lastActivityScan) > 300 else { return }
        lastActivityScan = Date()
        let jobs = projects.map { project in
            (id: project.id, folders: [project.path] + worktrees.filter { $0.projectId == project.id }.map(\.path))
        }
        Task {
            for job in jobs {
                let latest = await Task.detached(priority: .utility) {
                    SessionHistory.latestActivity(folders: job.folders)
                }.value
                guard let latest, latest > (projectActivity[job.id]?.lastUsed ?? .distantPast) else { continue }
                touchProject(job.id, at: latest)
            }
        }
    }

    func addProject(at url: URL) async {
        do {
            let p = try await store.addProject(name: url.lastPathComponent, path: url.path)
            await reload()
            // Its start page offers Claude, Codex and the rest.
            selectedProjectId = p.id
        } catch {
            print("addProject failed: \(error)")
        }
    }

    func removeProject(_ id: ProjectID) async {
        for pane in panes(for: id) { tearDown(pane.id) }
        try? await store.removeProject(id)
        await reload()
        if selectedProjectId == id { selectedProjectId = projects.first?.id }
        recomputeProjectStates()
    }

    // MARK: Remote hosts

    func addRemoteHost(_ host: RemoteHost) async {
        try? await store.upsertRemoteHost(host)
        await reload()
    }

    func removeRemoteHost(_ id: RemoteHostID) async {
        let doomed = panes.values.filter {
            if case .ssh(let h) = $0.descriptor.kind { return h == id }
            return false
        }
        for pane in doomed { tearDown(pane.id) }
        try? await store.removeRemoteHost(id)
        await reload()
    }

    // MARK: Panes

    func panes(for projectId: ProjectID) -> [TerminalPane] {
        paneOrder.compactMap { panes[$0] }.filter { $0.descriptor.projectId == projectId }
    }

    func openClaudePane(project: Project) async {
        guard let wt = await store.primaryWorktree(for: project.id) else { return }
        let d = PaneDescriptor(projectId: project.id,
                               kind: .claude(worktreeId: wt.id, resumeSessionId: nil),
                               title: "Claude")
        await open(d)
    }

    /// A Codex tab in the project's folder. Codex reports to the same hook
    /// server as Claude (docs/HOOKS.md, "Codex").
    func openCodexPane(project: Project) async {
        guard let wt = await store.primaryWorktree(for: project.id) else {
            print("openCodexPane: \(project.name) has no primary worktree")
            return
        }
        print("openCodexPane: opening in \(wt.path), hook port \(hookPort.map(String.init) ?? "none")")
        let d = PaneDescriptor(projectId: project.id,
                               kind: .codex(worktreeId: wt.id, resumeSessionId: nil),
                               title: "Codex")
        await open(d)
    }

    struct StartError: Error, CustomStringConvertible {
        var description: String
    }

    /// A new Claude (or Codex) tab, on a new worktree branch when `branch` is
    /// set, starting on `prompt` when given. `select` is false for phone
    /// requests, so the Mac's view doesn't jump.
    @discardableResult
    func startSession(projectId: ProjectID, branch: String?, prompt: String?,
                      permissionMode: String? = nil, agent: AgentKind = .claude,
                      nativeCodexChat: Bool = false, select: Bool) async throws -> PaneID {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw StartError(description: "That project is no longer on the Mac.")
        }
        let branchName = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let worktree: Worktree
        if branchName.isEmpty {
            guard let primary = await store.primaryWorktree(for: project.id) else {
                throw StartError(description: "\(project.name) has no folder on record.")
            }
            worktree = primary
        } else {
            do {
                let path = try await WorktreeCreator().create(
                    repoPath: project.path, branch: branchName, baseBranch: project.baseBranch)
                worktree = try await store.addWorktree(projectId: project.id, path: path, branch: branchName)
                await reload()
            } catch let failure as WorktreeCreator.Failure {
                throw StartError(description: failure.description)
            }
        }
        let kind: PaneKind = switch agent {
        case .claude: .claude(worktreeId: worktree.id, resumeSessionId: nil)
        case .codex: .codex(worktreeId: worktree.id, resumeSessionId: nil)
        }
        let d = PaneDescriptor(projectId: project.id, kind: kind,
                               title: branchName.isEmpty ? agent.displayName : branchName,
                               codexChat: agent == .codex && nativeCodexChat ? true : nil)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initialPrompts[d.id] = prompt
        }
        // Permission modes are Claude's; Codex starts in its own default.
        if let permissionMode, agent == .claude { initialModes[d.id] = permissionMode }
        try? await store.addPane(d)
        await mount(d)
        if select {
            selectedProjectId = project.id
            selectedPaneId = d.id
        }
        return d.id
    }

    // MARK: Worktrees

    func branchWorktrees(for projectId: ProjectID) -> [Worktree] {
        worktrees.filter { $0.projectId == projectId && !$0.isPrimary }
    }

    func panes(onWorktree id: WorktreeID) -> [TerminalPane] {
        paneOrder.compactMap { panes[$0] }.filter { $0.descriptor.kind.worktreeId == id }
    }

    /// Nothing left on the branch that the base doesn't have: no commits
    /// since the merge base and no uncommitted files.
    func isMerged(_ worktree: Worktree) -> Bool {
        guard let snapshot = changes.snapshots[worktree.path], snapshot.baseRef != nil else { return false }
        return snapshot.files.isEmpty && snapshot.commits.isEmpty
    }

    /// Closes the worktree's tabs, removes the worktree, and deletes the
    /// branch if it's merged. Returns a note for the user when the branch
    /// was kept. Throws `.dirty` without `force` if there are uncommitted changes.
    @discardableResult
    func removeWorktree(_ id: WorktreeID, force: Bool) async throws -> String? {
        guard let wt = worktrees.first(where: { $0.id == id }), !wt.isPrimary,
              let project = projects.first(where: { $0.id == wt.projectId }) else { return nil }
        let removal = try await WorktreeCreator().remove(repoPath: project.path, worktreePath: wt.path,
                                                         branch: wt.branch, force: force)
        for pane in panes(onWorktree: id) { tearDown(pane.id) }
        try? await store.removeWorktree(id)
        await reload()
        return removal.branchDeleted ? nil
            : "The branch “\(wt.branch)” has commits that aren't merged, so it was kept."
    }

    /// A fresh Claude tab on an existing worktree whose tabs were closed.
    func startSession(worktree: Worktree) async {
        let d = PaneDescriptor(projectId: worktree.projectId,
                               kind: .claude(worktreeId: worktree.id, resumeSessionId: nil),
                               title: worktree.branch)
        await open(d)
        selectedProjectId = worktree.projectId
        selectedPaneId = d.id
    }

    /// A Claude or Codex tab with its project, for the Overview and the menu bar.
    struct AgentTab {
        var project: Project
        var pane: TerminalPane
        /// The project has more than one agent tab, so name this one.
        var showTitle: Bool
    }

    /// Every Claude and Codex tab, in sidebar and tab order.
    var agentTabs: [AgentTab] {
        projects.flatMap { project -> [AgentTab] in
            let tabs = panes(for: project.id).filter(\.isAgent)
            return tabs.map { AgentTab(project: project, pane: $0, showTitle: tabs.count > 1) }
        }
    }

    /// When the longest-running current turn among these tabs started, if any
    /// of them is mid-turn.
    func turnStart(of panes: [TerminalPane]) -> Date? {
        panes.compactMap { turnStartedAt[$0.id] }.min()
    }

    /// Leaves the Overview for one tab.
    func select(pane: TerminalPane) {
        closeOverlays()
        selectedProjectId = pane.descriptor.projectId
        selectedPaneId = pane.id
    }

    /// The folder a tab works in: its worktree for Claude tabs, else nil.
    func worktreePath(forPane id: PaneID) -> String? {
        paneWorktreePaths[id]
    }

    func selectWorktree(_ worktree: Worktree) {
        selectedProjectId = worktree.projectId
        if let pane = panes(onWorktree: worktree.id).first { selectedPaneId = pane.id }
    }

    func renameProject(_ id: ProjectID, to name: String) async {
        try? await store.renameProject(id, to: name)
        await reload()
    }

    func reorderProjects(_ ids: [ProjectID]) async {
        try? await store.reorder(ids)
        await reload()
    }

    func openShellPane(project: Project) async {
        let d = PaneDescriptor(projectId: project.id, kind: .shell(cwd: project.path), title: "Shell")
        await open(d)
    }

    // MARK: Tab order and splits

    /// Drops a dragged tab where `target` is, within one project.
    func movePane(_ id: PaneID, onto target: PaneID) async {
        guard let projectId = panes[id]?.descriptor.projectId,
              panes[target]?.descriptor.projectId == projectId else { return }
        await applyOrder(PaneLayout.moving(id, onto: target, in: panes(for: projectId).map(\.id)),
                         in: projectId)
    }

    private func applyOrder(_ order: [PaneID], in projectId: ProjectID) async {
        paneOrder = PaneLayout.reordering(paneOrder, id: { $0 },
                                          inProject: { self.panes[$0]?.descriptor.projectId == projectId },
                                          to: order)
        companion.setNeedsSnapshot()
        try? await store.reorderPanes(order, in: projectId)
    }

    func split(containing pane: PaneID?) -> PaneSplit? {
        PaneLayout.split(containing: pane, in: splits)
    }

    /// Opens a shell beside the selected tab, in the folder that tab works in.
    func splitSelectedPane(_ axis: SplitAxis) async {
        guard let current = selectedPaneId, let pane = panes[current] else { return }
        let projectId = pane.descriptor.projectId
        let d = PaneDescriptor(projectId: projectId, kind: .shell(cwd: folder(of: pane)), title: "Shell")
        closeOverlays()
        // Set before the pane opens so the new tab appears already beside this one.
        splits = PaneLayout.adding(PaneSplit(projectId: projectId, first: current, second: d.id, axis: axis),
                                   to: splits)
        await open(d)
        await applyOrder(PaneLayout.placing(d.id, after: current, in: panes(for: projectId).map(\.id)),
                         in: projectId)
        await persistSplits()
    }

    /// Shows `other` beside the selected tab, which keeps focus.
    func showBesideSelected(_ other: PaneID) async {
        guard let current = selectedPaneId, current != other,
              let projectId = panes[current]?.descriptor.projectId,
              panes[other]?.descriptor.projectId == projectId else { return }
        closeOverlays()
        splits = PaneLayout.adding(PaneSplit(projectId: projectId, first: current, second: other), to: splits)
        await applyOrder(PaneLayout.placing(other, after: current, in: panes(for: projectId).map(\.id)),
                         in: projectId)
        await persistSplits()
    }

    /// Takes the tab's split apart; both tabs stay open.
    func unsplit(_ pane: PaneID) async {
        splits.removeAll { $0.contains(pane) }
        await persistSplits()
    }

    func unsplitSelectedPane() {
        guard let id = selectedPaneId else { return }
        Task { await unsplit(id) }
    }

    /// Moves focus to the other half of the selected tab's split.
    func focusOtherSplitHalf() {
        guard let id = selectedPaneId, let partner = split(containing: id)?.partner(of: id) else { return }
        closeOverlays()
        showOverview = false
        selectedPaneId = partner
    }

    /// Called when a divider drag ends; the view tracks the drag itself.
    /// Synchronous so the divider doesn't jump back for a frame.
    func setSplitFraction(_ fraction: Double, forPane pane: PaneID) {
        guard let i = splits.firstIndex(where: { $0.contains(pane) }) else { return }
        splits[i].fraction = PaneSplit.clamp(fraction)
        Task { await persistSplits() }
    }

    func toggleSplitAxis(forPane pane: PaneID) async {
        guard let i = splits.firstIndex(where: { $0.contains(pane) }) else { return }
        splits[i].axis = splits[i].axis.toggled
        await persistSplits()
    }

    private func persistSplits() async {
        try? await store.setSplits(splits)
    }

    /// The folder a tab works in, for a shell opened beside it.
    private func folder(of pane: TerminalPane) -> String {
        switch pane.descriptor.kind {
        case .shell(let cwd), .command(let cwd, _): return cwd
        case .claude, .codex, .ssh:
            return paneWorktreePaths[pane.id]
                ?? projects.first { $0.id == pane.descriptor.projectId }?.path
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
    }

    // MARK: Quick actions

    func quickActions(for projectId: ProjectID) -> [QuickAction] {
        quickActions.filter { $0.projectId == projectId }
    }

    func setQuickActions(_ actions: [QuickAction], for projectId: ProjectID) async {
        try? await store.setQuickActions(actions, for: projectId)
        quickActions = await store.state.quickActions
    }

    /// Runs a shortcut in its own tab, in the folder the selected tab works
    /// in. If that command is already running there, its tab is selected
    /// instead, so a second click doesn't start a second dev server.
    @discardableResult
    func runQuickAction(_ action: QuickAction, inPane paneId: PaneID? = nil, select: Bool = true) async -> PaneID? {
        guard let project = projects.first(where: { $0.id == action.projectId }) else { return nil }
        if let paneId, panes[paneId]?.descriptor.projectId != project.id { return nil }
        let cwd = paneId.flatMap { worktreePath(forPane: $0) }
            ?? (select && selectedProjectId == project.id ? selectedWorktreePath : nil) ?? project.path
        let kind = PaneKind.command(cwd: cwd, command: action.command)
        if select { closeOverlays(); selectedProjectId = project.id }
        if let running = panes(for: project.id).first(where: {
            $0.descriptor.kind == kind && !$0.hasExited && commandRuns[$0.id]?.exitCode == nil
        }) {
            if select { selectedPaneId = running.id }
            return running.id
        }
        let descriptor = PaneDescriptor(projectId: project.id, kind: kind, title: action.label)
        await mount(descriptor)
        if select { selectedPaneId = descriptor.id }
        return descriptor.id
    }

    // MARK: History

    /// Claude sessions that ran in the project's folder or its worktrees.
    func pastSessions(for projectId: ProjectID) async -> [PastSession] {
        let folders = worktrees.filter { $0.projectId == projectId }.map(\.path)
        return await Task.detached(priority: .userInitiated) {
            SessionHistory.list(folders: folders)
        }.value
    }

    /// The tab already running a session, if any.
    func pane(forSession id: SessionID) -> PaneID? {
        paneOrder.first { sessionId(forPane: $0) == id }
    }

    /// Selects the session's tab, or resumes it in a new Claude tab in the
    /// worktree it ran in.
    func openPastSession(_ session: PastSession, projectId: ProjectID) async {
        closeOverlays()
        selectedProjectId = projectId
        if let paneId = pane(forSession: session.id) {
            selectedPaneId = paneId
            return
        }
        let candidates = worktrees.filter { $0.projectId == projectId }
        guard let worktree = candidates.first(where: { $0.path == session.cwd })
                ?? candidates.first(where: \.isPrimary) else { return }
        let d = PaneDescriptor(projectId: projectId,
                               kind: .claude(worktreeId: worktree.id, resumeSessionId: session.id),
                               title: worktree.isPrimary ? "Claude" : worktree.branch)
        await open(d)
    }

    /// Like `openPastSession`, for a paired Mac or phone: returns the tab
    /// running the session, opening one when none is.
    func resumePastSession(_ sessionId: SessionID, projectId: ProjectID, select: Bool) async throws -> PaneID {
        if let paneId = pane(forSession: sessionId) { return paneId }
        let past = await pastSessions(for: projectId).first { $0.id == sessionId }
        let candidates = worktrees.filter { $0.projectId == projectId }
        guard let worktree = candidates.first(where: { $0.path == past?.cwd })
                ?? candidates.first(where: \.isPrimary) else {
            throw StartError(description: "That project has no folder on record.")
        }
        let d = PaneDescriptor(projectId: projectId,
                               kind: .claude(worktreeId: worktree.id, resumeSessionId: sessionId),
                               title: worktree.isPrimary ? "Claude" : worktree.branch)
        try? await store.addPane(d)
        await mount(d)
        if select {
            selectedProjectId = projectId
            selectedPaneId = d.id
        }
        return d.id
    }

    func openSSHPane(project: Project, host: RemoteHost) async {
        let d = PaneDescriptor(projectId: project.id, kind: .ssh(hostId: host.id), title: host.name)
        await open(d)
    }

    // MARK: Project icons

    /// Rescans when the app comes to the front, at most every 30 seconds, so
    /// an icon Claude just added shows up without a relaunch.
    func refreshProjectIconsIfStale() {
        if Date().timeIntervalSince(lastIconScan) > 30 { refreshProjectIcons() }
    }

    func refreshProjectIcons() {
        lastIconScan = Date()
        let jobs = projects.map { (id: $0.id, path: $0.path, stamp: iconStamps[$0.id]) }
        let live = Set(jobs.map(\.id))
        var removed = false
        for id in projectIcons.keys where !live.contains(id) {
            projectIcons[id] = nil
            iconStamps[id] = nil
            iconData[id] = nil
            removed = true
        }
        let removedAny = removed
        Task {
            var changed = removedAny
            for job in jobs {
                let result = await Task.detached(priority: .utility) {
                    ProjectIconLoader.load(projectPath: job.path, knownStamp: job.stamp)
                }.value
                guard !result.unchanged else { continue }
                iconStamps[job.id] = result.stamp
                projectIcons[job.id] = result.png.flatMap { NSImage(data: $0) }
                iconData[job.id] = result.png
                changed = true
            }
            if changed { companion.sendProjectIcons() }
        }
    }

    /// Icons for the phone; empty when "Show each project's app icon" is off.
    func companionProjectIcons() -> [ProjectIcon] {
        guard UserDefaults.standard.object(forKey: "useProjectIcons") as? Bool ?? true else { return [] }
        return projects.compactMap { project in iconData[project.id].map { ProjectIcon(id: project.id, png: $0) } }
    }

    // MARK: Energy

    /// Transcript reads: quick while you're looking or a phone is connected,
    /// slow in the background, slower again in Low Power Mode. Hooks, not
    /// transcripts, drive state and notifications, so those aren't delayed.
    func updatePolling() {
        let watched = NSApp.isActive
        let phone = !companion.connectedDeviceIds.isEmpty
        var interval: Duration = watched ? .milliseconds(500) : phone ? .seconds(1) : .seconds(3)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { interval = interval * 2 }
        mirror.pollInterval = interval
    }

    // MARK: Keyboard navigation

    /// A tab waiting for "close it anyway?" because Claude is busy in it.
    var pendingClose: PaneID?

    /// Closes a tab, asking first if Claude is mid-turn or waiting on you.
    func requestClose(_ id: PaneID) {
        if let pane = panes[id], pane.isAgent,
           let state = paneStates[id], state == .working || state == .needsInput {
            pendingClose = id
        } else {
            Task { await closePane(id) }
        }
    }

    func requestCloseSelectedPane() {
        if let id = selectedPaneId { requestClose(id) }
    }

    func selectAdjacentPane(_ offset: Int) {
        guard let pid = selectedProjectId else { return }
        let visible = panes(for: pid)
        guard visible.count > 1 else { return }
        let current = visible.firstIndex { $0.id == selectedPaneId } ?? 0
        let next = (current + offset + visible.count) % visible.count
        closeOverlays()
        showOverview = false
        selectedPaneId = visible[next].id
    }

    /// ⌘1…⌘9, in sidebar order.
    func selectProject(number: Int) {
        guard projects.indices.contains(number - 1) else { return }
        selectedProjectId = projects[number - 1].id
    }

    /// File → New Claude/Codex Tab. With a paired Mac in view, the tab opens
    /// on that Mac, in its selected project: opening it here would land in a
    /// project the window isn't showing.
    func newAgentTabInSelectedProject(_ agent: AgentKind) {
        if let connection = remote.selectedConnection {
            guard connection.status == .online,
                  let projectId = remote.selectedProjectId ?? connection.snapshot?.projects.first?.id else { return }
            Task {
                if case .started(let paneId) = await connection.startSession(
                    projectId: projectId, branch: nil, prompt: "", permissionMode: nil, agent: agent) {
                    remote.selectedProjectId = projectId
                    remote.selectedPaneId = paneId
                }
            }
            return
        }
        guard let project = projects.first(where: { $0.id == selectedProjectId }) else {
            print("newAgentTab(\(agent)): no selected project")
            return
        }
        Task {
            switch agent {
            case .claude: await openClaudePane(project: project)
            case .codex: await openCodexPane(project: project)
            }
        }
    }

    func newShellTabInSelectedProject() {
        guard let project = projects.first(where: { $0.id == selectedProjectId }) else { return }
        Task { await openShellPane(project: project) }
    }

    func closePane(_ id: PaneID) async {
        tearDown(id)
        try? await store.removePane(id)
    }

    // MARK: Mirror

    func agent(forPane paneId: PaneID?) -> AgentKind? {
        paneId.flatMap { panes[$0]?.agent }
    }

    func sessionId(forPane paneId: PaneID) -> SessionID? {
        recordedSessions[paneId] ?? launchSessions[paneId]
    }

    // MARK: Sending prompts

    enum SendOutcome { case sent, queued, failed }

    /// Types a message into a Claude tab now if that is safe, otherwise holds
    /// it until Claude is ready. A message is never typed into a permission
    /// prompt or into a turn in progress. The queue lives in memory only.
    @discardableResult
    func sendOrQueue(_ text: String, toPane paneId: PaneID) -> SendOutcome {
        guard panes[paneId] != nil else { return .failed }
        promptQueue.enqueue(text, for: paneId)
        guard promptQueue.count(for: paneId) > 0 else { return .failed } // blank text
        touchProject(panes[paneId]?.descriptor.projectId)
        setSuggestion(nil, for: paneId)
        if flushQueue(paneId) { return .sent }
        syncQueuedCount(paneId)
        return .queued
    }

    private func canSendNow(_ paneId: PaneID) -> Bool {
        if let driver = codexChats[paneId] { return driver.isReady && !driver.isWorking && paneAttention[paneId] == nil }
        // Without hooks there is no state to wait for.
        guard hookServer != nil else { return true }
        guard let state = paneStates[paneId] else { return false } // still starting up
        return PromptGate.canSend(state: state, attention: paneAttention[paneId],
                                  command: promptQueue.nextIsCommand(for: paneId))
    }

    @discardableResult
    private func flushQueue(_ paneId: PaneID) -> Bool {
        let solo = promptQueue.nextIsSolo(for: paneId)
        guard canSendNow(paneId), let text = promptQueue.drain(for: paneId) else {
            syncQueuedCount(paneId)
            return false
        }
        guard panes[paneId]?.send(prompt: text) == true else {
            // The terminal is not ready yet: keep the message and try again.
            promptQueue.putBack(text, for: paneId, solo: solo)
            syncQueuedCount(paneId)
            scheduleFlushRetry(paneId)
            return false
        }
        syncQueuedCount(paneId)
        // A slash command like /model fires no hook, so nothing else would
        // send what is queued behind it.
        if PromptQueue.isCommand(text), promptQueue.count(for: paneId) > 0 { scheduleFlushRetry(paneId) }
        return true
    }

    /// Sends a message ahead of anything queued, stopping Claude's current
    /// step first if it is working: Ctrl-Return in the terminal. The message
    /// goes by itself and the rest stay queued.
    @discardableResult
    func sendNow(_ text: String, toPane paneId: PaneID) -> SendOutcome {
        guard panes[paneId] != nil else { return .failed }
        promptQueue.enqueue(text, for: paneId)
        let texts = promptQueue.texts(for: paneId)
        guard let last = texts.last else { return .failed } // blank text
        return sendQueuedNow(at: texts.count - 1, expected: last, forPane: paneId)
    }

    /// Send Now on a queued message: it moves to the front and goes alone as
    /// soon as Claude stops. Esc stops a working turn; a prompt waiting on
    /// the user is left for them to answer, and the message follows.
    @discardableResult
    func sendQueuedNow(at index: Int, expected: String, forPane paneId: PaneID) -> SendOutcome {
        guard promptQueue.sendNext(at: index, expected: expected, for: paneId) else { return .failed }
        if flushQueue(paneId) { return .sent }
        if paneStates[paneId] == .working { interrupt(pane: paneId) }
        return .queued
    }

    func editQueued(at index: Int, expected: String, to text: String, forPane paneId: PaneID) {
        promptQueue.replace(at: index, expected: expected, with: text, for: paneId)
        syncQueuedCount(paneId)
    }

    func removeQueued(at index: Int, expected: String, forPane paneId: PaneID) {
        promptQueue.remove(at: index, expected: expected, for: paneId)
        syncQueuedCount(paneId)
    }

    /// Switches a tab's model the way the user would, with `/model <name>`,
    /// queued like any message so it never lands mid-turn.
    @discardableResult
    func setModel(_ model: String, forPane paneId: PaneID) -> SendOutcome {
        // Claude's aliases and /model menu; Codex's differ.
        guard panes[paneId]?.isClaude == true, let text = ModelCommand.text(for: model) else { return .failed }
        return sendOrQueue(text, toPane: paneId)
    }

    private func scheduleFlushRetry(_ paneId: PaneID) {
        promptRetries.schedule(for: paneId) { [weak self] in
            guard let self, self.panes[paneId] != nil,
                  self.promptQueue.count(for: paneId) > 0 else { return false }
            self.flushQueue(paneId)
            // A slash command can leave another command or prompt behind it.
            // The current burst owns retries, including calls from flushQueue.
            return self.promptQueue.count(for: paneId) > 0
        }
    }

    private func syncQueuedCount(_ paneId: PaneID) {
        let count = promptQueue.count(for: paneId)
        queuedCounts[paneId] = count > 0 ? count : nil
        let texts = promptQueue.texts(for: paneId)
        queuedMessages[paneId] = texts.isEmpty ? nil : texts
        companion.setNeedsSnapshot()
    }

    // MARK: Changes and diffs

    /// The folder whose changes the panel shows: the selected Claude tab's
    /// worktree, or the project folder for shell and ssh tabs.
    var selectedWorktreePath: String? {
        if let id = selectedPaneId, let path = paneWorktreePaths[id] { return path }
        guard let pid = selectedProjectId else { return nil }
        return projects.first { $0.id == pid }?.path
    }

    /// Worktrees on a branch other than their project's base, by path, with
    /// that branch: the ones that can have a pull request.
    private func pullRequestTargets() -> [String: String] {
        var result: [String: String] = [:]
        for wt in worktrees {
            guard let project = projects.first(where: { $0.id == wt.projectId }),
                  let branch = changes.snapshots[wt.path]?.branch,
                  branch != project.baseBranch else { continue }
            result[wt.path] = branch
        }
        return result
    }

    func pullRequest(forPath path: String) -> PullRequestStatus? {
        pullRequests.statuses[path]
    }

    func branchLabel(for project: Project) -> String {
        changes.snapshots[project.path]?.branchLabel ?? project.baseBranch
    }

    private func updateChangesFocus() {
        changes.focus(selectedWorktreePath)
    }

    func toggleInspector() {
        showInspector.toggle()
    }

    func toggleInspector(_ tab: InspectorTab) {
        if showInspector && inspectorTab == tab {
            showInspector = false
        } else {
            inspectorTab = tab
            showInspector = true
        }
    }

    func openDiff(_ file: ChangedFile) {
        guard let pid = selectedProjectId, let path = selectedWorktreePath else { return }
        openFileTarget = nil
        openDiffTarget = OpenDiff(projectId: pid, worktreePath: path, file: file)
        // Keystrokes should reach the diff's comment field, not the hidden terminal.
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func closeDiff() {
        openDiffTarget = nil
    }

    /// Shows a file from the Files panel over the terminal.
    func openFile(_ relativePath: String) {
        guard let pid = selectedProjectId, let path = selectedWorktreePath else { return }
        openDiffTarget = nil
        openFileTarget = OpenFile(projectId: pid, worktreePath: path, path: relativePath)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Shows a file Claude touched, given as an absolute path. Files outside
    /// the tab's folder are not opened.
    func openFile(absolutePath: String) {
        if let relative = relativePath(ofAbsolute: absolutePath) { openFile(relative) }
    }

    func relativePath(ofAbsolute path: String) -> String? {
        guard let root = selectedWorktreePath else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    func closeFile() {
        openFileTarget = nil
    }

    /// Back to the terminal: closes a diff or file shown over it.
    func closeOverlays() {
        openDiffTarget = nil
        openFileTarget = nil
    }

    func addReviewComment(_ comment: ReviewComment, scope: ReviewScope) {
        reviewComments.add(comment, in: scope)
    }

    func removeReviewComment(_ id: UUID, scope: ReviewScope) {
        reviewComments.remove(id, in: scope)
    }

    enum ReviewSendResult { case sent, queued, noSession }

    /// Sends only to a live Claude tab in the reviewed worktree. Drafts remain
    /// available when that worktree has no live session or delivery fails.
    func sendReview(scope: ReviewScope, extra: ReviewComment?) -> ReviewSendResult {
        let candidates = panes(for: scope.projectId).compactMap { pane -> ReviewDestination? in
            guard pane.isClaude, let path = worktreePath(forPane: pane.id) else { return nil }
            return ReviewDestination(id: pane.id,
                                     scope: ReviewScope(projectId: pane.descriptor.projectId, worktreePath: path),
                                     isLive: !pane.hasExited && paneStates[pane.id] != .detached)
        }
        var outcome: SendOutcome = .failed
        // Keep the value local while the delivery closure updates the model's queue.
        var drafts = reviewComments
        let paneId = drafts.send(in: scope, extra: extra, candidates: candidates, selected: selectedPaneId) {
            paneId, message in
            outcome = sendOrQueue(message, toPane: paneId)
            return outcome != .failed
        }
        guard let paneId else { return .noSession }
        reviewComments = drafts
        closeOverlays()
        selectedPaneId = paneId
        return outcome == .sent ? .sent : .queued
    }

    // MARK: Suggested prompt

    /// Keeps a tab's suggestion and tells phones and paired Macs when it changes.
    private func setSuggestion(_ text: String?, for paneId: PaneID) {
        guard suggestions[paneId] != text else { return }
        suggestions[paneId] = text
        companion.setNeedsSnapshot()
    }

    /// Reads Claude Code's suggested next prompt after a turn ends. It draws a
    /// moment after the Stop hook, so this tries a few times. Only for a tab
    /// showing its chat: nobody can have typed into that terminal, so text in
    /// its prompt box is the suggestion.
    private func readSuggestion(_ paneId: PaneID) {
        Task { [weak self] in
            for delay in [0.5, 1.0, 2.0, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, let pane = self.panes[paneId], self.showsChat(paneId),
                      let state = self.paneStates[paneId], state != .working, state != .needsInput,
                      self.promptQueue.count(for: paneId) == 0 else { return }
                if let text = pane.promptSuggestion() {
                    self.setSuggestion(text, for: paneId)
                    return
                }
            }
        }
    }

    // MARK: Chat or terminal

    /// Whether this tab shows its chat instead of its terminal.
    func showsChat(_ paneId: PaneID) -> Bool {
        guard let pane = panes[paneId], pane.isAgent else { return false }
        if pane.usesNativeCodexChat { return true }
        return chatOverrides[paneId] ?? chatByDefault
    }

    func setChat(_ chat: Bool, forPane paneId: PaneID) {
        guard panes[paneId]?.usesNativeCodexChat != true else { return }
        chatOverrides[paneId] = chat
        // Whatever is typed in the terminal from here on isn't Claude's suggestion.
        if !chat { setSuggestion(nil, for: paneId) }
    }

    /// Switches the selected Claude tab between its terminal and its chat.
    func toggleChat() {
        guard let id = selectedPaneId, panes[id]?.isAgent == true else { return }
        setChat(!showsChat(id), forPane: id)
    }

    /// Changes what new Claude tabs open in. Tabs already open keep their view.
    func setChatByDefault(_ chat: Bool) {
        guard chat != chatByDefault else { return }
        for (id, pane) in panes where pane.isClaude && chatOverrides[id] == nil {
            chatOverrides[id] = chatByDefault
        }
        chatByDefault = chat
        UserDefaults.standard.set(chat, forKey: "chatByDefault")
    }

    /// Presses Shift-Tab until the tab reports `target` as its permission mode.
    /// Claude Code cycles its modes in an order that depends on its settings, so
    /// this watches for the transcript's mode record after each press instead
    /// of counting. Returns false when a press changes nothing.
    func setPermissionMode(_ target: String, forPane paneId: PaneID) async -> Bool {
        for _ in 0..<6 {
            guard let pane = panes[paneId], pane.isClaude else { return false }
            let before = paneModes[paneId]
            if before == target { return true }
            guard pane.cycleMode() else { return false }
            var waited = 0
            while paneModes[paneId] == before, waited < 20 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            if paneModes[paneId] == before { return false }
        }
        return paneModes[paneId] == target
    }

    /// Esc, as if pressed in the terminal: stops Claude's current turn.
    func interrupt(pane paneId: PaneID) {
        panes[paneId]?.interrupt()
    }

    // MARK: Permissions

    func pendingPermission(forPane paneId: PaneID) -> PendingPermission? {
        pendingPermissions.first { $0.paneId == paneId }
    }

    func resolvePermission(_ id: UUID, _ decision: PermissionDecision) {
        let request = pendingPermissions.first { $0.id == id }
        pendingPermissions.removeAll { $0.id == id }
        companion.setNeedsSnapshot()
        if let request, request.toolName == TrustFolder.toolName {
            answerTrust(request, decision)
            return
        }
        if let paneId = request?.paneId, codexChats[paneId]?.resolve(id, decision: decision) == true { return }
        Task { await self.broker.resolve(id, decision) }
    }

    /// Answers a question Claude asked with options: the choice goes back to
    /// Claude Code as the tool's answer, so no terminal dialog is needed.
    func answerQuestion(_ id: UUID, answer: String) {
        if let paneId = pendingPermissions.first(where: { $0.id == id })?.paneId,
           codexChats[paneId]?.answer(id, answer: answer) == true { return }
        guard let request = pendingPermissions.first(where: { $0.id == id }),
              request.toolName == AskUserQuestion.toolName,
              let prompt = AskUserQuestion.prompt(from: request.toolInput) else { return }
        let input = AskUserQuestion.updatedInput(request.toolInput, question: prompt.question, answer: answer)
        resolvePermission(id, .allowWithInput(input))
    }

    // MARK: Folder trust

    /// Tabs whose trust question the user left to the terminal.
    private var trustLeftToTerminal: Set<PaneID> = []

    /// Claude Code asks about an unfamiliar folder before it starts, and no
    /// hook fires until it is answered. A tab that has shown no session and no
    /// status line after a moment, in a folder `~/.claude.json` doesn't list,
    /// is sitting at that question: show it as a card so a phone or another Mac
    /// can answer too. The phone is only notified once the card has stood a
    /// few seconds, since a slow start looks the same at first.
    private func scheduleTrustCheck(paneId: PaneID, path: String) {
        Task { [weak self] in
            for (delay, notify) in [(3.0, false), (4.0, true)] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.panes[paneId] != nil else { return }
                self.checkTrust(paneId: paneId, path: path, notify: notify)
            }
        }
    }

    private func checkTrust(paneId: PaneID, path: String, notify: Bool) {
        guard hookServer != nil, let pane = panes[paneId], pane.isClaude, !pane.hasExited,
              !claudeHasStarted(paneId), !trustLeftToTerminal.contains(paneId) else { return }
        let config = try? Data(contentsOf: FolderTrust.configFile)
        guard !FolderTrust.isTrusted(path, config: config) else { return }
        var request = pendingPermissions.first { $0.paneId == paneId && $0.toolName == TrustFolder.toolName }
        if request == nil {
            guard !pendingPermissions.contains(where: { $0.paneId == paneId }) else { return }
            let card = PendingPermission(sessionId: launchSessions[paneId] ?? "", paneId: paneId,
                                         toolName: TrustFolder.toolName,
                                         toolInput: .object(["path": .string(path)]), suggestions: nil)
            pendingPermissions.append(card)
            requestAttention()
            companion.setNeedsSnapshot()
            request = card
        }
        if notify, let request {
            companion.permissionRequested(phoneSummary(of: request), projectName: projectName(forPane: paneId))
        }
    }

    /// Claude only runs hooks and draws its status line once it is past the
    /// trust question. Until then nothing typed in chat can reach it.
    func claudeHasStarted(_ paneId: PaneID) -> Bool {
        hookServer == nil || paneStates[paneId] != nil || paneStatus[paneId] != nil
            || panes[paneId]?.hasExited == true
    }

    /// Claude started, so the folder question was answered in the terminal.
    private func dropTrustCard(_ paneId: PaneID) {
        guard pendingPermissions.contains(where: { $0.paneId == paneId && $0.toolName == TrustFolder.toolName })
        else { return }
        pendingPermissions.removeAll { $0.paneId == paneId && $0.toolName == TrustFolder.toolName }
        companion.setNeedsSnapshot()
    }

    /// Passes the answer to Claude's own dialog. Tether never trusts a folder
    /// itself: Down and Return take "Yes, I trust this folder", Esc declines.
    private func answerTrust(_ request: PendingPermission, _ decision: PermissionDecision) {
        guard let paneId = request.paneId, let pane = panes[paneId] else { return }
        switch decision {
        case .allow, .allowAlways, .allowWithInput: pane.trustFolder()
        case .deny: pane.interrupt()
        case .askInTerminal: trustLeftToTerminal.insert(paneId)
        }
    }

    // MARK: Hook events

    private func handle(_ event: HookEvent) {
        switch event {
        case .session(let session):
            guard let paneId = session.paneId, panes[paneId] != nil, codexChats[paneId] == nil else { return }
            codexReports[paneId] = Date()
            codexMissingReports.remove(paneId)
            let previous = paneStates[paneId]
            paneStates[paneId] = session.state
            paneAttention[paneId] = session.attention
            dropTrustCard(paneId)
            updateTurnStart(paneId, previous: previous, state: session.state)
            // A turn started, from chat, the terminal or the phone.
            if session.state == .working, previous != .working { touchProject(panes[paneId]?.descriptor.projectId) }
            if session.state == .working || session.state == .needsInput {
                setSuggestion(nil, for: paneId)
            } else if previous == .working {
                readSuggestion(paneId)
            }
            if let mode = session.permissionMode { paneModes[paneId] = mode }
            if let old = sessionId(forPane: paneId), old != session.id {
                // /clear or a fork gave this tab a new session.
                mirror.stop(old)
                interruptWatchers.removeValue(forKey: old)?.cancel()
            }
            if recordedSessions[paneId] != session.id {
                recordedSessions[paneId] = session.id
                Task { try? await self.store.recordSession(session.id, forPane: paneId) }
            }
            let isClaude = panes[paneId]?.isClaude == true
            mirror.track(sessionId: session.id, path: session.transcriptPath, agent: panes[paneId]?.agent ?? .claude)
            recomputeProjectStates()
            notifyPhones(paneId: paneId, previous: previous, state: session.state, attention: session.attention)
            // Codex has an Interrupt hook; Claude's Esc only shows in its transcript.
            if isClaude { updateInterruptWatcher(for: session) }
            if session.state == .needsInput, previous != .needsInput { requestAttention() }
            flushQueue(paneId)
            if previous == .working, session.state != .working, let worktree = paneWorktreePaths[paneId] {
                // The turn ended: files may have changed, and the base branch may have moved.
                changes.refresh(worktree)
                pullRequests.refreshSoon(worktree)
                if [.done, .idle, .error].contains(session.state) { changes.fetchNow(worktree) }
            }
        case .permissionRequested(let request):
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
                companion.permissionRequested(phoneSummary(of: request), projectName: projectName(forPane: request.paneId))
            }
            requestAttention()
            companion.setNeedsSnapshot()
        case .permissionResolved(let id, _):
            pendingPermissions.removeAll { $0.id == id }
            companion.setNeedsSnapshot()
        case .status(let paneId, let report):
            guard let pane = panes[paneId] else { return }
            dropTrustCard(paneId)
            var changed = false
            if paneStates[paneId] == .detached, !pane.hasExited {
                // Claude only draws its status line while running, so this tab
                // hasn't ended, whatever a stray SessionEnd said.
                paneStates[paneId] = .idle
                paneAttention[paneId] = nil
                if let id = sessionId(forPane: paneId) {
                    Task { await self.registry.setState(.idle, for: id) }
                }
                recomputeProjectStates()
                changed = true
            }
            if paneStatus[paneId] != report.status {
                paneStatus[paneId] = report.status
                changed = true
            }
            if let limits = report.limits {
                if limits != usageLimits {
                    usageLimits = limits
                    UserDefaults.standard.set(SavedLimits.encode(limits), forKey: "usageLimits")
                }
                let now = Date()
                usageLimitsAt = now
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "usageLimitsAt")
                changed = true
            }
            if changed { companion.setNeedsSnapshot() }
        }
    }

    private func updateInterruptWatcher(for session: Session) {
        guard session.state == .working, let path = session.transcriptPath else {
            interruptWatchers.removeValue(forKey: session.id)?.cancel()
            return
        }
        guard interruptWatchers[session.id] == nil else { return }
        let sessionId = session.id
        let registry = self.registry
        interruptWatchers[sessionId] = Task { [weak self] in
            var tail = TranscriptTail(path: path)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if tail.readNewLines().contains(where: TranscriptSignals.isUserInterrupt),
                   let updated = await registry.setState(.idle, for: sessionId) {
                    self?.interruptWatchers[sessionId] = nil
                    self?.handle(.session(updated))
                    return
                }
            }
        }
    }

    private func paneFocused(_ id: PaneID) async {
        guard NSApp.isActive, let session = await registry.paneFocused(id) else { return }
        handle(.session(session))
    }

    private func stopInterruptWatcher(forPane id: PaneID) {
        if let sessionId = recordedSessions[id] {
            interruptWatchers.removeValue(forKey: sessionId)?.cancel()
        }
    }

    private func stopMirror(forPane id: PaneID) {
        if let sessionId = sessionId(forPane: id) { mirror.stop(sessionId) }
    }

    private func paneDidExit(_ id: PaneID) async {
        codexMissingReports.remove(id)
        companion.setNeedsSnapshot()
        stopInterruptWatcher(forPane: id)
        _ = await broker.cancelAll(paneId: id)
        pendingPermissions.removeAll { $0.paneId == id }
        if let session = await registry.paneExited(id) {
            let previous = paneStates[id]
            paneStates[id] = session.state
            turnStartedAt[id] = nil
            recomputeProjectStates()
            notifyPhones(paneId: id, previous: previous, state: session.state, attention: nil)
        }
    }

    /// Same rule as the phone's Live Activity timer: a turn starts when Claude
    /// starts working and ends when it is neither working nor waiting on you.
    private func updateTurnStart(_ paneId: PaneID, previous: SessionState?, state: SessionState) {
        let active: Set<SessionState> = [.working, .needsInput]
        if state == .working, !(previous.map(active.contains) ?? false) {
            turnStartedAt[paneId] = Date()
        } else if !active.contains(state) {
            turnStartedAt[paneId] = nil
        }
    }

    private func recomputeProjectStates() {
        var result: [ProjectID: SessionState] = [:]
        for pane in panes.values {
            let state = paneStates[pane.id] ?? .idle
            let pid = pane.descriptor.projectId
            if let current = result[pid], current.urgency >= state.urgency { continue }
            result[pid] = state
        }
        sessionStates = result
        let waiting = result.values.filter { $0 == .needsInput }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        companion.setNeedsSnapshot()
    }

    private func requestAttention() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Launch

    private func startHookServer() async {
        let router = HookRouter(token: launchToken, registry: registry, broker: broker) { [weak self] event in
            await self?.handle(event)
        }
        let server = HookServer(router: router)
        do {
            let port = try await server.start()
            let url = ProjectStore.defaultFileURL().deletingLastPathComponent()
                .appendingPathComponent("hooks.json")
            // Tether's status line replaces the user's, then runs it. Read at
            // launch: a change to it takes effect when Tether restarts.
            let userSettings = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json")
            let statusLine = (try? Data(contentsOf: userSettings)).flatMap(HookSettings.userStatusLine(settings:))
            try HookSettings.write(port: port, to: url, userStatusLine: statusLine)
            hookServer = server
            hookSettingsPath = url.path
            hookPort = port
            hookStatusMessage = nil
        } catch {
            server.stop()
            hookStatusMessage = "Session tracking is off: \(error.localizedDescription)"
            print("Hook server failed: \(error)")
        }
    }

    /// Starts the hook server, then restores persisted panes, staggered so a
    /// dozen projects don't spawn a dozen `claude` processes at once. Projects
    /// without any pane get a Claude session: the "ready to go" promise.
    private func restore() async {
        _ = toolPaths()
        await startHookServer()
        companion.start()
        pullRequests.onChange = { [weak self] in self?.companion.setNeedsSnapshot() }
        pullRequests.targets = { [weak self] in self?.pullRequestTargets() ?? [:] }
        pullRequests.start()
        preview.folders = { [weak self] in
            guard let self else { return [] }
            return self.projects.map(\.path) + self.worktrees.map(\.path)
        }
        await reload()
        splits = await store.state.splits
        updater.startAutomaticChecks()
        // A project with no tabs shows its start page rather than starting Claude.
        let descriptors = await store.state.panes
        // Someone who already has projects has been through setup, in an older version.
        if !UserDefaults.standard.bool(forKey: "welcomeSeen") {
            if projects.isEmpty {
                needsWelcome = true
            } else {
                UserDefaults.standard.set(true, forKey: "welcomeSeen")
            }
        }
        for (i, d) in descriptors.enumerated() {
            if i > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            await mount(d)
        }
        selectFirstPaneIfNeeded()
    }

    private func open(_ d: PaneDescriptor, persist: Bool = true) async {
        if persist { try? await store.addPane(d) }
        touchProject(d.projectId)
        await mount(d)
        showOverview = false
        selectedPaneId = d.id
    }

    private func mount(_ d: PaneDescriptor) async {
        guard panes[d.id] == nil else { return }
        var worktree: Worktree?
        var host: RemoteHost?
        var launchSession: SessionID?
        switch d.kind {
        case .claude(let wtId, let resume):
            worktree = await store.worktree(wtId)
            if let worktree { paneWorktreePaths[d.id] = worktree.path }
            if let resume, !resume.isEmpty {
                launchSession = resume
            } else {
                launchSession = UUID().uuidString.lowercased()
            }
        case .codex(let wtId, let resume):
            if d.codexChat != true, let resume, !resume.isEmpty { launchSession = resume }
            // New Codex terminal thread ids arrive with SessionStart.
            worktree = await store.worktree(wtId)
            if let worktree { paneWorktreePaths[d.id] = worktree.path }
        case .ssh(let hostId): host = await store.remoteHost(hostId)
        case .shell(let cwd), .command(let cwd, _): paneWorktreePaths[d.id] = cwd
        }
        var tools = ToolPaths()
        if let agent = d.kind.agent {
            tools = await toolPaths().value
            if tools.path(of: agent.rawValue) == nil {
                missingTools[d.id] = agent
            } else {
                missingTools[d.id] = nil
            }
        }
        let initialPrompt = initialPrompts.removeValue(forKey: d.id)
        var launch = TerminalLaunch.make(pane: d, worktree: worktree, remoteHost: host,
                                         token: launchToken, hookSettingsPath: hookSettingsPath,
                                         newSessionId: launchSession,
                                         initialPrompt: initialPrompt,
                                         permissionMode: d.readOnly == true && d.kind.agent == .claude ? "plan" : initialModes.removeValue(forKey: d.id),
                                         hookPort: hookPort,
                                         claudeExecutable: tools.path(of: AgentKind.claude.rawValue) ?? "claude",
                                         codexExecutable: tools.path(of: AgentKind.codex.rawValue) ?? "codex",
                                         searchPath: d.kind.agent == nil ? nil
                                            : tools.launchPath(inherited: ProcessInfo.processInfo.environment["PATH"]))
        var captureDirectory: URL?
        if case .command(_, let command) = d.kind {
            do {
                let folder = ProjectStore.defaultFileURL().deletingLastPathComponent()
                    .appendingPathComponent("command-runs/" + d.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                launch.environment["TETHER_RUN_LOG"] = folder.appendingPathComponent("output.log").path
                launch.environment["TETHER_RUN_STATUS"] = folder.appendingPathComponent("exit").path
                commandRuns[d.id] = CommandRunSummary(command: command)
                paneStates[d.id] = .working
                captureDirectory = folder
            } catch { codexErrors[d.id] = "Output capture failed: \(error)" }
        }
        let pane = TerminalPane(descriptor: d, launch: launch, controller: TerminalHost.controller)
        pane.onExit = { [weak self] id in
            guard let self else { return }
            Task { await self.paneDidExit(id) }
        }
        panes[d.id] = pane
        paneOrder.append(d.id)
        if let captureDirectory { monitorCommand(d.id, directory: captureDirectory) }
        if pane.usesNativeCodexChat, let worktree,
           let executable = tools.path(of: AgentKind.codex.rawValue) {
            startCodexChat(pane: pane, directory: worktree.path, executable: executable, initialPrompt: initialPrompt)
        } else if pane.agent == .codex, !pane.usesNativeCodexChat {
            scheduleCodexHealth(d.id)
        }
        if let launchSession {
            // Not persisted for --resume until a hook confirms the session
            // exists: resuming an id with no transcript would fail.
            launchSessions[d.id] = launchSession
            mirror.track(sessionId: launchSession, path: nil, agent: d.kind.agent ?? .claude)
        }
        if let worktree, case .claude = d.kind {
            scheduleTrustCheck(paneId: d.id, path: worktree.path)
        }
        companion.setNeedsSnapshot()
    }

    /// The cached search, started on first use. `retryMissingTool` drops it.
    private func toolPaths() -> Task<ToolPaths, Never> {
        if let toolPathsTask { return toolPathsTask }
        let overrides = ToolOverrides.all
        let task = Task.detached { await ToolLocator.locate(["claude", "codex"], overrides: overrides) }
        toolPathsTask = task
        return task
    }

    /// Searches again (after installing, or picking the file in `locateTool`)
    /// and restarts the tab in place.
    func retryMissingTool(_ id: PaneID) async {
        toolPathsTask = nil
        guard let pane = panes[id] else { return }
        let descriptor = pane.descriptor
        let wasSelected = selectedPaneId == id
        // Same place in the tab bar and the same split as before.
        let index = paneOrder.firstIndex(of: id)
        let keptSplits = splits
        tearDown(id)
        await mount(descriptor)
        if let index, paneOrder.last == id {
            paneOrder.removeLast()
            paneOrder.insert(id, at: min(index, paneOrder.count))
        }
        splits = keptSplits
        if wasSelected { selectedPaneId = id }
    }

    /// Remembers the file the user picked for `agent`, then retries the tab.
    func locateTool(_ agent: AgentKind, at path: String, pane id: PaneID) async {
        ToolOverrides.set(path, for: agent.rawValue)
        await retryMissingTool(id)
    }

    private func tearDown(_ id: PaneID) {
        let partner = split(containing: id)?.partner(of: id)
        splits.removeAll { $0.contains(id) }
        stopInterruptWatcher(forPane: id)
        stopMirror(forPane: id)
        codexGenerations[id] = nil
        codexChats.removeValue(forKey: id)?.stop()
        nativeLiveText[id] = nil
        codexErrors[id] = nil
        codexMissingReports.remove(id)
        codexLaunches[id] = nil; codexReports[id] = nil
        commandMonitors.removeValue(forKey: id)?.cancel()
        commandRuns[id] = nil
        panes[id] = nil
        paneOrder.removeAll { $0 == id }
        paneStates[id] = nil
        paneAttention[id] = nil
        paneModes[id] = nil
        paneStatus[id] = nil
        paneWorktreePaths[id] = nil
        missingTools[id] = nil
        promptRetries.cancel(id)
        promptQueue.clear(pane: id)
        queuedCounts[id] = nil
        queuedMessages[id] = nil
        drafts[id] = nil
        setSuggestion(nil, for: id)
        turnStartedAt[id] = nil
        recordedSessions[id] = nil
        launchSessions[id] = nil
        pendingPermissions.removeAll { $0.paneId == id }
        trustLeftToTerminal.remove(id)
        Task { _ = await self.broker.cancelAll(paneId: id) }
        if selectedPaneId == id {
            // Closing half of a split leaves the other half selected.
            if let partner, panes[partner] != nil {
                selectedPaneId = partner
            } else {
                selectFirstPaneIfNeeded(force: true)
            }
        }
        recomputeProjectStates()
    }

    private func selectFirstPaneIfNeeded(force: Bool = false) {
        guard let pid = selectedProjectId else { selectedPaneId = nil; return }
        let visible = panes(for: pid)
        if force || !visible.contains(where: { $0.id == selectedPaneId }) {
            selectedPaneId = visible.first?.id
        }
    }
}

enum InspectorTab: String {
    case changes, files, preview
}

/// A file from the Files panel shown over the terminal area.
struct OpenFile: Equatable {
    var projectId: ProjectID
    var worktreePath: String
    /// Relative to `worktreePath`.
    var path: String

    var url: URL { URL(fileURLWithPath: worktreePath).appendingPathComponent(path) }
}

/// A file's diff opened over the terminal area.
struct OpenDiff: Equatable {
    var projectId: ProjectID
    var worktreePath: String
    var file: ChangedFile
}

extension SessionState {
    /// Which state wins when a project has several panes.
    var urgency: Int {
        switch self {
        case .needsInput: 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        case .detached: 0
        }
    }
}

// MARK: - Companion

extension AppModel {
    /// Everything the phone shows, in sidebar and tab order.
    func companionSnapshot(macName: String) -> Snapshot {
        let sections = projectSections()
        let projectList = sections.pinned.map {
            ProjectSummary(id: $0.id, name: $0.name, branch: branchLabel(for: $0), pinned: true, active: true)
        } + sections.active.map {
            ProjectSummary(id: $0.id, name: $0.name, branch: branchLabel(for: $0), pinned: false, active: true)
        } + sections.inactive.map {
            ProjectSummary(id: $0.id, name: $0.name, branch: branchLabel(for: $0), pinned: false, active: false)
        }
        var sessions: [SessionSummary] = []
        for project in projects {
            for pane in panes(for: project.id) {
                let agent = pane.descriptor.kind.agent
                guard agent != nil || commandRuns[pane.id] != nil else { continue }
                let pr = worktreePath(forPane: pane.id).flatMap { pullRequests.statuses[$0] }.map {
                    PullRequestSummary(number: $0.number, title: $0.title, url: $0.url, state: $0.state.rawValue,
                                       headRevision: $0.headRevision, checksSummary: $0.checksSummary)
                }
                sessions.append(SessionSummary(
                    id: pane.id, projectId: project.id, sessionId: sessionId(forPane: pane.id),
                    title: pane.title, state: paneStates[pane.id] ?? .idle,
                    attention: paneAttention[pane.id], queued: queuedCounts[pane.id] ?? 0,
                    preview: mirror.model(for: sessionId(forPane: pane.id))?.preview(),
                    permissionMode: paneModes[pane.id], status: paneStatus[pane.id], agent: agent,
                    suggestion: suggestions[pane.id], command: commandRuns[pane.id], warning: warning(for: pane.id),
                    liveText: nativeLiveText[pane.id], pullRequest: pr))
            }
        }
        let permissions = pendingPermissions.map(phoneSummary(of:))
        let colors = TerminalHost.palette
        return Snapshot(macName: macName, projects: projectList, sessions: sessions, permissions: permissions,
                        limits: usageLimits.flatMap { SavedLimits.current($0, now: Date()) },
                        limitsAt: usageLimitsAt,
                        theme: MacTheme(background: colors.surface.hexString, foreground: colors.text.hexString),
                        shortcuts: quickActions.map { ShortcutSummary(id: $0.id, projectId: $0.projectId, label: $0.label, command: $0.command) })
    }
}

// MARK: - Phone: changes, diffs, images

/// Why the phone's request couldn't be answered, shown as is.
struct PhoneRequestError: Error {
    var message: String
}

extension AppModel {
    /// The folder a tab's Changes panel shows.
    private func changesPath(forPane paneId: PaneID) -> String? {
        if let path = worktreePath(forPane: paneId) { return path }
        guard let pane = agentTabs.first(where: { $0.pane.id == paneId }) else { return nil }
        return pane.project.path
    }

    func changesForPhone(paneId: PaneID) -> Result<ChangesSnapshot, PhoneRequestError> {
        guard let path = changesPath(forPane: paneId) else {
            return .failure(PhoneRequestError(message: "That tab is no longer open."))
        }
        if let snapshot = changes.snapshots[path] { return .success(snapshot) }
        let message = changes.errors[path] ?? "The Mac hasn't read this folder's changes yet. Try again in a moment."
        return .failure(PhoneRequestError(message: message))
    }

    func diffForPhone(paneId: PaneID, file: ChangedFile) async -> Result<FileDiff, PhoneRequestError> {
        guard let path = changesPath(forPane: paneId) else {
            return .failure(PhoneRequestError(message: "That tab is no longer open."))
        }
        // Only files the Mac itself lists, so the phone can't ask for arbitrary paths.
        guard changes.snapshots[path]?.files.contains(where: { $0.path == file.path }) == true else {
            return .failure(PhoneRequestError(message: "\(file.path) is no longer in the changes."))
        }
        do {
            return .success(try await changes.loadDiff(path: path, file: file))
        } catch {
            return .failure(PhoneRequestError(message: ChangesStore.describe(error)))
        }
    }

    func fileListForPhone(paneId: PaneID) async -> Result<[String], PhoneRequestError> {
        guard let path = changesPath(forPane: paneId) else {
            return .failure(PhoneRequestError(message: "That tab is no longer open."))
        }
        do {
            return .success(try await FileTree.list(in: path))
        } catch {
            return .failure(PhoneRequestError(message: "\(error)"))
        }
    }

    func fileForPhone(paneId: PaneID, path relative: String) async -> Result<RemoteFile, PhoneRequestError> {
        guard let root = changesPath(forPane: paneId) else {
            return .failure(PhoneRequestError(message: "That tab is no longer open."))
        }
        // Only files the Mac itself lists, so a paired device can't ask for arbitrary paths.
        guard let listed = try? await FileTree.list(in: root), listed.contains(relative) else {
            return .failure(PhoneRequestError(message: "\(relative) isn't in this project's files."))
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        let content = await Task.detached(priority: .userInitiated) { FileContent.load(url) }.value
        switch content {
        case .text(let lines, let truncated):
            return .success(RemoteFile(path: relative, kind: .text, text: lines.joined(separator: "\n"),
                                       truncated: truncated))
        case .image(let data):
            return .success(RemoteFile(path: relative, kind: .image, image: data))
        case .binary:
            return .success(RemoteFile(path: relative, kind: .binary))
        case .unreadable(let reason):
            return .success(RemoteFile(path: relative, kind: .unreadable, note: reason))
        }
    }

    func devServersForPhone(paneId: PaneID) async -> Result<[DevServerInfo], PhoneRequestError> {
        guard let path = changesPath(forPane: paneId) else {
            return .failure(PhoneRequestError(message: "That tab is no longer open."))
        }
        let found = await DevServerFinder.scan(folders: preview.folders())
        let servers = (found[DevServerFinder.key(for: path)] ?? []).map {
            DevServerInfo(port: $0.port, command: $0.command)
        }
        return .success(servers)
    }

    /// Saves images pasted into the chat and sends Claude their paths with the text.
    func sendWithImages(_ text: String, images: [Data], toPane paneId: PaneID) -> SendOutcome {
        guard agentTabs.contains(where: { $0.pane.id == paneId }) else { return .failed }
        do {
            let paths = try images.map { try ImageUpload.save($0, in: ImageUpload.defaultDirectory(), prefix: "mac") }
            return sendOrQueue(ImageUpload.prompt(text: text, imagePaths: paths), toPane: paneId)
        } catch {
            print("Pasted image refused: \(error)")
            return .failed
        }
    }

    /// Saves a photo from the phone and sends Claude its path with the text.
    func sendImage(_ data: Data, text: String, toPane paneId: PaneID) -> SendOutcome {
        guard agentTabs.contains(where: { $0.pane.id == paneId }) else { return .failed }
        do {
            let path = try ImageUpload.save(data, in: ImageUpload.defaultDirectory())
            return sendOrQueue(ImageUpload.prompt(text: text, imagePath: path), toPane: paneId)
        } catch {
            print("Image from phone refused: \(error)")
            return .failed
        }
    }
}

// MARK: - Push

extension AppModel {
    func phoneSummary(of request: PendingPermission) -> PermissionRequested {
        let summary = PermissionSummary.describe(toolName: request.toolName, input: request.toolInput)
        let question = request.toolName == AskUserQuestion.toolName
            ? questionPrompt(for: request) : nil
        return PermissionRequested(id: request.id, paneId: request.paneId, sessionId: request.sessionId,
                                   toolName: request.toolName, title: summary.title, detail: summary.detail,
                                   question: question, agent: agent(forPane: request.paneId))
    }

    func projectName(forPane paneId: PaneID?) -> String {
        guard let paneId, let pane = panes[paneId] else { return "Tether" }
        return projects.first { $0.id == pane.descriptor.projectId }?.name ?? "Tether"
    }

    /// Hands a tab's state change to the companion for alerts and Live Activities.
    fileprivate func notifyPhones(paneId: PaneID, previous: SessionState?, state: SessionState,
                                  attention: AttentionReason?) {
        guard let pane = panes[paneId] else { return }
        let transcript = mirror.model(for: sessionId(forPane: paneId))
        companion.sessionChanged(paneId: paneId, projectName: projectName(forPane: paneId), title: pane.title,
                                 previous: previous, state: state, attention: attention,
                                 preview: transcript?.preview(), steps: transcript?.stepsInCurrentTurn ?? 0, agent: pane.agent ?? .claude)
    }

    fileprivate func activityContentChanged(sessionId: SessionID) {
        guard let paneId = paneOrder.first(where: { self.sessionId(forPane: $0) == sessionId }),
              let state = paneStates[paneId], state == .working || state == .needsInput,
              let transcript = mirror.model(for: sessionId) else { return }
        companion.activityContentChanged(paneId: paneId, state: state, preview: transcript.preview(),
                                         steps: transcript.stepsInCurrentTurn)
    }
}

// MARK: - Native Codex and dogfooding workflows
extension AppModel {
    func openCodexChatPane(project: Project) async {
        _ = try? await startSession(projectId: project.id, branch: nil, prompt: nil,
                                    agent: .codex, nativeCodexChat: true, select: true)
    }

    func agent(for paneId: PaneID) -> AgentKind? { panes[paneId]?.agent }
    func isNativeCodex(_ paneId: PaneID) -> Bool { panes[paneId]?.usesNativeCodexChat == true }

    func warning(for paneId: PaneID) -> String? {
        if let error = codexErrors[paneId] { return error }
        if codexMissingReports.contains(paneId) {
            return "Codex isn’t reporting. Check the terminal for hook trust or sign-in prompts."
        }
        let occupants = paneOrder.compactMap { id -> AgentFolderOccupant? in
            guard let pane = panes[id], let agent = pane.agent, let path = paneWorktreePaths[id] else { return nil }
            return AgentFolderOccupant(id: id, agent: agent, path: path,
                                      isLive: !pane.hasExited && paneStates[id] != .detached && codexErrors[id] == nil)
        }
        if !SameFolderAgents(occupants).conflicts(for: paneId).isEmpty {
            return "Claude and Codex share this folder. Their edits can overlap. Use separate worktrees for independent work."
        }
        return nil
    }

    private func scheduleCodexHealth(_ id: PaneID) {
        let launched = Date()
        codexLaunches[id] = launched
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, let pane = self.panes[id], self.codexLaunches[id] == launched,
                  self.missingTools[id] == nil,
                  CodexReportingHealth.isMissing(agent: .codex, launchedAt: launched,
                      lastReportAt: self.codexReports[id], hasExited: pane.hasExited, now: Date()) else { return }
            self.codexMissingReports.insert(id)
            self.companion.setNeedsSnapshot()
        }
    }

    private func startCodexChat(pane: TerminalPane, directory: String, executable: String, initialPrompt: String?) {
        let id = pane.id
        let generation = UUID()
        codexGenerations[id] = generation
        let resume: String?
        if case .codex(_, let sessionId) = pane.descriptor.kind { resume = sessionId } else { resume = nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let environment = ProcessInfo.processInfo.environment
        let driver = CodexChatDriver(directory: directory, executable: executable, version: version,
                                    resumeSessionId: resume, readOnly: pane.descriptor.readOnly == true, environment: environment)
        codexChats[id] = driver
        pane.sendHandler = { [weak driver] in driver?.send($0) ?? false }
        pane.interruptHandler = { [weak driver] in driver?.interrupt() ?? false }
        driver.onReady = { [weak self] sessionId in
            guard let self, self.codexGenerations[id] == generation else { return }
            self.launchSessions[id] = sessionId
            self.recordedSessions[id] = sessionId
            self.codexErrors[id] = nil
            Task { try? await self.store.recordSession(sessionId, forPane: id) }
            self.companion.setNeedsSnapshot()
        }
        driver.onEvents = { [weak self] events in
            guard let self, self.codexGenerations[id] == generation,
                  let session = self.sessionId(forPane: id) else { return }
            self.mirror.append(events, for: session)
        }
        driver.onLiveText = { [weak self] text in
            guard let self, self.codexGenerations[id] == generation else { return }
            self.nativeLiveText[id] = text.map { String($0.suffix(16_000)) }
            self.companion.setNeedsSnapshot()
        }
        driver.onState = { [weak self] state, attention in
            guard let self, self.codexGenerations[id] == generation else { return }
            let previous = self.paneStates[id]
            self.paneStates[id] = state; self.paneAttention[id] = attention
            if state == .working { self.codexErrors[id] = nil }
            self.updateTurnStart(id, previous: previous, state: state)
            self.recomputeProjectStates()
            self.notifyPhones(paneId: id, previous: previous, state: state, attention: attention)
            if state == .done || state == .idle { self.flushQueue(id) }
            if previous == .working, state != .working {
                self.changes.refresh(directory); self.pullRequests.refreshSoon(directory)
            }
            self.companion.setNeedsSnapshot()
        }
        driver.onPermission = { [weak self] request in
            guard let self, self.codexGenerations[id] == generation else { return }
            var card = request; card.paneId = id
            self.pendingPermissions.append(card)
            self.requestAttention()
            self.companion.permissionRequested(self.phoneSummary(of: card), projectName: self.projectName(forPane: id))
            self.companion.setNeedsSnapshot()
        }
        driver.onResolved = { [weak self] requestId in
            guard let self, self.codexGenerations[id] == generation else { return }
            self.pendingPermissions.removeAll { $0.id == requestId }
            self.companion.setNeedsSnapshot()
        }
        driver.onError = { [weak self] error in
            guard let self, self.codexGenerations[id] == generation else { return }
            self.codexErrors[id] = error
            self.pendingPermissions.removeAll { $0.paneId == id }
            self.companion.setNeedsSnapshot()
        }
        Task { await driver.start(initialPrompt: initialPrompt, review: pane.descriptor.readOnly == true && initialPrompt != nil) }
    }

    private func monitorCommand(_ id: PaneID, directory: URL) {
        commandMonitors[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let previous = self.commandRuns[id], self.panes[id] != nil else { return }
                do {
                    let next = try await Task.detached(priority: .utility) {
                        try ShortcutCapture.read(in: directory, previous: previous)
                    }.value
                    guard !Task.isCancelled, self.panes[id] != nil else { return }
                    if next != previous {
                        self.commandRuns[id] = next
                        if let code = next.exitCode {
                            self.paneStates[id] = code == 0 ? .done : .error
                            if code != 0 {
                                self.companion.shortcutFailed(paneId: id, projectName: self.projectName(forPane: id),
                                    title: self.panes[id]?.title ?? "Shortcut", exitCode: code, output: next.output)
                            }
                        }
                        self.companion.setNeedsSnapshot()
                    }
                    if next.exitCode != nil { return }
                } catch {
                    self.codexErrors[id] = "Couldn’t read shortcut output: \(error)"
                    self.companion.setNeedsSnapshot()
                }
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            }
        }
    }

    func runShortcut(_ shortcutId: UUID, paneId: PaneID?) async throws -> PaneID {
        guard let action = quickActions.first(where: { $0.id == shortcutId }),
              let id = await runQuickAction(action, inPane: paneId, select: false) else {
            throw StartError(description: "That shortcut or tab is no longer available on the Mac.")
        }
        return id
    }

    func performPullRequest(_ action: PullRequestAction, paneId: PaneID) async throws -> String {
        guard let pane = panes[paneId], let path = worktreePath(forPane: paneId),
              let project = projects.first(where: { $0.id == pane.descriptor.projectId }),
              let branch = changes.snapshots[path]?.branch else {
            throw StartError(description: "Open a tab on a branch and wait for its changes to load.")
        }
        guard !prActionsInFlight.contains(path) else { throw StartError(description: "A pull request action is already running here.") }
        guard let cli = GitHubCLI.locate() else { throw StartError(description: "Install and sign in to GitHub CLI on the host Mac first.") }
        prActionsInFlight.insert(path)
        defer { prActionsInFlight.remove(path); pullRequests.refreshSoon(path); companion.setNeedsSnapshot() }
        let result = try await cli.perform(action, branch: branch, expectedBase: project.baseBranch, in: path)
        return result.isEmpty ? "Pull request action completed." : result
    }
}

extension AppModel {
    func transferDraft(for paneId: PaneID, kind: AgentTransferKind) async throws -> AgentTransferDraft {
        guard let pane = panes[paneId], let source = pane.agent, !pane.hasExited,
              AgentTransferMessage.canStart(state: paneStates[paneId] ?? .detached, attention: paneAttention[paneId]),
              let path = paneWorktreePaths[paneId], let wtId = pane.descriptor.kind.worktreeId,
              let wt = worktrees.first(where: { $0.id == wtId }), wt.path == path,
              let project = projects.first(where: { $0.id == pane.descriptor.projectId }) else {
            throw StartError(description: "Let the source agent finish or stop its turn before starting a review or handoff.")
        }
        let git = GitRunner()
        let revision = try await git.run(["rev-parse", "HEAD"], in: path).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = try await git.run(["branch", "--show-current"], in: path).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let changes = self.changes.snapshots[path]
        return AgentTransferDraft(paneId: paneId, kind: kind, target: source == .claude ? .codex : .claude,
            directory: path, revision: revision, branch: branch,
            message: AgentTransferMessage.compose(kind: kind, source: source, directory: path,
                base: changes?.baseRef ?? project.baseBranch, files: changes?.files.map(\.path) ?? [],
                items: mirror.model(for: sessionId(forPane: paneId))?.items ?? []))
    }

    func startTransfer(_ draft: AgentTransferDraft, message: String) async throws {
        let fresh = try await transferDraft(for: draft.paneId, kind: draft.kind)
        guard fresh.directory == draft.directory, fresh.revision == draft.revision, fresh.branch == draft.branch,
              fresh.target == draft.target, let source = panes[draft.paneId],
              let worktreeId = source.descriptor.kind.worktreeId else {
            throw StartError(description: "The source folder or branch changed. Reopen the preview before continuing.")
        }
        let kind: PaneKind = draft.target == .codex
            ? .codex(worktreeId: worktreeId, resumeSessionId: nil)
            : .claude(worktreeId: worktreeId, resumeSessionId: nil)
        let pane = PaneDescriptor(projectId: source.descriptor.projectId, kind: kind,
            title: "\(draft.target.displayName) \(draft.kind == .review ? "Review" : "Handoff")",
            codexChat: draft.target == .codex ? true : nil, readOnly: draft.kind == .review ? true : nil)
        initialPrompts[pane.id] = message
        if draft.target == .claude, draft.kind == .review { initialModes[pane.id] = "plan" }
        await open(pane)
    }
}

extension AppModel {
    func questionPrompt(for request: PendingPermission) -> QuestionPrompt? {
        if let prompt = AskUserQuestion.prompt(from: request.toolInput) { return prompt }
        guard request.toolName == AskUserQuestion.toolName,
              let pane = request.paneId, isNativeCodex(pane),
              case .array(let questions)? = request.toolInput?["questions"], questions.count == 1,
              let question = questions.first,
              let text = question["question"]?.stringValue else { return nil }
        return QuestionPrompt(header: question["header"]?.stringValue ?? "", question: text, options: [])
    }

    /// Called as the app quits, so native app-server children cannot outlive it.
    func stopOwnedProcesses() async {
        for driver in codexChats.values { await driver.shutdown() }
        for monitor in commandMonitors.values { monitor.cancel() }
    }
}
