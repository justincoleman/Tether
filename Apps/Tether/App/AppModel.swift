import Foundation
import Observation
import TetherCore
import TetherProtocol

/// Main-actor façade over the TetherCore actors. Views bind to this; it owns
/// the live terminal panes and forwards persistence to `ProjectStore`.
@MainActor
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
    private(set) var remoteHosts: [RemoteHost] = []
    private(set) var sessionStates: [ProjectID: SessionState] = [:]
    var selectedProjectId: ProjectID? {
        didSet { selectFirstPaneIfNeeded() }
    }
    var selectedPaneId: PaneID?
    var addProjectRequested = false

    /// Live panes keyed by id. Descriptors persist in the store; this does not.
    private var panes: [PaneID: TerminalPane] = [:]
    private var paneOrder: [PaneID] = []

    private let store = ProjectStore(fileURL: ProjectStore.defaultFileURL())
    let registry = SessionRegistry()
    /// Per-launch secret handed to every pty; the hook server (phase 2) checks it.
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

    /// Restores persisted panes, staggered so a dozen projects don't spawn
    /// a dozen `claude` processes in the same instant. Projects without any
    /// pane get a Claude session, which is the "ready to go" promise.
    private func restore() async {
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
        switch d.kind {
        case .claude(let wtId, _): worktree = await store.worktree(wtId)
        case .ssh(let hostId): host = await store.remoteHost(hostId)
        case .shell: break
        }
        let launch = TerminalLaunch.make(pane: d, worktree: worktree, remoteHost: host, token: launchToken)
        let pane = TerminalPane(descriptor: d, launch: launch, controller: TerminalHost.controller)
        pane.onExit = { [weak self] id in
            // Keep the tab so the exit message is readable; the user closes it.
            _ = self; _ = id
        }
        panes[d.id] = pane
        paneOrder.append(d.id)
    }

    private func tearDown(_ id: PaneID) {
        panes[id] = nil
        paneOrder.removeAll { $0 == id }
        if selectedPaneId == id { selectFirstPaneIfNeeded(force: true) }
    }

    private func selectFirstPaneIfNeeded(force: Bool = false) {
        guard let pid = selectedProjectId else { selectedPaneId = nil; return }
        let visible = panes(for: pid)
        if force || !visible.contains(where: { $0.id == selectedPaneId }) {
            selectedPaneId = visible.first?.id
        }
    }
}
