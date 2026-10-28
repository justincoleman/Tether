import Foundation
import Testing
@testable import TetherCore

@Suite struct SessionHistoryTests {
    /// Trimmed from a Claude Code 2.1.312 transcript: titles are rewritten
    /// as the session goes, meta and sidechain records come first.
    static let transcript = """
    {"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-28T23:05:08.754Z","sessionId":"S1","content":"hey"}
    {"type":"ai-title","aiTitle":"Early title","sessionId":"S1"}
    {"type":"user","isMeta":true,"isSidechain":false,"cwd":"/Users/j/Duet","gitBranch":"main","message":{"role":"user","content":"Caveat: injected"},"uuid":"u0"}
    {"type":"user","isSidechain":true,"cwd":"/Users/j/Duet","message":{"role":"user","content":"subagent task"},"uuid":"u1"}
    {"type":"user","isSidechain":false,"cwd":"/Users/j/Duet","gitBranch":"main","message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"},"uuid":"u2"}
    {"type":"user","isSidechain":false,"cwd":"/Users/j/Duet","gitBranch":"main","message":{"role":"user","content":[{"type":"text","text":"Find or make a square icon\\nfor this project"}]},"uuid":"u3"}
    {"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Sure"}]},"uuid":"a1"}
    {"type":"ai-title","aiTitle":"Square project icon","sessionId":"S1"}
    {"type":"user","isSidechain":false,"cwd":"/Users/j/Duet","gitBranch":"icon","message":{"role":"user","content":"thanks"},"uuid":"u4"}
    """

    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func summarizesTitlePromptAndBranch() throws {
        let s = try #require(SessionHistory.summarize(head: Data(Self.transcript.utf8), tail: Data(),
                                                      sessionId: "S1", modified: date))
        #expect(s.title == "Square project icon")
        #expect(s.firstPrompt == "Find or make a square icon for this project")
        #expect(s.cwd == "/Users/j/Duet")
        #expect(s.branch == "icon")
        #expect(s.lastActivity == date)
    }

    @Test func customTitleBeatsGeneratedOne() throws {
        let text = Self.transcript + "\n{\"type\":\"custom-title\",\"customTitle\":\"Icon work\",\"sessionId\":\"S1\"}\n"
        let s = try #require(SessionHistory.summarize(head: Data(text.utf8), tail: Data(), sessionId: "S1", modified: date))
        #expect(s.displayTitle == "Icon work")
    }

    @Test func slashCommandsReadAsTyped() {
        let content = "<command-name>/review</command-name>\n<command-message>review</command-message>\n<command-args>PR 4</command-args>"
        #expect(SessionHistory.promptText(content) == "/review PR 4")
        #expect(SessionHistory.promptText("[Request interrupted by user]") == nil)
        #expect(SessionHistory.promptText([["type": "tool_result", "content": "ok"]]) == nil)
    }

    @Test func sessionWithNothingTypedIsSkipped() {
        let text = #"{"type":"ai-title","aiTitle":"x","sessionId":"S"}"#
        #expect(SessionHistory.summarize(head: Data(text.utf8), tail: Data(), sessionId: "S", modified: date) == nil)
    }

    @Test func cutOffLinesAreIgnored() throws {
        // A tail chunk starts mid-line.
        let tail = #"ssage":{"content":"x"}}"# + "\n" + #"{"type":"custom-title","customTitle":"Renamed"}"#
        let s = try #require(SessionHistory.summarize(head: Data(Self.transcript.utf8), tail: Data(tail.utf8),
                                                      sessionId: "S1", modified: date))
        #expect(s.title == "Renamed")
    }

    @Test func searchMatchesEveryWord() throws {
        let s = PastSession(id: "S", title: "Square project icon", firstPrompt: "Find or make one",
                            cwd: nil, branch: nil, lastActivity: date)
        #expect(s.matches(""))
        #expect(s.matches("ICON find"))
        #expect(!s.matches("icon deploy"))
    }

    @Test func encodesFolderNames() {
        #expect(SessionHistory.encodedDirectoryName("/Volumes/justin/code/Developer/Duet") == "-Volumes-justin-code-Developer-Duet")
        #expect(SessionHistory.encodedDirectoryName("/Users/j/my.app_x") == "-Users-j-my-app-x")
    }

    @Test func listsNewestFirstFromMatchingFolders() throws {
        let fm = FileManager.default
        let projects = fm.temporaryDirectory.appendingPathComponent("tether-history-\(UUID().uuidString)")
        let duet = projects.appendingPathComponent("-Users-j-Duet")
        let other = projects.appendingPathComponent("-Users-j-Other")
        try fm.createDirectory(at: duet, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        func write(_ dir: URL, _ id: String, _ prompt: String, age: TimeInterval) throws {
            let url = dir.appendingPathComponent("\(id).jsonl")
            let line = #"{"type":"user","cwd":"/Users/j/Duet","message":{"content":"\#(prompt)"},"uuid":"u"}"#
            try Data((line + "\n").utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        try write(duet, "old", "first", age: 3600)
        try write(duet, "new", "second", age: 60)
        try write(duet, "agent-x", "subagent", age: 1)
        try write(other, "elsewhere", "nope", age: 1)
        let list = SessionHistory.list(folders: ["/Users/j/Duet"], projectsDirectory: projects)
        #expect(list.map(\.id) == ["new", "old"])
    }

    @Test func findsShortenedFolderByCwd() throws {
        let fm = FileManager.default
        let projects = fm.temporaryDirectory.appendingPathComponent("tether-history-\(UUID().uuidString)")
        let dir = projects.appendingPathComponent("-Users-j-very-long-name-12ab")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = #"{"type":"user","cwd":"/Users/j/very/long/name","message":{"content":"hi"},"uuid":"u"}"#
        try Data((line + "\n").utf8).write(to: dir.appendingPathComponent("s.jsonl"))
        #expect(SessionHistory.list(folders: ["/Users/j/very/long/name"], projectsDirectory: projects).map(\.id) == ["s"])
    }
}
