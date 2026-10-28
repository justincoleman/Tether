import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct PaneLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func dragRightLandsAfterTargetAndLeftBefore() {
        let ids = [a, b, c, d]
        #expect(PaneLayout.moving(a, onto: c, in: ids) == [b, c, a, d])
        #expect(PaneLayout.moving(d, onto: b, in: ids) == [a, d, b, c])
        #expect(PaneLayout.moving(b, onto: b, in: ids) == ids)
        #expect(PaneLayout.moving(UUID(), onto: b, in: ids) == ids)
    }

    @Test func placingPutsPaneRightAfterAnchor() {
        #expect(PaneLayout.placing(d, after: a, in: [a, b, c, d]) == [a, d, b, c])
        #expect(PaneLayout.placing(a, after: d, in: [a, b, c, d]) == [b, c, d, a])
        #expect(PaneLayout.placing(a, after: a, in: [a, b]) == [a, b])
    }

    @Test func reorderingKeepsOtherProjectsInTheirSlots() {
        // x1 and x2 belong to another project; a, b, c are interleaved with them.
        let x1 = UUID(), x2 = UUID()
        let all = [a, x1, b, x2, c]
        let mine: Set<UUID> = [a, b, c]
        let result = PaneLayout.reordering(all, id: { $0 }, inProject: { mine.contains($0) }, to: [c, a, b])
        #expect(result == [c, x1, a, x2, b])
    }

    @Test func reorderingKeepsUnlistedPanesAfterListedOnes() {
        let result = PaneLayout.reordering([a, b, c], id: { $0 }, inProject: { _ in true }, to: [c, UUID()])
        #expect(result == [c, a, b])
    }

    @Test func addingASplitReplacesOnesSharingAPane() {
        let p = UUID()
        let ab = PaneSplit(projectId: p, first: a, second: b)
        let cd = PaneSplit(projectId: p, first: c, second: d)
        let bc = PaneSplit(projectId: p, first: b, second: c, axis: .vertical)
        let splits = PaneLayout.adding(bc, to: [ab, cd])
        #expect(splits == [bc])
        #expect(PaneLayout.adding(PaneSplit(projectId: p, first: a, second: a), to: [ab]) == [ab])
        #expect(PaneLayout.split(containing: c, in: splits)?.partner(of: c) == b)
        #expect(PaneLayout.split(containing: a, in: splits) == nil)
    }

    @Test func fractionIsClamped() {
        let p = UUID()
        #expect(PaneSplit(projectId: p, first: a, second: b, fraction: 0.95).fraction == 0.8)
        #expect(PaneSplit(projectId: p, first: a, second: b, fraction: .nan).fraction == 0.5)
        #expect(PaneSplit.clamp(0.1) == 0.2)
    }
}

@Suite struct ProjectStoreLayoutTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-tests-\(UUID().uuidString)/state.json")
    }

    @Test func reorderPanesPersistsWithinTheProject() async throws {
        let url = tempURL()
        let store = ProjectStore(fileURL: url)
        let p = try await store.addProject(name: "p", path: "/p")
        let q = try await store.addProject(name: "q", path: "/q")
        let one = PaneDescriptor(projectId: p.id, kind: .shell(cwd: "/p"), title: "1")
        let other = PaneDescriptor(projectId: q.id, kind: .shell(cwd: "/q"), title: "x")
        let two = PaneDescriptor(projectId: p.id, kind: .shell(cwd: "/p"), title: "2")
        for pane in [one, other, two] { try await store.addPane(pane) }
        try await store.reorderPanes([two.id, one.id], in: p.id)
        let reloaded = ProjectStore(fileURL: url)
        #expect(await reloaded.state.panes.map(\.title) == ["2", "x", "1"])
    }

    @Test func splitsPersistAndDropWhenAPaneCloses() async throws {
        let url = tempURL()
        let store = ProjectStore(fileURL: url)
        let p = try await store.addProject(name: "p", path: "/p")
        let one = PaneDescriptor(projectId: p.id, kind: .shell(cwd: "/p"), title: "1")
        let two = PaneDescriptor(projectId: p.id, kind: .shell(cwd: "/p"), title: "2")
        try await store.addPane(one)
        try await store.addPane(two)
        let split = PaneSplit(projectId: p.id, first: one.id, second: two.id, axis: .vertical, fraction: 0.3)
        // A split with a pane the store never saw (an unpersisted shortcut tab) is dropped.
        try await store.setSplits([split, PaneSplit(projectId: p.id, first: one.id, second: UUID())])
        #expect(await ProjectStore(fileURL: url).state.splits == [split])
        try await store.removePane(two.id)
        #expect(await ProjectStore(fileURL: url).state.splits.isEmpty)
    }

    @Test func stateWithoutSplitsKeyLoads() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"projects\":[],\"panes\":[]}".utf8).write(to: url)
        #expect(await ProjectStore(fileURL: url).state.splits.isEmpty)
    }
}
