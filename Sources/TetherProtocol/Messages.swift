import Foundation

/// A single rendered unit of a session transcript, as shown in the chat mirror.
public enum MirrorEvent: Codable, Hashable, Sendable {
    case userText(id: String, text: String, at: Date)
    case assistantText(id: String, text: String, at: Date)
    case toolUse(id: String, name: String, summary: String, at: Date)
    case toolResult(id: String, toolUseId: String, summary: String, isError: Bool, at: Date)
    /// What a tool call touched: its file and, for edits, the lines taken out and put in.
    case toolDetail(toolUseId: String, file: String?, removed: [String], added: [String], at: Date)
    case usage(ContextUsage, at: Date)
    /// A muted system line, e.g. "Interrupted".
    case notice(id: String, text: String, at: Date)
}

public struct Hello: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var appVersion: String
    public var deviceName: String

    public init(protocolVersion: Int = ProtocolVersion.current, appVersion: String, deviceName: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.deviceName = deviceName
    }
}

/// Claude Code's "Do you trust the files in this folder?" question, shown
/// through the same card as a permission so the phone can answer it too.
/// It is not a hook: Tether reads `~/.claude.json` (see `FolderTrust`) and
/// passes the user's answer to the terminal as a key press.
public enum TrustFolder {
    public static let toolName = "TrustFolder"
}

extension PermissionRequested {
    public var isFolderTrust: Bool { toolName == TrustFolder.toolName }

    /// "Claude wants to run a command", or the folder-trust question.
    public var heading: String {
        if isFolderTrust { return "Do you trust the files in this folder?" }
        if let question { return question.question }
        return "Claude wants to \(title.lowercased())"
    }
}

/// A project as the phone lists it.
public struct ProjectSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectID
    public var name: String
    /// Branch label as the Mac sidebar shows it, e.g. "main".
    public var branch: String?

    public init(id: ProjectID, name: String, branch: String?) {
        self.id = id
        self.name = name
        self.branch = branch
    }
}

/// One Claude tab on the Mac. Keyed by pane because a tab keeps its place in
/// the list while `/clear` gives it a new Claude session.
public struct SessionSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: PaneID
    public var projectId: ProjectID
    /// Nil until the tab's Claude session is known.
    public var sessionId: SessionID?
    public var title: String
    public var state: SessionState
    public var attention: AttentionReason?
    /// Messages held on the Mac until Claude can take them.
    public var queued: Int
    /// The latest message in the conversation, shortened, so tabs are
    /// recognisable in a list. See `TranscriptModel.preview`.
    public var preview: String?
    /// Permission mode from hooks, e.g. "auto". Nil until a hook reports it.
    public var permissionMode: String?
    /// Model and cost from the status line. Nil until Claude Code draws it.
    public var status: SessionStatus?

    public init(id: PaneID, projectId: ProjectID, sessionId: SessionID?, title: String,
                state: SessionState, attention: AttentionReason?, queued: Int, preview: String? = nil,
                permissionMode: String? = nil, status: SessionStatus? = nil) {
        self.id = id
        self.projectId = projectId
        self.sessionId = sessionId
        self.title = title
        self.state = state
        self.attention = attention
        self.queued = queued
        self.preview = preview
        self.permissionMode = permissionMode
        self.status = status
    }
}

/// A multiple-choice question from Claude's AskUserQuestion tool, as a card.
/// Only single questions with single answers are shown this way; anything
/// else stays a permission card with "Ask in Terminal".
public struct QuestionPrompt: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        public var label: String
        public var description: String

        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    /// The short chip above the question, e.g. "Color".
    public var header: String
    public var question: String
    public var options: [Option]

    public init(header: String, question: String, options: [Option]) {
        self.header = header
        self.question = question
        self.options = options
    }
}

public struct PermissionRequested: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var paneId: PaneID?
    public var sessionId: SessionID
    public var toolName: String
    /// "Run a command", "Edit a file", ...
    public var title: String
    /// The command, path or input, already formatted for display.
    public var detail: String
    /// Set for a question Claude asks with options, so a card can offer them.
    public var question: QuestionPrompt?

    public init(id: UUID, paneId: PaneID?, sessionId: SessionID, toolName: String,
                title: String, detail: String, question: QuestionPrompt? = nil) {
        self.question = question
        self.id = id
        self.paneId = paneId
        self.sessionId = sessionId
        self.toolName = toolName
        self.title = title
        self.detail = detail
    }
}

/// A project's icon as a small PNG (about 128 px), found in its folder.
public struct ProjectIcon: Codable, Hashable, Sendable {
    public var id: ProjectID
    public var png: Data

    public init(id: ProjectID, png: Data) {
        self.id = id
        self.png = png
    }
}

/// A past Claude session on the Mac, for the History list.
public struct PastSessionInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: SessionID
    /// `/rename` title, else Claude Code's generated title.
    public var title: String?
    /// The first thing typed in the session.
    public var firstPrompt: String?
    public var branch: String?
    public var lastActivity: Date

    public init(id: SessionID, title: String?, firstPrompt: String?, branch: String?, lastActivity: Date) {
        self.id = id
        self.title = title
        self.firstPrompt = firstPrompt
        self.branch = branch
        self.lastActivity = lastActivity
    }

    public var displayTitle: String { title ?? firstPrompt ?? id }

    /// Every word of `query` appears in the title or the first prompt.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [title, firstPrompt].compactMap { $0 }.joined(separator: "\n").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// One file from a tab's worktree, read on the Mac for a paired Mac's Files panel.
public struct RemoteFile: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, image, binary, unreadable
    }

    /// Relative to the worktree root.
    public var path: String
    public var kind: Kind
    /// `text`: the start of the file, as the Mac's viewer shows it.
    public var text: String?
    /// `image`: the file's bytes.
    public var image: Data?
    /// Only the start of the file is included.
    public var truncated: Bool
    /// `unreadable`: why.
    public var note: String?

    public init(path: String, kind: Kind, text: String? = nil, image: Data? = nil,
                truncated: Bool = false, note: String? = nil) {
        self.path = path
        self.kind = kind
        self.text = text
        self.image = image
        self.truncated = truncated
        self.note = note
    }
}

/// A dev server the Mac found running in a tab's folder, for the Preview panel.
public struct DevServerInfo: Codable, Hashable, Sendable, Identifiable {
    public var port: Int
    public var command: String

    public var id: Int { port }

    public init(port: Int, command: String) {
        self.port = port
        self.command = command
    }
}

/// The Mac terminal's background and text colors as `#rrggbb`, so the phone
/// can wear them. Light or dark follows from the background.
public struct MacTheme: Codable, Hashable, Sendable {
    public var background: String
    public var foreground: String

    public init(background: String, foreground: String) {
        self.background = background
        self.foreground = foreground
    }
}

/// The Mac's whole state for the phone. Small, so it is resent in full on
/// every change instead of diffed.
public struct Snapshot: Codable, Hashable, Sendable {
    public var macName: String
    public var projects: [ProjectSummary]
    public var sessions: [SessionSummary]
    public var permissions: [PermissionRequested]
    /// The latest plan limits any session's status line reported.
    public var limits: UsageLimits?
    /// The Mac's Ghostty colors, when it has them.
    public var theme: MacTheme?

    public init(macName: String, projects: [ProjectSummary], sessions: [SessionSummary],
                permissions: [PermissionRequested], limits: UsageLimits? = nil, theme: MacTheme? = nil) {
        self.theme = theme
        self.macName = macName
        self.projects = projects
        self.sessions = sessions
        self.permissions = permissions
        self.limits = limits
    }
}

/// Mac → phone. See docs/PROTOCOL.md.
public enum MacMessage: Codable, Sendable {
    case hello(Hello)
    /// Pairing succeeded. The phone keeps `token` for every later connection.
    case paired(macId: UUID, macName: String, token: String)
    case authenticated(macId: UUID, macName: String)
    /// The Mac closes the connection after this.
    case authFailed(reason: String)
    case snapshot(Snapshot)
    /// Every project icon the Mac has, sent after auth and whenever one
    /// changes. A project missing from the list has none: show the letter tile.
    /// Separate from `snapshot`, which is resent on every change.
    case projectIcons([ProjectIcon])
    /// Transcript events for a subscribed session. `reset` replaces what the
    /// phone holds (sent first after subscribing); otherwise append.
    case transcript(sessionId: SessionID, events: [MirrorEvent], reset: Bool)
    /// Answer to `sendMessage`: "sent", "queued" or "failed".
    case sendResult(paneId: PaneID, outcome: String)
    /// Answer to `startSession`: the new tab, or why it couldn't start.
    case startResult(requestId: UUID, paneId: PaneID?, error: String?)
    /// Answer to `requestChanges`: the tab's worktree against its base branch.
    case changes(requestId: UUID, snapshot: ChangesSnapshot?, error: String?)
    /// Answer to `requestDiff`.
    case fileDiff(requestId: UUID, diff: FileDiff?, error: String?)
    /// Answer to `requestFileList`: relative paths, as the Mac's Files panel lists them.
    case fileList(requestId: UUID, paths: [String]?, error: String?)
    /// Answer to `requestFile`.
    case fileContent(requestId: UUID, file: RemoteFile?, error: String?)
    /// Answer to `requestDevServers`.
    case devServers(requestId: UUID, servers: [DevServerInfo]?, error: String?)
    /// Answer to `requestHistory`: past sessions in the project, newest first.
    case history(requestId: UUID, sessions: [PastSessionInfo]?, error: String?)
    case error(message: String)
}

/// Phone → Mac. See docs/PROTOCOL.md.
public enum PhoneMessage: Codable, Sendable {
    case hello(Hello)
    /// First connection: the one-time code from the Mac's QR.
    case pair(code: String)
    /// Every later connection.
    case authenticate(token: String)
    /// Stream this session's transcript; nil stops streaming.
    case subscribe(sessionId: SessionID?)
    case sendMessage(paneId: PaneID, text: String)
    /// Stops Claude's current turn, like Esc in the terminal.
    case interrupt(paneId: PaneID)
    case permissionDecision(requestId: UUID, allow: Bool)
    /// Answers a `PermissionRequested.question` with one option's label, or free text.
    case answerQuestion(requestId: UUID, answer: String)
    /// Opens a Claude tab in the project, on a new worktree branch when
    /// `branch` is set, starting on `prompt` when it isn't empty, in
    /// `permissionMode` when set (otherwise the user's configured default).
    case startSession(requestId: UUID, projectId: ProjectID, branch: String?, prompt: String,
                      permissionMode: String?)
    /// Sidebar order, all of the Mac's project ids.
    case reorderProjects(ids: [ProjectID])
    /// Display name only; the folder is untouched.
    case renameProject(id: ProjectID, name: String)
    /// Closes a Claude tab on the Mac, like its x button. Ends a running turn.
    case closeSession(paneId: PaneID)
    /// Switches a tab's model by typing `/model <model>`, queued like a
    /// message. `model` is an alias ("opus") or a full model id.
    case setModel(paneId: PaneID, model: String)
    /// Push tokens for this phone; sent after auth and when they change.
    case registerPush(PushRegistration)
    /// The update token of the Live Activity for a tab, or nil when it ended.
    case registerActivity(paneId: PaneID, token: String?)
    /// The Changes list for a tab's worktree; answered with `changes`.
    case requestChanges(requestId: UUID, paneId: PaneID)
    /// One file's diff from that list; answered with `fileDiff`.
    case requestDiff(requestId: UUID, paneId: PaneID, file: ChangedFile)
    /// The files in a tab's worktree; answered with `fileList`.
    case requestFileList(requestId: UUID, paneId: PaneID)
    /// One file from that list; answered with `fileContent`.
    case requestFile(requestId: UUID, paneId: PaneID, path: String)
    /// Dev servers running in a tab's folder; answered with `devServers`.
    case requestDevServers(requestId: UUID, paneId: PaneID)
    /// The project's past Claude sessions; answered with `history`.
    case requestHistory(requestId: UUID, projectId: ProjectID)
    /// Opens a past session in a Claude tab (or finds the tab already running
    /// it); answered with `startResult`.
    case resumeSession(requestId: UUID, projectId: ProjectID, sessionId: SessionID)
    /// A photo plus optional text for Claude. The Mac saves the image and
    /// sends the text with its path, like `sendMessage`; answered with `sendResult`.
    case sendImage(paneId: PaneID, image: Data, text: String)
}

/// Shared encoder/decoder configuration so both sides agree on date format.
public enum WireCodec {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
