import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

/// Codex 0.165 rollout record shapes; all conversation content is synthetic.
enum CodexRolloutFixture {
    static let user = #"{"timestamp":"2026-10-30T12:00:00.000Z","type":"response_item","payload":{"type":"message","id":null,"role":"user","content":[{"type":"input_text","text":"Fix the test"}]}}"#
    static let assistant = #"{"timestamp":"2026-10-30T12:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"The test passes."}]}}"#
    static let command = #"{"timestamp":"2026-10-30T12:00:02.000Z","type":"response_item","payload":{"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}"}}"#
    static let result = #"{"timestamp":"2026-10-30T12:00:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"Process exited with code 0\nAll tests passed"}}"#
    static let usage = #"{"timestamp":"2026-10-30T12:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":500,"output_tokens":80},"model_context_window":258400}}}"#
}

@Suite struct CodexTranscriptTests {
    @Test func publicConversationAndStableMissingIDs() {
        let a = CodexTranscriptParser.events(fromLine: CodexRolloutFixture.user)
        #expect(a == CodexTranscriptParser.events(fromLine: CodexRolloutFixture.user))
        guard case .userText(_, let text, _)? = a.first else { Issue.record("missing user"); return }
        #expect(text == "Fix the test")
        guard case .assistantText(_, let reply, _)? = CodexTranscriptParser.events(fromLine: CodexRolloutFixture.assistant).first else { Issue.record("missing reply"); return }
        #expect(reply == "The test passes.")
        var model = TranscriptModel()
        model.apply(a + a)
        #expect(model.items.count == 1)
    }

    @Test func hidesPrivateAndDuplicateRecords() {
        let records = [
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"secret instructions"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"analysis","content":[{"type":"output_text","text":"private reasoning"}]}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"private"}]}}"#,
            #"{"type":"response_item","payload":{"type":"agent_message","content":[{"type":"text","text":"private handback"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>injected</environment_context>"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Fix the test"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"The test passes."}}"#,
            "not json",
        ]
        for record in records { #expect(CodexTranscriptParser.events(fromLine: record).isEmpty) }
    }

    @Test func commandResultsAndUsageFoldLikeClaude() {
        var model = TranscriptModel()
        model.apply([CodexRolloutFixture.command, CodexRolloutFixture.result, CodexRolloutFixture.usage].flatMap(CodexTranscriptParser.events(fromLine:)))
        #expect(model.usage == ContextUsage(inputTokens: 1000, contextWindow: 258400))
        guard case .steps(_, let steps)? = model.items.first else { Issue.record("missing tool"); return }
        #expect(steps.count == 1 && steps[0].name == "Bash")
        #expect(steps[0].summary == "swift test")
        #expect(steps[0].result?.contains("All tests passed") == true && !steps[0].isError)
    }

    @Test func customToolAndInterruptAreVisibleWithoutReasoning() {
        let call = #"{"timestamp":"2026-10-30T12:00:05Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"patch_1","name":"apply_patch","input":"*** Begin Patch\n*** End Patch"}}"#
        let result = #"{"timestamp":"2026-10-30T12:00:06Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"patch_1","output":"Failed to apply patch"}}"#
        let abort = #"{"timestamp":"2026-10-30T12:00:07Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
        #expect(CodexTranscriptParser.events(fromLine: call).count == 1)
        guard case .toolResult(_, let id, _, let failed, _)? = CodexTranscriptParser.events(fromLine: result).first else { Issue.record("missing result"); return }
        #expect(id == "patch_1" && failed)
        guard case .notice(_, let text, _)? = CodexTranscriptParser.events(fromLine: abort).first else { Issue.record("missing notice"); return }
        #expect(text == "Interrupted")
    }

    @Test func codexFeedPreservesWindowAndWaitsForPartialLine() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout.jsonl")
        try Data((CodexRolloutFixture.user + "\n" + CodexRolloutFixture.usage).utf8).write(to: url)
        let feed = TranscriptFeed(path: url.path, agent: .codex)
        #expect(await feed.poll().count == 1)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let events = await feed.poll()
        guard case .usage(let usage, _)? = events.first else { Issue.record("missing usage"); return }
        #expect(usage.contextWindow == 258400)
    }
}

@Suite struct CodexTranscriptLocatorTests {
    @Test func findsOnlyMatchingValidatedRollout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026/10/30")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let url = directory.appendingPathComponent("rollout-2026-10-30T12-00-00-\(id).jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/project\"}}\n".utf8).write(to: url)
        let found = try #require(CodexTranscriptLocator.find(sessionId: id, in: root))
        // Foundation's enumerator expands /var to /private/var on macOS;
        // resolvingSymlinksInPath deliberately preserves that system alias.
        #expect(URL(fileURLWithPath: found).lastPathComponent == url.lastPathComponent)
        #expect(FileManager.default.contentsEqual(atPath: found, andPath: url.path))
        #expect(CodexTranscriptLocator.find(sessionId: "../../private", in: root) == nil)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(UUID())\",\"cwd\":\"/project\"}}\n".utf8).write(to: url)
        #expect(CodexTranscriptLocator.find(sessionId: id, in: root) == nil)
    }

    @Test func refusesSymlinkOutsideSessionsAndBoundedSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026/10/30")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let external = root.appendingPathComponent("outside.jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/project\"}}\n".utf8).write(to: external)
        let link = directory.appendingPathComponent("rollout-time-\(id).jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        #expect(CodexTranscriptLocator.find(sessionId: id, in: root, maxEntries: 0) == nil)
        // A rollout must sit in the dated directory layout, not a top-level alias.
        #expect(CodexTranscriptLocator.find(sessionId: id, in: root) == nil)
    }
}
