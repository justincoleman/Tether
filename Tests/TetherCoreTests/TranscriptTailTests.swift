import Foundation
import Testing
import TetherProtocol
@testable import TetherCore

@Suite struct TranscriptSignalTests {
    @Test func detectsInterruptInTextBlock() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        #expect(TranscriptSignals.isUserInterrupt(line))
    }

    @Test func detectsInterruptDuringToolUse() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        #expect(TranscriptSignals.isUserInterrupt(line))
    }

    @Test func detectsInterruptAsPlainString() {
        let line = #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#
        #expect(TranscriptSignals.isUserInterrupt(line))
    }

    @Test func ignoresAssistantQuotingTheMarker() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        #expect(!TranscriptSignals.isUserInterrupt(line))
    }

    @Test func ignoresOrdinaryPromptsAndGarbage() {
        #expect(!TranscriptSignals.isUserInterrupt(#"{"type":"user","message":{"role":"user","content":"fix the bug"}}"#))
        #expect(!TranscriptSignals.isUserInterrupt("not json"))
    }
}

@Suite struct TranscriptTailTests {
    @Test func lineBufferHoldsPartialLines() {
        var b = JSONLLineBuffer()
        #expect(b.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(b.append(Data(":2}\n\n".utf8)) == ["{\"b\":2}"])
    }

    @Test func readsOnlyAppendedLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        try Data("old\n".utf8).write(to: url)
        var tail = TranscriptTail(path: url.path)
        #expect(tail.readNewLines().isEmpty)

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("new1\nnew2\n".utf8))
        try h.close()
        #expect(tail.readNewLines() == ["new1", "new2"])
        #expect(tail.readNewLines().isEmpty)
    }

    @Test func missingFileIsQuiet() {
        var tail = TranscriptTail(path: "/nonexistent/\(UUID().uuidString).jsonl")
        #expect(tail.readNewLines().isEmpty)
    }
}

@Suite struct PermissionModeRecordTests {
    @Test func modeRecordsGiveTheMode() {
        #expect(TranscriptSignals.permissionMode(#"{"type":"mode","mode":"plan","sessionId":"s"}"#) == "plan")
        #expect(TranscriptSignals.permissionMode(#"{"type":"permission-mode","permissionMode":"acceptEdits","sessionId":"s"}"#) == "acceptEdits")
        #expect(TranscriptSignals.permissionMode(#"{"type":"mode","mode":"normal"}"#) == "default")
    }

    @Test func otherRecordsAreNotModes() {
        #expect(TranscriptSignals.permissionMode(#"{"type":"user","uuid":"u","message":{"content":"set the mode to plan"}}"#) == nil)
        #expect(TranscriptSignals.permissionMode(#"{"type":"mode"}"#) == nil)
        #expect(TranscriptSignals.permissionMode("not json mode") == nil)
    }

    @Test func feedReportsTheNewestModeOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mode-\(UUID().uuidString).jsonl")
        let lines = [#"{"type":"mode","mode":"acceptEdits"}"#, #"{"type":"mode","mode":"plan"}"#]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let feed = TranscriptFeed(path: url.path)
        _ = await feed.poll()
        #expect(await feed.takeMode() == "plan")
        #expect(await feed.takeMode() == nil)
    }
}

@Suite struct LongTranscriptTests {
    private func writeTranscript(lines: Int) throws -> (URL, [String]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID().uuidString).jsonl")
        let rows = (0..<lines).map { i in
            #"{"type":"user","uuid":"u\#(i)","isSidechain":false,"timestamp":"2026-10-28T13:21:36.619Z","message":{"role":"user","content":"message number \#(i)"}}"#
        }
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: url)
        return (url, rows)
    }

    @Test func shortFileIsReadWhole() async throws {
        let (url, _) = try writeTranscript(lines: 5)
        let feed = TranscriptFeed(path: url.path, windowBytes: 1_000_000)
        let events = await feed.poll()
        #expect(events.count == 5)
        #expect(!events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func longFileOpensWithItsEndAndSaysSo() async throws {
        let (url, rows) = try writeTranscript(lines: 200)
        let window = UInt64(rows[0].utf8.count * 10 + 25) // about ten lines, starting mid-line
        let feed = TranscriptFeed(path: url.path, windowBytes: window)
        let events = await feed.poll()
        guard case .notice(_, let text, _)? = events.first else { Issue.record("no notice"); return }
        #expect(text == "Earlier messages are left out")
        let texts = events.compactMap { event -> String? in
            if case .userText(_, let t, _) = event { t } else { nil }
        }
        #expect(texts.last == "message number 199")
        #expect(texts.count >= 8 && texts.count <= 11)
        // The cut line is dropped, never parsed half-way.
        #expect(texts.first.map { $0.hasPrefix("message number ") } == true)
        #expect(await feed.poll().isEmpty)
    }

    @Test func appendedRecordsFollowTheWindow() async throws {
        let (url, _) = try writeTranscript(lines: 100)
        let feed = TranscriptFeed(path: url.path, windowBytes: 600)
        _ = await feed.poll()
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((Fixture.reply + "\n").utf8))
        try h.close()
        let events = await feed.poll()
        #expect(events.count == 1)
    }

    @Test func tailStartsOnAWholeLine() throws {
        let (url, rows) = try writeTranscript(lines: 50)
        var tail = TranscriptTail(path: url.path, lastBytes: UInt64(rows[0].utf8.count * 3 + 7))
        let lines = tail.readNewLines()
        #expect(tail.skippedEarlier)
        #expect(lines.allSatisfy { $0.hasPrefix("{") && $0.hasSuffix("}") })
        #expect(lines.last == rows.last)
    }
}
