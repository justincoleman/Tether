import Foundation
import Testing
import TetherProtocol
@testable import TetherCore

@Suite struct AgentAwarenessTests {
    let launch = Date(timeIntervalSince1970: 100)

    @Test func missingReportWaitsForStartupAndOnlyAppliesToLiveCodex() {
        func missing(_ agent: AgentKind = .codex, after: TimeInterval, exited: Bool = false) -> Bool {
            CodexReportingHealth.isMissing(agent: agent, launchedAt: launch, lastReportAt: nil,
                                           hasExited: exited, now: launch.addingTimeInterval(after))
        }
        #expect(!missing(after: 14.9))
        #expect(missing(after: 15))
        #expect(!missing(after: -1))
        #expect(!missing(.claude, after: 60))
        #expect(!missing(after: 60, exited: true))
    }

    @Test func aReportInThisRunStaysHealthyWhileIdle() {
        #expect(!CodexReportingHealth.isMissing(agent: .codex, launchedAt: launch,
                                               lastReportAt: launch.addingTimeInterval(1), hasExited: false,
                                               now: launch.addingTimeInterval(3_600)))
        #expect(CodexReportingHealth.isMissing(agent: .codex, launchedAt: launch,
                                              lastReportAt: launch.addingTimeInterval(-1), hasExited: false,
                                              now: launch.addingTimeInterval(60)))
    }

    @Test func conflictsOnlyWithOtherLiveAgentsInTheSameFolder() {
        let codex = AgentFolderOccupant(id: UUID(), agent: .codex, path: "/repo", isLive: true)
        let claude = AgentFolderOccupant(id: UUID(), agent: .claude, path: "/repo/./", isLive: true)
        let sameAgent = AgentFolderOccupant(id: UUID(), agent: .codex, path: "/repo", isLive: true)
        let worktree = AgentFolderOccupant(id: UUID(), agent: .claude, path: "/repo-feature", isLive: true)
        let nested = AgentFolderOccupant(id: UUID(), agent: .claude, path: "/repo/subfolder", isLive: true)
        let ended = AgentFolderOccupant(id: UUID(), agent: .claude, path: "/repo", isLive: false)
        let folders = SameFolderAgents([codex, claude, sameAgent, worktree, nested, ended])
        #expect(folders.conflicts(for: codex.id).map(\.id) == [claude.id])
        #expect(folders.conflicts(for: claude.id).map(\.id) == [codex.id, sameAgent.id])
        #expect(folders.conflicts(for: ended.id).isEmpty)
        #expect(folders.conflicts(for: UUID()).isEmpty)
    }

    @Test func symlinkedFoldersConflictWithTheirDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-folders-\(UUID())")
        let target = root.appendingPathComponent("repo")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let codex = AgentFolderOccupant(id: UUID(), agent: .codex, path: alias.path, isLive: true)
        let claude = AgentFolderOccupant(id: UUID(), agent: .claude, path: target.path, isLive: true)
        #expect(SameFolderAgents([codex, claude]).conflicts(for: codex.id).map(\.id) == [claude.id])
    }

    @Test func unknownFoldersDoNotCollide() {
        let codex = AgentFolderOccupant(id: UUID(), agent: .codex, path: "", isLive: true)
        let claude = AgentFolderOccupant(id: UUID(), agent: .claude, path: "", isLive: true)
        #expect(SameFolderAgents([codex, claude]).conflicts(for: codex.id).isEmpty)
    }
}
