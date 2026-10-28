import Foundation
import TetherProtocol

public typealias RemoteHostID = UUID

/// A machine reachable over SSH, e.g. the always-on Mac mini.
public struct RemoteHost: Codable, Hashable, Sendable, Identifiable {
    public var id: RemoteHostID
    public var name: String
    public var host: String
    public var user: String?

    public init(id: RemoteHostID = UUID(), name: String, host: String, user: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
    }

    public var sshTarget: String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }
}

/// What a terminal tab is running. Persisted so a relaunch restores the workspace.
public enum PaneKind: Codable, Hashable, Sendable {
    /// Claude Code in a worktree. `resumeSessionId` is the last session seen there.
    case claude(worktreeId: WorktreeID, resumeSessionId: SessionID?)
    /// A plain shell in a directory.
    case shell(cwd: String)
    /// An interactive SSH session to a remote host.
    case ssh(hostId: RemoteHostID)
    /// A quick action: runs `command` in `cwd`, then leaves a shell open there.
    case command(cwd: String, command: String)
}

/// A project's shortcut command, e.g. `npm run dev`, shown in the top bar.
public struct QuickAction: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectId: ProjectID
    public var name: String
    public var command: String

    public init(id: UUID = UUID(), projectId: ProjectID, name: String, command: String) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.command = command
    }

    /// The button label: the name, or the command when no name was given.
    public var label: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? command.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }
}

public struct PaneDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: PaneID
    public var projectId: ProjectID
    public var kind: PaneKind
    public var title: String

    public init(id: PaneID = UUID(), projectId: ProjectID, kind: PaneKind, title: String) {
        self.id = id
        self.projectId = projectId
        self.kind = kind
        self.title = title
    }
}
