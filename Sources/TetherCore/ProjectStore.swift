import Foundation
import TetherProtocol

/// Persisted layout: projects and worktrees. Written atomically as JSON.
public struct ProjectStoreState: Codable, Sendable, Equatable {
    public var projects: [Project] = []
    public var worktrees: [Worktree] = []
    public init(projects: [Project] = [], worktrees: [Worktree] = []) {
        self.projects = projects
        self.worktrees = worktrees
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

    public func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try WireCodec.encoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
