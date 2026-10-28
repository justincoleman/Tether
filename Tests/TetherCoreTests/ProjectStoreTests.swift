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

    @Test func reorderAssignsOrderByPosition() async throws {
        let store = ProjectStore(fileURL: tempURL())
        let a = try await store.addProject(name: "a", path: "/a")
        let b = try await store.addProject(name: "b", path: "/b")
        try await store.reorder([b.id, a.id])
        #expect(await store.orderedProjects().map(\.name) == ["b", "a"])
    }
}
