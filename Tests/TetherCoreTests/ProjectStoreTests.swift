import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct ProjectStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-tests-\(UUID().uuidString)/state.json")
    }

    @Test func addPersistsAndReloads() async throws {
        let url = tempURL()
        let store = ProjectStore(fileURL: url)
        let p = try await store.addProject(name: "Bench", path: "/tmp/bench")
        let reloaded = ProjectStore(fileURL: url)
        let projects = await reloaded.orderedProjects()
        #expect(projects.map(\.id) == [p.id])
        let worktrees = await reloaded.state.worktrees
        #expect(worktrees.count == 1 && worktrees[0].isPrimary)
    }

    @Test func renameTrimsAndIgnoresBlank() async throws {
        let url = tempURL()
        let store = ProjectStore(fileURL: url)
        let p = try await store.addProject(name: "CreditBenefitsTracker", path: "/tmp/cbt")
        try await store.renameProject(p.id, to: "  Credit Buddy \n")
        try await store.renameProject(p.id, to: "   ")
        #expect(await ProjectStore(fileURL: url).orderedProjects().first?.name == "Credit Buddy")
        #expect(await store.orderedProjects().first?.path == "/tmp/cbt")
    }

    @Test func reorderAssignsOrderByPosition() async throws {
        let store = ProjectStore(fileURL: tempURL())
        let a = try await store.addProject(name: "a", path: "/a")
        let b = try await store.addProject(name: "b", path: "/b")
        try await store.reorder([b.id, a.id])
        #expect(await store.orderedProjects().map(\.name) == ["b", "a"])
    }
}

@Suite struct ProjectStorePaneTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-tests-\(UUID().uuidString)/state.json")
    }

    @Test func oldStateFileWithoutNewKeysStillLoads() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"projects\":[],\"worktrees\":[]}".utf8).write(to: url)
        let store = ProjectStore(fileURL: url)
        #expect(await store.state.remoteHosts.isEmpty)
    }

    @Test func recordSessionUpdatesClaudePane() async throws {
        let store = ProjectStore(fileURL: tempURL())
        let p = try await store.addProject(name: "p", path: "/p")
        let wt = await store.primaryWorktree(for: p.id)!
        let pane = PaneDescriptor(projectId: p.id, kind: .claude(worktreeId: wt.id, resumeSessionId: nil), title: "Claude")
        try await store.addPane(pane)
        try await store.recordSession("sess-1", forPane: pane.id)
        let kind = await store.panes(for: p.id).first?.kind
        #expect(kind == .claude(worktreeId: wt.id, resumeSessionId: "sess-1"))
    }
}
