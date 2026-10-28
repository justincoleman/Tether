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
    /// Most urgent state across a project's panes, for the sidebar.
    private(set) var sessionStates: [ProjectID: SessionState] = [:]
    /// Per-pane state, for tab badges.
    private(set) var paneStates: [PaneID: SessionState] = [:]
    /// Permission requests waiting on an answer, oldest first.
    private(set) var pendingPermissions: [PendingPermission] = []
    /// Non-nil when hooks could not be set up; shown in the sidebar footer.
    private(set) var hookStatusMessage: String?

    var selectedProjectId: ProjectID? {
        didSet { selectFirstPaneIfNeeded() }
    }
    var selectedPaneId: PaneID? {
        didSet {
            guard let id = selectedPaneId, id != oldValue else { return }
            Task { await self.paneFocused(id) }
        }
    }
    var addProjectRequested = false
    /// Right-hand chat mirror panel.
    var showMirror = false

    let mirror = MirrorStore()

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

    private let store = ProjectStore(fileURL: ProjectStore.defaultFileURL())
    let registry = SessionRegistry()
    let broker = PermissionBroker()
    private var hookServer: HookServer?
    private var hookSettingsPath: String?
    /// Per-launch secret handed to every pty and echoed back by hooks.
    let launchToken = UUID().uuidString

    init() {
        Task { await restore() }
    }

    // MARK: Projects

    func reload() async {
        projects = await store.orderedProjects()
        remoteHosts = await store.state.remoteHosts
        if selectedProjectId == nil { selectedProjectId = projects.first?.id }
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

    func openShellPane(project: Project) async {
        let d = PaneDescriptor(projectId: project.id, kind: .shell(cwd: project.path), title: "Shell")
        await open(d)
    }

    func openSSHPane(project: Project, host: RemoteHost) async {
        let d = PaneDescriptor(projectId: project.id, kind: .ssh(hostId: host.id), title: host.name)
        await open(d)
    }

    func closePane(_ id: PaneID) async {
        tearDown(id)
        try? await store.removePane(id)
    }

    // MARK: Mirror

    func sessionId(forPane paneId: PaneID) -> SessionID? {
        recordedSessions[paneId] ?? launchSessions[paneId]
    }

    /// Types a prompt into a Claude tab and submits it. Returns false if the
    /// tab is gone or its terminal is not ready.
    @discardableResult
    func sendPrompt(_ text: String, toPane paneId: PaneID) -> Bool {
        panes[paneId]?.send(prompt: text) ?? false
    }

    // MARK: Permissions

    func resolvePermission(_ id: UUID, _ decision: PermissionDecision) {
        pendingPermissions.removeAll { $0.id == id }
        Task { await self.broker.resolve(id, decision) }
    }

    // MARK: Hook events

    private func handle(_ event: HookEvent) {
        switch event {
        case .session(let session):
            guard let paneId = session.paneId, panes[paneId] != nil else { return }
            let previous = paneStates[paneId]
            paneStates[paneId] = session.state
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
            updateInterruptWatcher(for: session)
            if session.state == .needsInput, previous != .needsInput { requestAttention() }
        case .permissionRequested(let request):
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
            }
            requestAttention()
        case .permissionResolved(let id, _):
            pendingPermissions.removeAll { $0.id == id }
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
            paneStates[id] = session.state
            recomputeProjectStates()
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
            try HookSettings.write(port: port, to: url)
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

    private func open(_ d: PaneDescriptor) async {
        try? await store.addPane(d)
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
            if let resume, !resume.isEmpty {
                launchSession = resume
            } else {
                launchSession = UUID().uuidString.lowercased()
            }
        case .ssh(let hostId): host = await store.remoteHost(hostId)
        case .shell: break
        }
        let launch = TerminalLaunch.make(pane: d, worktree: worktree, remoteHost: host,
                                         token: launchToken, hookSettingsPath: hookSettingsPath,
                                         newSessionId: launchSession)
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
    }

    private func tearDown(_ id: PaneID) {
        stopInterruptWatcher(forPane: id)
        stopMirror(forPane: id)
        panes[id] = nil
        paneOrder.removeAll { $0 == id }
        paneStates[id] = nil
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

private extension SessionState {
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
