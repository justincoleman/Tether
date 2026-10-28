import Foundation
import Testing
@testable import TetherCore

@Suite struct ReleaseNotesTests {
    func note(_ v: String) -> ReleaseNote {
        ReleaseNote(version: v, date: "2026-10-28", summary: "s", highlights: [])
    }

    @Test func versionsCompareNumerically() {
        #expect(SemanticVersion("0.10.0")! > SemanticVersion("0.9.0")!)
        #expect(SemanticVersion("1.0")! == SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("1.0")!.hashValue == SemanticVersion("1.0.0")!.hashValue)
        #expect(SemanticVersion("1.2.3")! < SemanticVersion("1.3")!)
        #expect(SemanticVersion("dev") == nil)
        #expect(SemanticVersion("1..2") == nil)
    }

    @Test func parseSortsNewestFirstAndDropsBadVersions() throws {
        let json = #"[{"version":"0.9.0","date":"d","summary":"s","highlights":[]},{"version":"x","date":"d","summary":"s","highlights":[]},{"version":"0.10.0","date":"d","summary":"s","highlights":[]}]"#
        #expect(try ReleaseNotes.parse(Data(json.utf8)).map(\.version) == ["0.10.0", "0.9.0"])
    }

    @Test func unseenRules() {
        let notes = ["0.3.0", "0.2.0", "0.1.0"].map(note)
        // First launch: only the current release.
        #expect(ReleaseNotes.unseen(notes, lastSeen: nil, current: "0.3.0").map(\.version) == ["0.3.0"])
        // Two versions behind.
        #expect(ReleaseNotes.unseen(notes, lastSeen: "0.1.0", current: "0.3.0").map(\.version) == ["0.3.0", "0.2.0"])
        // Up to date, or downgraded.
        #expect(ReleaseNotes.unseen(notes, lastSeen: "0.3.0", current: "0.3.0").isEmpty)
        #expect(ReleaseNotes.unseen(notes, lastSeen: "0.3.0", current: "0.2.0").isEmpty)
        // Notes for a version newer than the running app aren't announced.
        #expect(ReleaseNotes.unseen(notes, lastSeen: "0.1.0", current: "0.2.0").map(\.version) == ["0.2.0"])
        // An unreadable running version announces nothing.
        #expect(ReleaseNotes.unseen(notes, lastSeen: nil, current: "dev").isEmpty)
    }

    /// The shipped notes file must describe the version being built, so a
    /// release can't go out without its What's New entry.
    @Test func bundledNotesMatchMarketingVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let notes = try ReleaseNotes.parse(Data(contentsOf: root.appendingPathComponent("Apps/Tether/Resources/ReleaseNotes.json")))
        let yml = try String(contentsOf: root.appendingPathComponent("Apps/project.yml"), encoding: .utf8)
        let line = try #require(yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") })
        let version = line.split(separator: ":", maxSplits: 1)[1]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        #expect(notes.first?.version == version)
        #expect(notes.allSatisfy { !$0.highlights.isEmpty })
    }
}
