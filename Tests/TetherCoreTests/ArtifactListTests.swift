import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

/// The Artifact tool's result text is synthetic: the docs give the tool name and
/// the `claude.ai/code/artifact/<uuid>` link but not the result shape.
@Suite struct ArtifactListTests {
    private func publish(_ id: String, time: String, file: String?, result: String) -> [String] {
        let input = file.map { #"{"file_path":"\#($0)"}"# } ?? #"{"url":"https://claude.ai/code/artifact/5fbea6f3-1111"}"#
        return [
            #"{"type":"assistant","uuid":"a-\#(id)","isSidechain":false,"timestamp":"2026-10-30T10:\#(time).000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_\#(id)","name":"Artifact","input":\#(input)}]}}"#,
            #"{"type":"user","uuid":"u-\#(id)","isSidechain":false,"timestamp":"2026-10-30T10:\#(time).500Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_\#(id)","content":"\#(result)"}]}}"#,
        ]
    }

    private func model(_ lines: [String]) -> TranscriptModel {
        var model = TranscriptModel()
        for line in lines { model.apply(TranscriptParser.events(fromLine: line)) }
        return model
    }

    @Test func findsThePublishedLinkAndNamesItFromTheFile() throws {
        let m = model(publish("1", time: "00:01", file: "/tmp/q3-dashboard.html",
                              result: "Published https://claude.ai/code/artifact/5fbea6f3-1111."))
        let list = ArtifactList.published(in: m.items)
        let first = try #require(list.first)
        #expect(list.count == 1)
        #expect(first.url.absoluteString == "https://claude.ai/code/artifact/5fbea6f3-1111")
        #expect(first.title == "q3 dashboard")
        #expect(first.versions == 1)
    }

    @Test func anUpdateToTheSameLinkCountsAsAVersion() throws {
        let m = model(publish("1", time: "00:01", file: "/tmp/page.html",
                              result: "https://claude.ai/code/artifact/5fbea6f3-1111")
                      + publish("2", time: "00:05", file: nil,
                                result: "Updated https://claude.ai/code/artifact/5fbea6f3-1111"))
        let list = ArtifactList.published(in: m.items)
        #expect(list.count == 1)
        #expect(list[0].versions == 2)
        #expect(list[0].title == "page")
    }

    @Test func newestFirstAndStepsWithoutALinkAreSkipped() {
        let m = model(publish("1", time: "00:01", file: "/tmp/a.html", result: "https://claude.ai/code/artifact/aaaa-1")
                      + publish("2", time: "00:09", file: "/tmp/b.html", result: "https://claude.ai/code/artifact/bbbb-2")
                      + publish("3", time: "00:10", file: "/tmp/c.html", result: "Could not publish"))
        #expect(ArtifactList.published(in: m.items).map(\.title) == ["b", "a"])
    }
}
