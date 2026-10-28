import Foundation
import Testing
@testable import TetherCore

@Suite struct FileTreeTests {
    /// `git ls-files -z --cached --others --exclude-standard`, captured from
    /// git 2.43 in a repo with an unmerged file (listed once per stage).
    static let lsFiles = "src/b.ts\0.gitignore\0README.md\0src/a.ts\0src/lib/x.ts\0conflict.txt\0conflict.txt\0Docs/plan.md\0"

    @Test func parseDropsEmptyAndDuplicates() {
        let paths = FileTree.parseLsFiles(Data(Self.lsFiles.utf8))
        #expect(paths == ["src/b.ts", ".gitignore", "README.md", "src/a.ts", "src/lib/x.ts", "conflict.txt", "Docs/plan.md"])
    }

    @Test func foldersFirstThenFilesCaseInsensitive() {
        let tree = FileTree.build(paths: FileTree.parseLsFiles(Data(Self.lsFiles.utf8)))
        #expect(tree.map(\.name) == ["Docs", "src", ".gitignore", "conflict.txt", "README.md"])
        let src = tree[1]
        #expect(src.isDirectory && src.path == "src")
        #expect(src.children.map(\.path) == ["src/lib", "src/a.ts", "src/b.ts"])
        #expect(src.children[0].children.map(\.path) == ["src/lib/x.ts"])
    }

    @Test func rowsFollowExpandedFolders() {
        let tree = FileTree.build(paths: ["src/a.ts", "src/lib/x.ts", "z.txt"])
        #expect(FileTree.rows(tree, expanded: []).map(\.id) == ["src", "z.txt"])
        let open = FileTree.rows(tree, expanded: ["src"])
        #expect(open.map(\.id) == ["src", "src/lib", "src/a.ts", "z.txt"])
        #expect(open.map(\.depth) == [0, 1, 1, 0])
        #expect(FileTree.rows(tree, expanded: [], expandAll: true).count == 5)
    }

    @Test func filterKeepsMatchesAndTheirFolders() {
        let tree = FileTree.build(paths: ["src/a.ts", "src/lib/x.ts", "docs/plan.md", "z.txt"])
        let kept = FileTree.filter(tree, query: "LIB x")
        #expect(FileTree.rows(kept, expanded: [], expandAll: true).map(\.id) == ["src", "src/lib", "src/lib/x.ts"])
        #expect(FileTree.filter(tree, query: "  ") == tree)
        #expect(FileTree.filter(tree, query: "nothing").isEmpty)
    }

    @Test func walkSkipsHeavyFoldersOutsideGit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-files-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("node_modules/pkg/index.js"))
        try Data().write(to: root.appendingPathComponent("src/main.c"))
        try Data().write(to: root.appendingPathComponent("README"))
        #expect(Set(FileTree.walk(root.path, limit: 100)) == ["src/main.c", "README"])
    }
}
