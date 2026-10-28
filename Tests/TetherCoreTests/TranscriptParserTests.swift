import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

/// Record shapes taken from Claude Code 2.1.308 transcripts; content is synthetic.
enum Fixture {
    static let prompt = #"{"type":"user","uuid":"u1","isSidechain":false,"timestamp":"2026-10-28T13:21:36.619Z","message":{"role":"user","content":"fix the failing test"}}"#
    static let command = "{\"type\":\"user\",\"uuid\":\"u2\",\"isSidechain\":false,\"timestamp\":\"2026-10-28T13:22:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/model</command-name>\\n<command-message>model</command-message>\\n<command-args>claude-opus-5-5</command-args>\"}}"
    static let commandOutput = #"{"type":"user","uuid":"u3","isSidechain":false,"timestamp":"2026-10-28T13:22:01.000Z","message":{"role":"user","content":"<local-command-stdout>Set model</local-command-stdout>"}}"#
    static let meta = #"{"type":"user","uuid":"u4","isMeta":true,"isSidechain":false,"timestamp":"2026-10-28T13:22:02.000Z","message":{"role":"user","content":[{"type":"text","text":"[Image: source: /tmp/x.png]"}]}}"#
    static let thinkingAndText = #"{"type":"assistant","uuid":"a1","isSidechain":false,"timestamp":"2026-10-28T13:22:03.000Z","message":{"id":"msg_1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"hmm","signature":"x"},{"type":"text","text":"Looking at the test."}],"usage":{"input_tokens":2,"cache_creation_input_tokens":6710,"cache_read_input_tokens":167288,"output_tokens":40}}}"#
    static let toolUse = #"{"type":"assistant","uuid":"a2","isSidechain":false,"timestamp":"2026-10-28T13:22:04.000Z","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test"},"caller":{}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":174000,"output_tokens":5}}}"#
    static let toolUse2 = #"{"type":"assistant","uuid":"a3","isSidechain":false,"timestamp":"2026-10-28T13:22:05.000Z","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/p/Sources/A.swift"}}]}}"#
    static let toolResultError = #"{"type":"user","uuid":"u5","isSidechain":false,"timestamp":"2026-10-28T13:22:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"\nerror: 1 test failed\nmore"}]}}"#
    static let toolResultList = #"{"type":"user","uuid":"u6","isSidechain":false,"timestamp":"2026-10-28T13:22:07.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"import Foundation"}]}]}}"#
    static let reply = #"{"type":"assistant","uuid":"a4","isSidechain":false,"timestamp":"2026-10-28T13:22:08.000Z","message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"Fixed. Want me to open a PR?"}]}}"#
    static let interrupt = #"{"type":"user","uuid":"u7","isSidechain":false,"timestamp":"2026-10-28T13:22:09.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    static let sidechain = #"{"type":"assistant","uuid":"a5","isSidechain":true,"timestamp":"2026-10-28T13:22:10.000Z","message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}"#
    static let otherTypes = [
        #"{"type":"attachment","uuid":"x1","attachment":{}}"#,
        #"{"type":"mode","mode":"auto","sessionId":"s"}"#,
        #"{"type":"last-prompt","lastPrompt":"hi","sessionId":"s"}"#,
        #"{"type":"system","uuid":"x2","subtype":"stop_hook_summary"}"#,
    ]
    static let imageWithText = #"{"type":"user","uuid":"u8","isSidechain":false,"timestamp":"2026-10-28T13:22:11.000Z","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"what is this?"}]}}"#

    static var session: [String] {
        [prompt, command, commandOutput, meta, thinkingAndText, toolUse, toolUse2,
         toolResultError, toolResultList, reply] + otherTypes + [sidechain, interrupt]
    }
}

@Suite struct TranscriptParserTests {
    private func parse(_ line: String) -> [MirrorEvent] { TranscriptParser.events(fromLine: line) }

    @Test func plainPrompt() {
        guard case .userText(_, let text, let at)? = parse(Fixture.prompt).first else { Issue.record("no event"); return }
        #expect(text == "fix the failing test")
        #expect(abs(at.timeIntervalSince1970 - 1_793_193_696.619) < 0.001)
    }

    @Test func slashCommandShowsNameAndArgs() {
        guard case .userText(_, let text, _)? = parse(Fixture.command).first else { Issue.record("no event"); return }
        #expect(text == "/model claude-opus-5-5")
    }

    @Test func hidesPlumbing() {
        #expect(parse(Fixture.commandOutput).isEmpty)
        #expect(parse(Fixture.meta).isEmpty)
        #expect(parse(Fixture.sidechain).isEmpty)
        for line in Fixture.otherTypes { #expect(parse(line).isEmpty) }
        #expect(parse("not json").isEmpty)
    }

    @Test func assistantSkipsThinkingAndReportsUsage() {
        let events = parse(Fixture.thinkingAndText)
        #expect(events.count == 2)
        guard case .assistantText(_, let text, _) = events[0],
              case .usage(let usage, _) = events[1] else { Issue.record("shape"); return }
        #expect(text == "Looking at the test.")
        #expect(usage == ContextUsage(inputTokens: 174_000, contextWindow: 200_000))
    }

    @Test func largeContextImpliesMillionWindow() {
        let u = TranscriptParser.contextUsage(.object(["cache_read_input_tokens": .number(520_581)]))
        #expect(u?.contextWindow == 1_000_000)
    }

    @Test func toolUseIsSummarised() {
        guard case .toolUse(let id, let name, let summary, _)? = parse(Fixture.toolUse).first else { Issue.record("shape"); return }
        #expect(id == "toolu_1")
        #expect(name == "Bash")
        #expect(summary == "swift test")
    }

    @Test func toolResultTakesFirstNonEmptyLine() {
        guard case .toolResult(_, let useId, let summary, let isError, _)? = parse(Fixture.toolResultError).first
        else { Issue.record("shape"); return }
        #expect(useId == "toolu_1")
        #expect(summary == "error: 1 test failed")
        #expect(isError)
        guard case .toolResult(_, _, let listSummary, let listError, _)? = parse(Fixture.toolResultList).first
        else { Issue.record("shape"); return }
        #expect(listSummary == "import Foundation")
        #expect(!listError)
    }

    @Test func interruptBecomesNotice() {
        guard case .notice(_, let text, _)? = parse(Fixture.interrupt).first else { Issue.record("shape"); return }
        #expect(text == "Interrupted")
    }

    @Test func imagesAreMentioned() {
        guard case .userText(_, let text, _)? = parse(Fixture.imageWithText).first else { Issue.record("shape"); return }
        #expect(text == "what is this?\n[image]")
    }
}

@Suite struct TranscriptModelTests {
    private func model(_ lines: [String]) -> TranscriptModel {
        var m = TranscriptModel()
        m.apply(lines.flatMap(TranscriptParser.events(fromLine:)))
        return m
    }

    @Test func groupsConsecutiveToolCallsAndAttachesResults() {
        let m = model(Fixture.session)
        // user prompt, /model, assistant text, one steps row, reply, interrupt notice
        #expect(m.items.count == 6)
        guard case .steps(_, let steps) = m.items[3] else { Issue.record("expected steps"); return }
        #expect(steps.map(\.name) == ["Bash", "Read"])
        #expect(steps[0].isError && steps[0].result == "error: 1 test failed")
        #expect(steps[1].result == "import Foundation" && !steps[1].isRunning)
        #expect(m.usage?.inputTokens == 174_012)
    }

    @Test func textBetweenToolCallsStartsANewGroup() {
        let m = model([Fixture.toolUse, Fixture.reply, Fixture.toolUse2])
        #expect(m.items.count == 3)
    }

    @Test func applyingTwiceIsANoOp() {
        var m = model(Fixture.session)
        let before = m
        m.apply(Fixture.session.flatMap(TranscriptParser.events(fromLine:)))
        #expect(m == before)
    }
}

@Suite struct TranscriptFeedTests {
    @Test func firstPollIsHistoryThenOnlyNewRecords() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feed-\(UUID().uuidString).jsonl")
        try Data((Fixture.prompt + "\n").utf8).write(to: url)
        let feed = TranscriptFeed(path: url.path)
        #expect(await feed.poll().count == 1)
        #expect(await feed.poll().isEmpty)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((Fixture.reply + "\n").utf8))
        try h.close()
        #expect(await feed.poll().count == 1)
    }
}
