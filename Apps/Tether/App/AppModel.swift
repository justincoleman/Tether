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

    var selectedProjectId: ProjectID? {
        didSet {
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
    /// Right-hand panel, showing Changes or Files.
    var showInspector = false
    var inspectorTab: InspectorTab = .changes
    /// Shortcut commands for every project, shown in the top bar.
    private(set) var quickActions: [QuickAction] = []

    let mirror = MirrorStore()
    let releases = ReleaseNotesStore()
    let changes = ChangesStore()
    let companion = CompanionHub()

    /// The diff open over the terminal, if any.
    private(set) var openDiffTarget: OpenDiff?
    /// A file from the Files panel open over the terminal, if any.
    private(set) var openFileTarget: OpenFile?
    /// Comments collected on diffs, waiting to be sent to Claude as one message.
    private(set) var reviewComments: [ProjectID: [ReviewComment]] = [:]

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
    /// The task a new Claude tab starts on, passed as `claude "<prompt>"`.
    private var initialPrompts: [PaneID: String] = [:]
    /// `--permission-mode` for a tab started from the phone. Not persisted:
    /// a resumed tab gets the user's default again (issue #3).
    private var initialModes: [PaneID: String] = [:]
    /// Permission mode per tab, as last reported by a hook.
    private(set) var paneModes: [PaneID: String] = [:]
    /// Model and cost per tab, from the status line relay.
    private(set) var paneStatus: [PaneID: SessionStatus] = [:]
    /// Plan limits from the latest status line that reported them.
    private(set) var usageLimits: UsageLimits?

    private let store = ProjectStore(fileURL: ProjectStore.defaultFileURL())
    let registry = SessionRegistry()
    let broker = PermissionBroker()
    private var hookServer: HookServer?
    private var hookSettingsPath: String?
    /// Per-launch secret handed to every pty and echoed back by hooks.
    let launchToken = UUID().uuidString

    init() {
        companion.model = self
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePolling()
                    if name == NSApplication.didBecomeActiveNotification { self?.refreshProjectIconsIfStale() }
                }
            }
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
        updateChangesFocus()
        companion.setNeedsSnapshot()
    }

    func addProject(at url: URL) async {
        do {
            let p = try await store.addProject(name: url.lastPathComponent, path: url.path)
            await reload()
            selectedProjectId = p.id
            await openClaudePane(project: p)
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

    struct StartError: Error, CustomStringConvertible {
        var description: String
    }

    /// A new Claude tab, on a new worktree branch when `branch` is set,
    /// starting on `prompt` when given. `select` is false for phone requests,
    /// so the Mac's view doesn't jump.
    @discardableResult
    func startSession(projectId: ProjectID, branch: String?, prompt: String?,
                      permissionMode: String? = nil, select: Bool) async throws -> PaneID {
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
        let d = PaneDescriptor(projectId: project.id,
                               kind: .claude(worktreeId: worktree.id, resumeSessionId: nil),
                               title: branchName.isEmpty ? "Claude" : branchName)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initialPrompts[d.id] = prompt
        }
        if let permissionMode { initialModes[d.id] = permissionMode }
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
        paneOrder.compactMap { panes[$0] }.filter {
            if case .claude(let wt, _) = $0.descriptor.kind { return wt == id }
            return false
        }
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
    func runQuickAction(_ action: QuickAction) async {
        guard let project = projects.first(where: { $0.id == action.projectId }) else { return }
        let cwd = (selectedProjectId == project.id ? selectedWorktreePath : nil) ?? project.path
        let kind = PaneKind.command(cwd: cwd, command: action.command)
        closeOverlays()
        selectedProjectId = project.id
        if let running = panes(for: project.id).first(where: { $0.descriptor.kind == kind && !$0.hasExited }) {
            selectedPaneId = running.id
            return
        }
        // Not persisted: a relaunch shouldn't start dev servers on its own.
        await open(PaneDescriptor(projectId: project.id, kind: kind, title: action.label), persist: false)
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
        if let pane = panes[id], case .claude = pane.descriptor.kind,
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
        selectedPaneId = visible[next].id
    }

    /// ⌘1…⌘9, in sidebar order.
    func selectProject(number: Int) {
        guard projects.indices.contains(number - 1) else { return }
        selectedProjectId = projects[number - 1].id
    }

    func newClaudeTabInSelectedProject() {
        guard let project = projects.first(where: { $0.id == selectedProjectId }) else { return }
        Task { await openClaudePane(project: project) }
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
        if flushQueue(paneId) { return .sent }
        syncQueuedCount(paneId)
        return .queued
    }

    private func canSendNow(_ paneId: PaneID) -> Bool {
        // Without hooks there is no state to wait for.
        guard hookServer != nil else { return true }
        guard let state = paneStates[paneId] else { return false } // still starting up
        return PromptGate.canSend(state: state, attention: paneAttention[paneId],
                                  command: promptQueue.nextIsCommand(for: paneId))
    }

    @discardableResult
    private func flushQueue(_ paneId: PaneID) -> Bool {
        guard canSendNow(paneId), let text = promptQueue.drain(for: paneId) else {
            syncQueuedCount(paneId)
            return false
        }
        guard panes[paneId]?.send(prompt: text) == true else {
            // The terminal is not ready yet: keep the message and try again.
            promptQueue.putBack(text, for: paneId)
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

    /// Switches a tab's model the way the user would, with `/model <name>`,
    /// queued like any message so it never lands mid-turn.
    @discardableResult
    func setModel(_ model: String, forPane paneId: PaneID) -> SendOutcome {
        guard let text = ModelCommand.text(for: model) else { return .failed }
        return sendOrQueue(text, toPane: paneId)
    }

    private func scheduleFlushRetry(_ paneId: PaneID, attempt: Int = 1) {
        guard attempt <= 5 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.promptQueue.count(for: paneId) > 0 else { return }
            if !self.flushQueue(paneId) { self.scheduleFlushRetry(paneId, attempt: attempt + 1) }
        }
    }

    private func syncQueuedCount(_ paneId: PaneID) {
        let count = promptQueue.count(for: paneId)
        queuedCounts[paneId] = count > 0 ? count : nil
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

    func closeFile() {
        openFileTarget = nil
    }

    /// Back to the terminal: closes a diff or file shown over it.
    func closeOverlays() {
        openDiffTarget = nil
        openFileTarget = nil
    }

    func addReviewComment(_ comment: ReviewComment, project: ProjectID) {
        reviewComments[project, default: []].append(comment)
    }

    func removeReviewComment(_ id: UUID, project: ProjectID) {
        reviewComments[project]?.removeAll { $0.id == id }
        if reviewComments[project]?.isEmpty == true { reviewComments[project] = nil }
    }

    enum ReviewSendResult { case sent, queued, noSession }

    /// Sends the collected comments, plus an optional last one, to the
    /// project's Claude tab as a single message, then returns to the terminal.
    func sendReview(project: ProjectID, extra: ReviewComment?) -> ReviewSendResult {
        var comments = reviewComments[project] ?? []
        if let extra { comments.append(extra) }
        let message = ReviewMessage.compose(comments)
        guard !message.isEmpty, let paneId = claudePaneId(forProject: project) else { return .noSession }
        let outcome = sendOrQueue(message, toPane: paneId)
        guard outcome != .failed else { return .noSession }
        reviewComments[project] = nil
        closeOverlays()
        selectedPaneId = paneId
        return outcome == .sent ? .sent : .queued
    }

    private func claudePaneId(forProject project: ProjectID) -> PaneID? {
        func isClaude(_ pane: TerminalPane) -> Bool {
            if case .claude = pane.descriptor.kind { return true }
            return false
        }
        if let selected = selectedPaneId, let pane = panes[selected],
           pane.descriptor.projectId == project, isClaude(pane) {
            return selected
        }
        return panes(for: project).first(where: isClaude)?.id
    }

    // MARK: Permissions

    func resolvePermission(_ id: UUID, _ decision: PermissionDecision) {
        pendingPermissions.removeAll { $0.id == id }
        companion.setNeedsSnapshot()
        Task { await self.broker.resolve(id, decision) }
    }

    // MARK: Hook events

    private func handle(_ event: HookEvent) {
        switch event {
        case .session(let session):
            guard let paneId = session.paneId, panes[paneId] != nil else { return }
            let previous = paneStates[paneId]
            paneStates[paneId] = session.state
            paneAttention[paneId] = session.attention
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
            mirror.track(sessionId: session.id, path: session.transcriptPath)
            recomputeProjectStates()
            notifyPhones(paneId: paneId, previous: previous, state: session.state, attention: session.attention)
            updateInterruptWatcher(for: session)
            if session.state == .needsInput, previous != .needsInput { requestAttention() }
            flushQueue(paneId)
            if previous == .working, session.state != .working, let worktree = paneWorktreePaths[paneId] {
                // The turn ended: files may have changed, and the base branch may have moved.
                changes.refresh(worktree)
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
            guard panes[paneId] != nil else { return }
            var changed = false
            if paneStatus[paneId] != report.status {
                paneStatus[paneId] = report.status
                changed = true
            }
            if let limits = report.limits, limits != usageLimits {
                usageLimits = limits
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
        stopInterruptWatcher(forPane: id)
        _ = await broker.cancelAll(paneId: id)
        pendingPermissions.removeAll { $0.paneId == id }
        if let session = await registry.paneExited(id) {
            let previous = paneStates[id]
            paneStates[id] = session.state
            recomputeProjectStates()
            notifyPhones(paneId: id, previous: previous, state: session.state, attention: nil)
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
        await startHookServer()
        companion.start()
        await reload()
        var descriptors = await store.state.panes
        for project in projects where !descriptors.contains(where: { $0.projectId == project.id }) {
            if let wt = await store.primaryWorktree(for: project.id) {
                let d = PaneDescriptor(projectId: project.id,
                                       kind: .claude(worktreeId: wt.id, resumeSessionId: nil),
                                       title: "Claude")
                try? await store.addPane(d)
                descriptors.append(d)
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
        await mount(d)
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
        case .ssh(let hostId): host = await store.remoteHost(hostId)
        case .shell, .command: break
        }
        let launch = TerminalLaunch.make(pane: d, worktree: worktree, remoteHost: host,
                                         token: launchToken, hookSettingsPath: hookSettingsPath,
                                         newSessionId: launchSession,
                                         initialPrompt: initialPrompts.removeValue(forKey: d.id),
                                         permissionMode: initialModes.removeValue(forKey: d.id))
        let pane = TerminalPane(descriptor: d, launch: launch, controller: TerminalHost.controller)
        pane.onExit = { [weak self] id in
            guard let self else { return }
            Task { await self.paneDidExit(id) }
        }
        panes[d.id] = pane
        paneOrder.append(d.id)
        if let launchSession {
            // Not persisted for --resume until a hook confirms the session
            // exists: resuming an id with no transcript would fail.
            launchSessions[d.id] = launchSession
            mirror.track(sessionId: launchSession, path: nil)
        }
        companion.setNeedsSnapshot()
    }

    private func tearDown(_ id: PaneID) {
        stopInterruptWatcher(forPane: id)
        stopMirror(forPane: id)
        panes[id] = nil
        paneOrder.removeAll { $0 == id }
        paneStates[id] = nil
        paneAttention[id] = nil
        paneModes[id] = nil
        paneStatus[id] = nil
        paneWorktreePaths[id] = nil
        promptQueue.clear(pane: id)
        queuedCounts[id] = nil
        recordedSessions[id] = nil
        launchSessions[id] = nil
        pendingPermissions.removeAll { $0.paneId == id }
        Task { _ = await self.broker.cancelAll(paneId: id) }
        if selectedPaneId == id { selectFirstPaneIfNeeded(force: true) }
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
    case changes, files
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
        let projectList = projects.map {
            ProjectSummary(id: $0.id, name: $0.name, branch: branchLabel(for: $0))
        }
        var sessions: [SessionSummary] = []
        for project in projects {
            for pane in panes(for: project.id) {
                guard case .claude = pane.descriptor.kind else { continue }
                sessions.append(SessionSummary(
                    id: pane.id, projectId: project.id, sessionId: sessionId(forPane: pane.id),
                    title: pane.title, state: paneStates[pane.id] ?? .idle,
                    attention: paneAttention[pane.id], queued: queuedCounts[pane.id] ?? 0,
                    preview: mirror.model(for: sessionId(forPane: pane.id))?.preview(),
                    permissionMode: paneModes[pane.id], status: paneStatus[pane.id]))
            }
        }
        let permissions = pendingPermissions.map(phoneSummary(of:))
        return Snapshot(macName: macName, projects: projectList, sessions: sessions, permissions: permissions,
                        limits: usageLimits)
    }
}

// MARK: - Push

extension AppModel {
    func phoneSummary(of request: PendingPermission) -> PermissionRequested {
        let summary = PermissionSummary.describe(toolName: request.toolName, input: request.toolInput)
        return PermissionRequested(id: request.id, paneId: request.paneId, sessionId: request.sessionId,
                                   toolName: request.toolName, title: summary.title, detail: summary.detail)
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
                                 preview: transcript?.preview(), steps: transcript?.stepsInCurrentTurn ?? 0)
    }

    fileprivate func activityContentChanged(sessionId: SessionID) {
        guard let paneId = paneOrder.first(where: { self.sessionId(forPane: $0) == sessionId }),
              let state = paneStates[paneId], state == .working || state == .needsInput,
              let transcript = mirror.model(for: sessionId) else { return }
        companion.activityContentChanged(paneId: paneId, state: state, preview: transcript.preview(),
                                         steps: transcript.stepsInCurrentTurn)
    }
}
