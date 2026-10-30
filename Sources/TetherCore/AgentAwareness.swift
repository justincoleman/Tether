import Foundation
import TetherProtocol

/// Hook health is a startup check, not an inactivity timeout: an idle agent
/// can legitimately go hours without reporting another event.
public enum CodexReportingHealth {
    public static func isMissing(agent: AgentKind, launchedAt: Date, lastReportAt: Date?,
                                 hasExited: Bool, now: Date, grace: TimeInterval = 15) -> Bool {
        guard agent == .codex, !hasExited,
              now.timeIntervalSince(launchedAt) >= max(0, grace) else { return false }
        return lastReportAt.map { $0 < launchedAt } ?? true
    }
}

/// A live coding tab's actual working folder. Shell and SSH tabs are excluded
/// by the caller because they have no `AgentKind`.
public struct AgentFolderOccupant: Equatable, Sendable, Identifiable {
    public var id: PaneID
    public var agent: AgentKind
    public var path: String
    public var isLive: Bool

    public init(id: PaneID, agent: AgentKind, path: String, isLive: Bool) {
        self.id = id
        self.agent = agent
        self.path = path
        self.isLive = isLive
    }
}

/// A warning is relevant only when different agents share the exact folder;
/// separate worktrees and nested folders are not treated as the same checkout.
public struct SameFolderAgents: Sendable {
    private var occupants: [AgentFolderOccupant]

    public init(_ occupants: [AgentFolderOccupant]) {
        self.occupants = occupants
    }

    public func conflicts(for paneId: PaneID) -> [AgentFolderOccupant] {
        guard let selected = occupants.first(where: { $0.id == paneId }), selected.isLive,
              let folder = Self.normalized(selected.path) else { return [] }
        return occupants.filter {
            $0.id != paneId && $0.isLive && $0.agent != selected.agent
                && Self.normalized($0.path) == folder
        }
    }

    private static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL.path
    }
}
