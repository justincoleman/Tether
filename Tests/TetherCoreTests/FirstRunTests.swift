import Foundation
import Testing
@testable import TetherCore

@Suite struct FirstRunTests {
    /// A projects directory with one transcript per (encoded name, cwd, age in seconds).
    func makeProjects(_ entries: [(name: String, cwd: String, age: TimeInterval, files: Int)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("firstrun-\(UUID().uuidString)")
        for entry in entries {
            let dir = root.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<entry.files {
                let file = dir.appendingPathComponent("s\(i).jsonl")
                let line = "{\"type\":\"user\",\"cwd\":\"\(entry.cwd)\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n"
                try line.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -entry.age)],
                                                      ofItemAtPath: file.path)
            }
        }
        return root
    }

    @Test func listsFoldersNewestFirstWithTheirRealPaths() throws {
        let root = try makeProjects([
            (name: "-Users-j-my-app", cwd: "/Users/j/my-app", age: 7200, files: 3),
            (name: "-Users-j-Duet", cwd: "/Users/j/Duet", age: 60, files: 1),
        ])
        let folders = SessionHistory.recentFolders(projectsDirectory: root, home: "/Users/j", folderExists: { _ in true })
        #expect(folders.map(\.path) == ["/Users/j/Duet", "/Users/j/my-app"])
        #expect(folders.map(\.name) == ["Duet", "my-app"])
        #expect(folders[1].sessions == 3)
    }

    @Test func skipsHomeWorktreesClaudeFoldersAndMissingFolders() throws {
        let root = try makeProjects([
            (name: "-Users-j", cwd: "/Users/j", age: 10, files: 1),
            (name: "-wt", cwd: "/Users/j/Library/Application Support/Tether/Worktrees/Duet/fix", age: 10, files: 1),
            (name: "-claude", cwd: "/Users/j/.claude/plugins", age: 10, files: 1),
            (name: "-gone", cwd: "/Users/j/deleted", age: 10, files: 1),
            (name: "-kept", cwd: "/Users/j/kept", age: 10, files: 1),
        ])
        let folders = SessionHistory.recentFolders(projectsDirectory: root, home: "/Users/j",
                                                   folderExists: { $0 != "/Users/j/deleted" })
        #expect(folders.map(\.path) == ["/Users/j/kept"])
    }

    @Test func mergesDirectoriesThatNameOneFolderAndHonoursTheLimit() throws {
        let root = try makeProjects([
            (name: "-a", cwd: "/p/a", age: 100, files: 2),
            (name: "-a-", cwd: "/p/a", age: 50, files: 1),
            (name: "-b", cwd: "/p/b", age: 200, files: 1),
            (name: "-c", cwd: "/p/c", age: 300, files: 1),
        ])
        let all = SessionHistory.recentFolders(projectsDirectory: root, home: "/h", folderExists: { _ in true })
        #expect(all.map(\.path) == ["/p/a", "/p/b", "/p/c"])
        #expect(all[0].sessions == 3)
        let two = SessionHistory.recentFolders(projectsDirectory: root, home: "/h", limit: 2, folderExists: { _ in true })
        #expect(two.count == 2)
    }

    @Test func missingProjectsDirectoryIsEmpty() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(SessionHistory.recentFolders(projectsDirectory: nowhere).isEmpty)
    }

    @Test func probeParsesThePathAndIgnoresBannersAndAliases() {
        #expect(ToolProbe.parse("/opt/homebrew/bin/claude\n") == "/opt/homebrew/bin/claude")
        #expect(ToolProbe.parse("Welcome back\n/usr/local/bin/git\n") == "/usr/local/bin/git")
        #expect(ToolProbe.parse("claude\n") == nil)
        #expect(ToolProbe.parse("") == nil)
    }

    @Test func probeFindsARealToolAndNotAMissingOne() async {
        let found = await ToolProbe.resolve("sh", shell: "/bin/sh")
        #expect(found?.hasSuffix("/sh") == true)
        let missing = await ToolProbe.resolve("tether-no-such-tool-xyz", shell: "/bin/sh")
        #expect(missing == nil)
    }
}
