import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct ShortcutCaptureTests {
    @Test func boundedOutputAndExit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data((String(repeating: "earlier\n", count: 10_000) + "\u{1B}[31mfailure\u{1B}[0m\n").utf8).write(to: folder.appendingPathComponent("output.log"))
        let base = CommandRunSummary(command: "make test")
        let running = try ShortcutCapture.read(in: folder, previous: base)
        #expect(running.exitCode == nil)
        #expect(running.output.utf8.count <= 16_384)
        #expect(running.output.hasSuffix("failure\n"))
        #expect(!running.output.contains("\u{1B}"))
        try Data("2\n".utf8).write(to: folder.appendingPathComponent("exit"))
        let done = try ShortcutCapture.read(in: folder, previous: running)
        #expect(done.exitCode == 2)
        #expect(done.finishedAt != nil)
        #expect(try ShortcutCapture.read(in: folder, previous: done) == done)
    }
    @Test func commandPaneExecutesCaptureWrapperInFolderWithSpaces() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut capture \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pane = PaneDescriptor(projectId: UUID(), kind: .command(cwd: folder.path,
            command: "printf 'captured stdout\\n'; printf 'captured stderr\\n' >&2; exit 7"), title: "Failing shortcut")
        let launch = TerminalLaunch.make(pane: pane, worktree: nil, remoteHost: nil, token: "fixture", shell: "/bin/bash")
        var environment = ProcessInfo.processInfo.environment
        environment.merge(launch.environment) { _, value in value }
        // Login shells must not source the developer's own startup files.
        environment["HOME"] = folder.path
        environment["TETHER_RUN_LOG"] = folder.appendingPathComponent("output.log").path
        environment["TETHER_RUN_STATUS"] = folder.appendingPathComponent("exit").path
        let output = try GitRunner.runBlocking(executable: "/bin/sh",
            arguments: ["-c", try #require(launch.command)], directory: try #require(launch.workingDirectory),
            environment: environment, timeout: 10, allowedExitCodes: [0])
        // The command exits 7, then the surviving shell sees null stdin and exits 0.
        #expect(output.status == 0)
        #expect(output.text.contains("captured stdout"))
        #expect(output.text.contains("captured stderr"))
        #expect(try String(contentsOf: folder.appendingPathComponent("exit"), encoding: .utf8) == "7\n")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("exit.tmp").path))
        let summary = try ShortcutCapture.read(in: folder, previous: CommandRunSummary(command: "failing shortcut"))
        #expect(summary.exitCode == 7)
        #expect(summary.finishedAt != nil)
        #expect(summary.output.contains("captured stdout"))
        #expect(summary.output.contains("captured stderr"))
    }

    @Test func protocol26ShortcutAndPullRequestRequestsRoundTrip() throws {
        #expect(ProtocolVersion.current == 26)
        let requestId = UUID(), paneId = UUID(), shortcutId = UUID()
        let shortcut = PhoneMessage.runShortcut(requestId: requestId, shortcutId: shortcutId, paneId: paneId)
        if case .runShortcut(let request, let configuredShortcut, let pane) = try WireCodec.decoder().decode(
            PhoneMessage.self, from: WireCodec.encoder().encode(shortcut)) {
            #expect(request == requestId)
            #expect(configuredShortcut == shortcutId)
            #expect(pane == paneId)
        } else { Issue.record("Shortcut request did not round trip") }
        for action in [PullRequestAction.create(title: "Title", body: "Body\nsecond line"),
                       .merge(expectedHead: "abc"), .rerunChecks(expectedHead: "def")] {
            let message = PhoneMessage.pullRequestAction(requestId: requestId, paneId: paneId, action: action)
            if case .pullRequestAction(let request, let pane, let decoded) = try WireCodec.decoder().decode(
                PhoneMessage.self, from: WireCodec.encoder().encode(message)) {
                #expect(request == requestId)
                #expect(pane == paneId)
                #expect(decoded == action)
            } else { Issue.record("Pull request action did not round trip") }
        }
    }

    @Test func protocol26ResultsAndSummariesRoundTrip() throws {
        let requestId = UUID(), paneId = UUID(), projectId = UUID()
        let messages: [MacMessage] = [
            .shortcutResult(requestId: requestId, paneId: paneId, error: nil),
            .shortcutResult(requestId: requestId, paneId: nil, error: "Shortcut no longer exists"),
            .pullRequestResult(requestId: requestId, message: "Merged", error: nil),
            .pullRequestResult(requestId: requestId, message: nil, error: "Revision changed"),
        ]
        for message in messages {
            let decoded = try WireCodec.decoder().decode(MacMessage.self, from: WireCodec.encoder().encode(message))
            switch (message, decoded) {
            case let (.shortcutResult(id, pane, error), .shortcutResult(decodedId, decodedPane, decodedError)):
                #expect(id == decodedId && pane == decodedPane && error == decodedError)
            case let (.pullRequestResult(id, result, error), .pullRequestResult(decodedId, decodedResult, decodedError)):
                #expect(id == decodedId && result == decodedResult && error == decodedError)
            default: Issue.record("Action result did not round trip")
            }
        }
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let command = CommandRunSummary(command: "make test", output: "failed\n", exitCode: 7, startedAt: at, finishedAt: at.addingTimeInterval(1))
        let pr = PullRequestSummary(number: 42, title: "A pull request", url: "https://example.com/pull/42", state: "OPEN",
                                   headRevision: "abc123", checksSummary: "1 failed")
        let session = SessionSummary(id: paneId, projectId: projectId, sessionId: nil, title: "Tests", state: .error,
                                     attention: nil, queued: 0, command: command, warning: "Shared folder", liveText: "Partial reply", pullRequest: pr)
        let shortcut = ShortcutSummary(id: UUID(), projectId: projectId, label: "Tests", command: "make test")
        let snapshot = Snapshot(macName: "Fixture Mac", projects: [], sessions: [session], permissions: [], shortcuts: [shortcut])
        if case .snapshot(let decoded) = try WireCodec.decoder().decode(MacMessage.self, from: WireCodec.encoder().encode(MacMessage.snapshot(snapshot))) {
            #expect(decoded.sessions == [session])
            #expect(decoded.sessions.first?.command == command)
            #expect(decoded.sessions.first?.pullRequest == pr)
            #expect(decoded.shortcuts == [shortcut])
        } else { Issue.record("Snapshot summaries did not round trip") }
    }

    @Test func oldLayoutWithoutCodexChatStaysTerminal() throws {
        let pane = PaneDescriptor(projectId: UUID(), kind: .codex(worktreeId: UUID(), resumeSessionId: nil), title: "Codex", codexChat: true)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pane)) as? [String: Any])
        #expect(legacy.removeValue(forKey: "codexChat") != nil)
        let decoded = try JSONDecoder().decode(PaneDescriptor.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.id == pane.id)
        #expect(decoded.kind == pane.kind)
        #expect(decoded.codexChat == nil)
    }
}
