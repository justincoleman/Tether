import SwiftUI
import TetherProtocol

/// Isolated simulator host. The companion script replaces only temporary
/// source copies: saved pairings are never loaded and connect() is disabled.
@main
struct PhoneWorkflowPreview: App {
    @State private var store: PhoneStore
    private let connection: MacConnection
    private let nativePane = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let commandPane = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let emptyPane = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    @MainActor init() {
        let project = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let native = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let command = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let empty = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let mac = PairedMac(id: UUID(), name: "QA Mac", host: "100.64.0.254", port: 0, token: "fixture-only")
        let connection = MacConnection(mac: mac)
        let at = Date(timeIntervalSince1970: 1_793_361_600)
        var transcript = TranscriptModel()
        transcript.apply([
            .userText(id: "user", text: "Review the new Codex phone workflow.", at: at),
            .assistantText(id: "assistant", text: "The conversation appears on your phone. Public messages and command results stay together.", at: at),
            .toolUse(id: "tool", name: "Bash", summary: "swift test --filter CodexTranscript", at: at),
            .toolResult(id: "result", toolUseId: "tool", summary: "Seven tests passed.", isError: false, at: at),
            .usage(ContextUsage(inputTokens: 24_000, contextWindow: 258_400), at: at),
        ])
        let snapshot = Snapshot(macName: mac.name, projects: [
            ProjectSummary(id: project, name: "Tether QA", branch: "codex/phone-workflows", pinned: true),
            ProjectSummary(id: UUID(), name: "No Open Tabs", branch: "main"),
        ], sessions: [
            SessionSummary(id: native, projectId: project, sessionId: "qa-codex", title: "Codex review", state: .working, attention: nil, queued: 0,
                           preview: "Review the new Codex phone workflow.", agent: .codex,
                           warning: "Claude and Codex share this folder. Their edits can overlap.",
                           liveText: "Checking the remaining phone controls…",
                           pullRequest: PullRequestSummary(number: 87, title: "Codex phone workflows", url: "https://example.invalid/pull/87", state: "open", headRevision: "fixture-revision", checksSummary: "2 checks passed")),
            SessionSummary(id: command, projectId: project, sessionId: nil, title: "Run Tests", state: .error, attention: nil, queued: 0,
                           command: CommandRunSummary(command: "swift test", output: "Test Suite 'CodexTranscriptTests' started.\nSeven tests passed.\nFixture failure: expected exit code 0, got 7.", exitCode: 7, startedAt: at, finishedAt: at.addingTimeInterval(3))),
            SessionSummary(id: empty, projectId: project, sessionId: "qa-empty", title: "New Codex chat", state: .idle, attention: nil, queued: 0, agent: .codex),
        ], permissions: [], shortcuts: [ShortcutSummary(id: UUID(), projectId: project, label: "Run Tests", command: "swift test")])
        connection.qaInstall(snapshot: snapshot, transcripts: ["qa-codex": transcript])
        let store = PhoneStore()
        store.qaInstall(connection: connection)
        self.connection = connection
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            let screen = ProcessInfo.processInfo.environment["TETHER_QA_SCREEN"] ?? "native"
            Group {
                if screen == "overview" { OverviewView(showPairing: .constant(false)) }
                else {
                    NavigationStack {
                        SessionView(connection: connection, paneId: screen == "command" ? commandPane : screen == "empty" ? emptyPane : nativePane)
                    }
                }
            }
            .environment(store)
        }
    }
}
