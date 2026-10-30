import Foundation

/// Captured by the shortcut launcher, never scraped from a terminal screen.
public struct CommandRunSummary: Codable, Hashable, Sendable {
    public var command: String
    public var output: String
    public var exitCode: Int32?
    public var startedAt: Date
    public var finishedAt: Date?
    public init(command: String, output: String = "", exitCode: Int32? = nil,
                startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.command = command; self.output = output; self.exitCode = exitCode
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct ShortcutSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectId: ProjectID
    public var label: String
    public var command: String
    public init(id: UUID, projectId: ProjectID, label: String, command: String) {
        self.id = id; self.projectId = projectId; self.label = label; self.command = command
    }
}

public struct PullRequestSummary: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: String
    public var headRevision: String
    public var checksSummary: String
    public init(number: Int, title: String, url: String, state: String, headRevision: String, checksSummary: String) {
        self.number = number; self.title = title; self.url = url; self.state = state
        self.headRevision = headRevision; self.checksSummary = checksSummary
    }
}

public enum PullRequestAction: Codable, Hashable, Sendable {
    case create(title: String, body: String)
    case merge(expectedHead: String)
    case rerunChecks(expectedHead: String)
}
