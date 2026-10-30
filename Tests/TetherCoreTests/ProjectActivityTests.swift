import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct ProjectActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    @Test func goesInactiveAfterTheSetNumberOfDays() {
        let recent = ProjectActivity(lastUsed: days(2.9))
        let stale = ProjectActivity(lastUsed: days(3.1))
        #expect(recent.isActive(now: now, inactiveAfterDays: 3))
        #expect(!stale.isActive(now: now, inactiveAfterDays: 3))
        #expect(stale.isActive(now: now, inactiveAfterDays: 7))
        #expect(!ProjectActivity().isActive(now: now, inactiveAfterDays: 3))
    }

    @Test func pinnedStaysActiveUntilMovedToInactive() {
        var a = ProjectActivity(lastUsed: days(30), pinned: true)
        #expect(a.isActive(now: now, inactiveAfterDays: 3))
        a.moveToInactive(at: days(1))
        #expect(!a.pinned)
        #expect(!a.isActive(now: now, inactiveAfterDays: 3))
    }

    @Test func useAfterMovingToInactiveBringsItBack() {
        var a = ProjectActivity(lastUsed: days(0.5))
        a.moveToInactive(at: days(0.2))
        #expect(!a.isActive(now: now, inactiveAfterDays: 3))
        // A transcript older than the move doesn't count.
        a.touch(at: days(0.3))
        #expect(!a.isActive(now: now, inactiveAfterDays: 3))
        let saved = a.touch(at: days(0.1))
        #expect(saved)
        #expect(a.isActive(now: now, inactiveAfterDays: 3))
    }

    @Test func makeActiveCountsAsUse() {
        var a = ProjectActivity(lastUsed: days(10))
        a.moveToInactive(at: days(5))
        a.makeActive(at: now)
        #expect(a.lastUsed == now)
        #expect(a.isActive(now: now, inactiveAfterDays: 3))
    }

    @Test func touchAsksToSaveOnlyWhenItMatters() {
        var a = ProjectActivity()
        let first = a.touch(at: now)
        let soonAfter = a.touch(at: now.addingTimeInterval(10))
        #expect(first && !soonAfter)
        #expect(a.lastUsed == now.addingTimeInterval(10))
        let older = a.touch(at: now)
        let later = a.touch(at: now.addingTimeInterval(120))
        #expect(!older && later)
    }

    @Test func decodesWithMissingKeys() throws {
        let a = try JSONDecoder().decode(ProjectActivity.self, from: Data("{}".utf8))
        #expect(a == ProjectActivity())
    }

    @Test func sectionsSortPinnedByOrderAndTheRestByRecency() {
        let p = (0..<5).map { Project(name: "P\($0)", path: "/p\($0)", order: $0) }
        let activity: [ProjectID: ProjectActivity] = [
            p[0].id: ProjectActivity(lastUsed: days(1)),
            p[1].id: ProjectActivity(lastUsed: days(0.1)),
            p[2].id: ProjectActivity(lastUsed: days(20), pinned: true),
            p[3].id: ProjectActivity(lastUsed: days(9)),
            p[4].id: ProjectActivity(lastUsed: days(0.5), pinned: true),
        ]
        let s = ProjectSections(projects: p, activity: activity, now: now, inactiveAfterDays: 3)
        #expect(s.pinned.map(\.name) == ["P2", "P4"])
        #expect(s.active.map(\.name) == ["P1", "P0"])
        #expect(s.inactive.map(\.name) == ["P3"])
        #expect(s.all.count == 5)
    }

    @Test func storeKeepsActivityAndForgetsRemovedProjects() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-tests-\(UUID().uuidString)/state.json")
        let store = ProjectStore(fileURL: url)
        let a = try await store.addProject(name: "A", path: "/tmp/a")
        let b = try await store.addProject(name: "B", path: "/tmp/b")
        #expect(await store.state.activity[a.id]?.lastUsed != nil)
        try await store.setPinned(b.id, true)
        try await store.setActive(a.id, false)
        let reloaded = await ProjectStore(fileURL: url).state.activity
        #expect(reloaded[b.id]?.pinned == true)
        #expect(reloaded[a.id]?.movedInactiveAt != nil)
        try await store.removeProject(a.id)
        #expect(await store.state.activity[a.id] == nil)
    }

    @Test func latestActivityReadsTranscriptTimes() throws {
        let fm = FileManager.default
        let projects = fm.temporaryDirectory.appendingPathComponent("tether-activity-\(UUID().uuidString)")
        let dir = projects.appendingPathComponent("-Users-j-Duet")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.jsonl")
        try Data("{}\n".utf8).write(to: url)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        #expect(SessionHistory.latestActivity(folders: ["/Users/j/Duet"], projectsDirectory: projects) == when)
        #expect(SessionHistory.latestActivity(folders: ["/Users/j/Other"], projectsDirectory: projects) == nil)
    }
}
