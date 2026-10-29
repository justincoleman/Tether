import Foundation
import Testing
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
