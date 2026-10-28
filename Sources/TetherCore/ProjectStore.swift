import Foundation
import TetherProtocol

/// Persisted layout: projects and worktrees. Written atomically as JSON.
public struct ProjectStoreState: Codable, Sendable, Equatable {
    public var projects: [Project] = []
    public var worktrees: [Worktree] = []
    public var remoteHosts: [RemoteHost] = []
    public var panes: [PaneDescriptor] = []

    public init(projects: [Project] = [], worktrees: [Worktree] = [],
                remoteHosts: [RemoteHost] = [], panes: [PaneDescriptor] = []) {
        self.projects = projects
        self.worktrees = worktrees
        self.remoteHosts = remoteHosts
        self.panes = panes
    }

    enum CodingKeys: String, CodingKey { case projects, worktrees, remoteHosts, panes }

    /// Missing keys decode as empty so older state files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        worktrees = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
        remoteHosts = try c.decodeIfPresent([RemoteHost].self, forKey: .remoteHosts) ?? []
        panes = try c.decodeIfPresent([PaneDescriptor].self, forKey: .panes) ?? []
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
        try save()
        return project
    }

    public func removeProject(_ id: ProjectID) throws {
        state.projects.removeAll { $0.id == id }
        state.worktrees.removeAll { $0.projectId == id }
        state.panes.removeAll { $0.projectId == id }
        try save()
    }

    /// Display name only; the folder and git are untouched. Blank names are ignored.
    public func renameProject(_ id: ProjectID, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = state.projects.firstIndex(where: { $0.id == id }) else { return }
        state.projects[i].name = clean
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

    /// Remember the Claude session running in a pane so the next launch resumes it.
    public func recordSession(_ sessionId: SessionID, forPane paneId: PaneID) throws {
        guard let i = state.panes.firstIndex(where: { $0.id == paneId }),
              case .claude(let wt, _) = state.panes[i].kind else { return }
        state.panes[i].kind = .claude(worktreeId: wt, resumeSessionId: sessionId)
        try save()
    }

    public func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try WireCodec.encoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
