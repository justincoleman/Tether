import Foundation
import TetherProtocol

/// Persisted layout: projects and worktrees. Written atomically as JSON.
public struct ProjectStoreState: Codable, Sendable, Equatable {
    public var projects: [Project] = []
    public var worktrees: [Worktree] = []
    public var remoteHosts: [RemoteHost] = []
    public var panes: [PaneDescriptor] = []
    public var quickActions: [QuickAction] = []
    /// Tabs shown side by side. Only splits between persisted panes are kept.
    public var splits: [PaneSplit] = []
    /// Last use, pin and Inactive state per project.
    public var activity: [ProjectID: ProjectActivity] = [:]

    public init(projects: [Project] = [], worktrees: [Worktree] = [],
                remoteHosts: [RemoteHost] = [], panes: [PaneDescriptor] = [],
                quickActions: [QuickAction] = [], splits: [PaneSplit] = []) {
        self.projects = projects
        self.worktrees = worktrees
        self.remoteHosts = remoteHosts
        self.panes = panes
        self.quickActions = quickActions
        self.splits = splits
    }

    enum CodingKeys: String, CodingKey { case projects, worktrees, remoteHosts, panes, quickActions, splits, activity }

    /// Missing keys decode as empty so older state files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        worktrees = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
        remoteHosts = try c.decodeIfPresent([RemoteHost].self, forKey: .remoteHosts) ?? []
        panes = try c.decodeIfPresent([PaneDescriptor].self, forKey: .panes) ?? []
        quickActions = try c.decodeIfPresent([QuickAction].self, forKey: .quickActions) ?? []
        splits = try c.decodeIfPresent([PaneSplit].self, forKey: .splits) ?? []
        activity = try c.decodeIfPresent([ProjectID: ProjectActivity].self, forKey: .activity) ?? [:]
    }
}

public actor ProjectStore {
    public private(set) var state: ProjectStoreState
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? WireCodec.decoder().decode(ProjectStoreState.self, from: data) {
            state = decoded
        } else {
            state = ProjectStoreState()
        }
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Tether/state.json")
    }

    public func orderedProjects() -> [Project] {
        state.projects.sorted { $0.order < $1.order }
    }

    @discardableResult
    public func addProject(name: String, path: String, baseBranch: String = "main") throws -> Project {
        let project = Project(name: name, path: path, baseBranch: baseBranch,
                              order: (state.projects.map(\.order).max() ?? -1) + 1)
        state.projects.append(project)
        state.worktrees.append(Worktree(projectId: project.id, path: path, branch: baseBranch, isPrimary: true))
        // Just added counts as used, so it lands in Active.
        state.activity[project.id] = ProjectActivity(lastUsed: Date())
        try save()
        return project
    }

    public func removeProject(_ id: ProjectID) throws {
        state.projects.removeAll { $0.id == id }
        state.worktrees.removeAll { $0.projectId == id }
        state.panes.removeAll { $0.projectId == id }
        state.quickActions.removeAll { $0.projectId == id }
        state.activity[id] = nil
        try save()
    }

    /// Display name only; the folder and git are untouched. Blank names are ignored.
    public func renameProject(_ id: ProjectID, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = state.projects.firstIndex(where: { $0.id == id }) else { return }
        state.projects[i].name = clean
        try save()
    }

    /// Records a use of a project; writes only when `ProjectActivity.touch` says it's worth it.
    public func touchProject(_ id: ProjectID, at date: Date = Date()) throws {
        guard state.projects.contains(where: { $0.id == id }) else { return }
        if state.activity[id, default: ProjectActivity()].touch(at: date) { try save() }
    }

    public func setPinned(_ id: ProjectID, _ pinned: Bool) throws {
        guard state.projects.contains(where: { $0.id == id }) else { return }
        state.activity[id, default: ProjectActivity()].pinned = pinned
        if pinned {
            // Newly pinned goes to the bottom of the pinned group.
            state.activity[id]?.movedInactiveAt = nil
            if let i = state.projects.firstIndex(where: { $0.id == id }) {
                state.projects[i].order = (state.projects.map(\.order).max() ?? -1) + 1
            }
        }
        try save()
    }

    public func setActive(_ id: ProjectID, _ active: Bool, at date: Date = Date()) throws {
        guard state.projects.contains(where: { $0.id == id }) else { return }
        if active {
            state.activity[id, default: ProjectActivity()].makeActive(at: date)
        } else {
            state.activity[id, default: ProjectActivity()].moveToInactive(at: date)
        }
        try save()
    }

    public func reorder(_ ids: [ProjectID]) throws {
        var index: [ProjectID: Int] = [:]
        for (i, id) in ids.enumerated() { index[id] = i }
        for i in state.projects.indices {
            if let o = index[state.projects[i].id] { state.projects[i].order = o }
        }
        try save()
    }

    public func primaryWorktree(for projectId: ProjectID) -> Worktree? {
        state.worktrees.first { $0.projectId == projectId && $0.isPrimary }
    }

    public func worktree(_ id: WorktreeID) -> Worktree? {
        state.worktrees.first { $0.id == id }
    }

    public func removeWorktree(_ id: WorktreeID) throws {
        state.worktrees.removeAll { $0.id == id && !$0.isPrimary }
        state.panes.removeAll { if case .claude(let wt, _) = $0.kind { return wt == id } else { return false } }
        try save()
    }

    @discardableResult
    public func addWorktree(projectId: ProjectID, path: String, branch: String) throws -> Worktree {
        let worktree = Worktree(projectId: projectId, path: path, branch: branch, isPrimary: false)
        state.worktrees.append(worktree)
        try save()
        return worktree
    }

    public func remoteHost(_ id: RemoteHostID) -> RemoteHost? {
        state.remoteHosts.first { $0.id == id }
    }

    // MARK: Remote hosts

    public func upsertRemoteHost(_ host: RemoteHost) throws {
        if let i = state.remoteHosts.firstIndex(where: { $0.id == host.id }) {
            state.remoteHosts[i] = host
        } else {
            state.remoteHosts.append(host)
        }
        try save()
    }

    public func removeRemoteHost(_ id: RemoteHostID) throws {
        state.remoteHosts.removeAll { $0.id == id }
        state.panes.removeAll { if case .ssh(let h) = $0.kind { return h == id } else { return false } }
        try save()
    }

    // MARK: Quick actions

    public func quickActions(for projectId: ProjectID) -> [QuickAction] {
        state.quickActions.filter { $0.projectId == projectId }
    }

    /// Replaces the project's shortcuts, in order. Ones with no command are dropped.
    public func setQuickActions(_ actions: [QuickAction], for projectId: ProjectID) throws {
        let kept = actions
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { action -> QuickAction in
                var copy = action
                copy.projectId = projectId
                copy.name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
                return copy
            }
        state.quickActions.removeAll { $0.projectId == projectId }
        state.quickActions += kept
        try save()
    }

    // MARK: Panes

    public func panes(for projectId: ProjectID) -> [PaneDescriptor] {
        state.panes.filter { $0.projectId == projectId }
    }

    public func addPane(_ pane: PaneDescriptor) throws {
        state.panes.append(pane)
        try save()
    }

    public func removePane(_ id: PaneID) throws {
        state.panes.removeAll { $0.id == id }
        try save()
    }

    /// Puts the project's tabs in `order` (see `PaneLayout.reordering`).
    public func reorderPanes(_ order: [PaneID], in projectId: ProjectID) throws {
        state.panes = PaneLayout.reordering(state.panes, id: \.id,
                                            inProject: { $0.projectId == projectId }, to: order)
        try save()
    }

    /// Replaces every split. Ones naming a pane that isn't persisted are dropped.
    public func setSplits(_ splits: [PaneSplit]) throws {
        state.splits = splits
        try save()
    }

    /// Remember the Claude session running in a pane so the next launch resumes it.
    public func recordSession(_ sessionId: SessionID, forPane paneId: PaneID) throws {
        guard let i = state.panes.firstIndex(where: { $0.id == paneId }),
              case .claude(let wt, _) = state.panes[i].kind else { return }
        state.panes[i].kind = .claude(worktreeId: wt, resumeSessionId: sessionId)
        try save()
    }

    public func save() throws {
        // Removing a pane, worktree, host or project can orphan a split.
        state.splits = PaneLayout.pruning(state.splits, existing: Set(state.panes.map(\.id)))
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try WireCodec.encoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
