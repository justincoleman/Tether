import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

/// Output captured from git 2.43 on real repositories. Diffs use raw strings
/// because they contain backslashes.
enum GitFixtures {
    static let statusFeature =
        "# branch.oid 51b0b5f8472cd0003d58932e866443bf255ced24\0# branch.head feat/x\0"
        + "1 .M N... 100644 100644 100644 c61fe5e2592c879fc3dbcb1f544455d4550eef70 c61fe5e2592c879fc3dbcb1f544455d4550eef70 a.txt\0"
        + "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 677273046bce3115f56c248238f3b83f77cfc239 blob.bin\0"
        + "1 .M N... 100644 100644 100644 aaa bbb dir/with space.txt\0"
        + "? untracked.txt\0? with space.txt\0"

    static let statusUpstream =
        "# branch.oid 5c52418b5e8f63416eb7f1696558dd36ef84c7d4\0# branch.head topic\0"
        + "# branch.upstream origin/main\0# branch.ab +1 -2\0"

    static let statusRename =
        "2 RM N... 100644 100644 100644 c9e9e05f445e6b772f19fea1449759b7458a446e c9e9e05f445e6b772f19fea1449759b7458a446e R100 moved.txt\0a.txt\0"

    static let statusConflict =
        "u AA N... 000000 100644 100644 100644 0000000000000000000000000000000000000000 950b81b7eee953d050aa05a641f8e056c85dd1bd b19a1e93bec1317dc6097229e12afaffbfa74dc2 conflict.txt\0"

    static let statusDetached = "# branch.oid c768584721653d90e5cf5da063d7ff6c423498b9\0# branch.head (detached)\0"
    static let statusUnborn = "# branch.oid (initial)\0# branch.head main\0? f.txt\0"

    static let nameStatus =
        "M\0a.txt\0M\0b.txt\0A\0blob.bin\0D\0d.txt\0A\0n.txt\0R069\0r.txt\0renamed.txt\0"
    static let numstat =
        "3\t1\ta.txt\01\t0\tb.txt\0-\t-\tblob.bin\00\t1\td.txt\01\t0\tn.txt\01\t1\t\0r.txt\0renamed.txt\0"

    static let modifiedDiff = #"""
diff --git a/a.txt b/a.txt
index c9e9e05..e68fa66 100644
--- a/a.txt
+++ b/a.txt
@@ -1,5 +1,5 @@
 one
-two
+TWO
 three
 four
 five
@@ -8,3 +8,5 @@ seven
 eight
 nine
 ten
+eleven
+twelve

"""#

    static let renameDiff = #"""
diff --git a/r.txt b/renamed.txt
similarity index 69%
rename from r.txt
rename to renamed.txt
index af95a0e..1d8b491 100644
--- a/r.txt
+++ b/renamed.txt
@@ -1,5 +1,5 @@
 old name file
 line2
-line3
+line3 changed
 line4
 line5

"""#

    static let deletedDiff = #"""
diff --git a/d.txt b/d.txt
deleted file mode 100644
index 286c5f5..0000000
--- a/d.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone

"""#

    static let binaryDiff = #"""
diff --git a/blob.bin b/blob.bin
new file mode 100644
index 0000000..6772730
Binary files /dev/null and b/blob.bin differ

"""#

    static let noNewlineDiff = #"""
diff --git a/nonl.txt b/nonl.txt
index 0a207c0..817f660 100644
--- a/nonl.txt
+++ b/nonl.txt
@@ -1,2 +1,2 @@
 a
-b
\ No newline at end of file
+c
\ No newline at end of file

"""#

    /// A deleted line whose text is "--- old" and an added "+++ new".
    static let lookalikeHeaders = #"""
diff --git a/t.txt b/t.txt
index 1111111..2222222 100644
--- a/t.txt
+++ b/t.txt
@@ -1,2 +1,2 @@
 keep
---- old
++++ new

"""#

    static let spacedNameDiff = "diff --git a/with space.txt b/with space.txt\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/with space.txt\t\n@@ -0,0 +1 @@\n+x\n"
}

@Suite struct GitStatusParserTests {
    private func parse(_ s: String) -> GitStatus { GitStatus.parse(Data(s.utf8)) }

    @Test func featureBranchEntries() {
        let status = parse(GitFixtures.statusFeature)
        #expect(status.oid == "51b0b5f8472cd0003d58932e866443bf255ced24")
        #expect(status.branch == "feat/x")
        #expect(status.upstream == nil)
        #expect(status.entries.map(\.path) == ["a.txt", "blob.bin", "dir/with space.txt", "untracked.txt", "with space.txt"])
        #expect(status.entries[0].staged == "." && status.entries[0].unstaged == "M")
        #expect(status.entries[1].staged == "A")
        #expect(status.entries[3].isUntracked)
    }

    @Test func upstreamAheadBehind() {
        let status = parse(GitFixtures.statusUpstream)
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 1 && status.behind == 2)
    }

    @Test func renameCarriesOriginalPath() {
        let status = parse(GitFixtures.statusRename)
        #expect(status.entries.count == 1)
        #expect(status.entries[0].path == "moved.txt")
        #expect(status.entries[0].originalPath == "a.txt")
        #expect(status.entries[0].approximateKind == .renamed)
    }

    @Test func conflictIsUnmerged() {
        let status = parse(GitFixtures.statusConflict)
        #expect(status.entries[0].isUnmerged)
        #expect(status.entries[0].approximateKind == .conflicted)
    }

    @Test func detachedAndUnborn() {
        let detached = parse(GitFixtures.statusDetached)
        #expect(detached.branch == nil && detached.isDetached && detached.oid != nil)
        let unborn = parse(GitFixtures.statusUnborn)
        #expect(unborn.oid == nil && unborn.branch == "main" && !unborn.isDetached)
        #expect(unborn.entries.map(\.path) == ["f.txt"])
    }

    @Test func emptyInputIsEmptyStatus() {
        #expect(GitStatus.parse(Data()).entries.isEmpty)
    }
}

@Suite struct GitDiffSummaryTests {
    @Test func nameStatusIncludingRename() {
        let entries = GitDiffSummary.parseNameStatus(Data(GitFixtures.nameStatus.utf8))
        #expect(entries.map(\.path) == ["a.txt", "b.txt", "blob.bin", "d.txt", "n.txt", "renamed.txt"])
        #expect(entries.map(\.kind) == [.modified, .modified, .added, .deleted, .added, .renamed])
        #expect(entries.last?.oldPath == "r.txt")
    }

    @Test func numstatBinaryAndRename() {
        let entries = GitDiffSummary.parseNumstat(Data(GitFixtures.numstat.utf8))
        #expect(entries.count == 6)
        #expect(entries[0] == .init(path: "a.txt", oldPath: nil, additions: 3, deletions: 1))
        #expect(entries[2].additions == nil && entries[2].deletions == nil) // binary
        #expect(entries[5] == .init(path: "renamed.txt", oldPath: "r.txt", additions: 1, deletions: 1))
    }
}

@Suite struct UnifiedDiffTests {
    @Test func twoHunksWithRealLineNumbers() throws {
        let files = UnifiedDiff.parse(GitFixtures.modifiedDiff)
        #expect(files.count == 1)
        let diff = files[0]
        #expect(diff.path == "a.txt" && diff.kind == .modified)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].header == "@@ -1,5 +1,5 @@")
        let first = diff.hunks[0].lines
        #expect(first[1] == DiffLine(kind: .delete, oldNumber: 2, newNumber: nil, text: "two"))
        #expect(first[2] == DiffLine(kind: .add, oldNumber: nil, newNumber: 2, text: "TWO"))
        #expect(first[3] == DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "three"))
        let second = diff.hunks[1].lines
        #expect(diff.hunks[1].newStart == 8 && diff.hunks[1].newCount == 5)
        #expect(second.last == DiffLine(kind: .add, oldNumber: nil, newNumber: 12, text: "twelve"))
        #expect(diff.additions == 3 && diff.deletions == 1)
    }

    @Test func renameUsesNewPath() {
        let diff = UnifiedDiff.parse(GitFixtures.renameDiff)[0]
        #expect(diff.kind == .renamed)
        #expect(diff.path == "renamed.txt" && diff.oldPath == "r.txt")
        #expect(diff.additions == 1 && diff.deletions == 1)
    }

    @Test func deletedFileKeepsItsPath() {
        let diff = UnifiedDiff.parse(GitFixtures.deletedDiff)[0]
        #expect(diff.kind == .deleted && diff.path == "d.txt")
        #expect(diff.hunks[0].lines == [DiffLine(kind: .delete, oldNumber: 1, newNumber: nil, text: "gone")])
    }

    @Test func binaryHasNoHunks() {
        let diff = UnifiedDiff.parse(GitFixtures.binaryDiff)[0]
        #expect(diff.isBinary && diff.hunks.isEmpty && diff.kind == .added && diff.path == "blob.bin")
    }

    @Test func noNewlineMarkerFlagsThePreviousLine() {
        let lines = UnifiedDiff.parse(GitFixtures.noNewlineDiff)[0].hunks[0].lines
        #expect(lines.count == 3)
        #expect(lines[1].kind == .delete && lines[1].noNewlineAtEnd)
        #expect(lines[2].kind == .add && lines[2].noNewlineAtEnd)
        #expect(!lines[0].noNewlineAtEnd)
    }

    @Test func contentThatLooksLikeAHeaderStaysContent() {
        let lines = UnifiedDiff.parse(GitFixtures.lookalikeHeaders)[0].hunks[0].lines
        #expect(lines.map(\.text) == ["keep", "--- old", "+++ new"])
        #expect(lines.map(\.kind) == [.context, .delete, .add])
    }

    @Test func tabAfterSpacedNameIsStripped() {
        let diff = UnifiedDiff.parse(GitFixtures.spacedNameDiff)[0]
        #expect(diff.path == "with space.txt" && diff.kind == .added)
    }

    @Test func severalFilesInOneDiff() {
        let files = UnifiedDiff.parse(GitFixtures.modifiedDiff + GitFixtures.deletedDiff)
        #expect(files.map(\.path) == ["a.txt", "d.txt"])
    }

    @Test func longDiffsAreTruncated() {
        var text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1,10 @@\n"
        for i in 1...10 { text += "+line \(i)\n" }
        let diff = UnifiedDiff.parse(text, maxLines: 4)[0]
        #expect(diff.truncated)
        #expect(diff.hunks[0].lines.count == 4)
    }

    @Test func hunkHeaderDefaultsCountsToOne() {
        let h = UnifiedDiff.parseHunkHeader("@@ -1 +1,2 @@ func f()")
        #expect(h?.oldStart == 1 && h?.oldCount == 1 && h?.newStart == 1 && h?.newCount == 2)
        #expect(UnifiedDiff.parseHunkHeader("@@@ -1 -1 +1 @@@") == nil)
    }

    @Test func gitQuotedNamesAreDecoded() {
        #expect(GitPath.unquote(#""caf\303\251.txt""#) == "café.txt")
        #expect(GitPath.unquote(#""tab\there""#) == "tab\there")
        #expect(GitPath.unquote("plain") == "plain")
    }
}

@Suite struct UntrackedDiffTests {
    @Test func everyLineIsAnAddition() {
        let diff = UntrackedDiff.make(path: "n.txt", data: Data("a\nb\n".utf8))
        #expect(diff.kind == .untracked)
        #expect(diff.hunks[0].header == "@@ -0,0 +1,2 @@")
        #expect(diff.hunks[0].lines.map(\.newNumber) == [1, 2])
        #expect(diff.hunks[0].lines.allSatisfy { !$0.noNewlineAtEnd })
    }

    @Test func missingFinalNewlineIsFlagged() {
        let lines = UntrackedDiff.make(path: "n.txt", data: Data("a\nb".utf8)).hunks[0].lines
        #expect(lines.map(\.text) == ["a", "b"])
        #expect(lines[1].noNewlineAtEnd && !lines[0].noNewlineAtEnd)
    }

    @Test func binaryAndEmptyFiles() {
        #expect(UntrackedDiff.make(path: "b", data: Data([0, 1, 2])).isBinary)
        #expect(UntrackedDiff.make(path: "e", data: Data()).hunks.isEmpty)
    }
}

@Suite struct GitLogParserTests {
    @Test func parsesRecordsWithBodyFreeSubjects() {
        let text = "abc123\u{1F}abc\u{1F}Ada L\u{1F}1793203979\u{1F}feat: change things\u{1E}\ndef456\u{1F}def\u{1F}Bo\u{1F}1793203000\u{1F}fix\u{1E}\n"
        let commits = GitRepository.parseLog(text)
        #expect(commits.map(\.shortHash) == ["abc", "def"])
        #expect(commits[0].subject == "feat: change things" && commits[0].author == "Ada L")
        #expect(commits[0].date == Date(timeIntervalSince1970: 1_793_203_979))
    }

    @Test func malformedRecordsAreSkipped() {
        #expect(GitRepository.parseLog("garbage\u{1E}").isEmpty)
    }
}

@Suite struct GitEventFilterTests {
    let root = "/Users/j/code/Tether"

    @Test func sourceChangesAreRelevant() {
        #expect(GitEventFilter.isRelevant(eventPath: root + "/Sources/A.swift", root: root))
        #expect(GitEventFilter.isRelevant(eventPath: root + "/README.md", root: root))
    }

    @Test func buildOutputAndJunkAreNot() {
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/build/mac/x.o", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/.build/debug/y", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/web/node_modules/z/index.js", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/.DS_Store", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/build", root: root))
    }

    @Test func gitInternalsOnlyWhenBranchOrIndexMove() {
        #expect(GitEventFilter.isRelevant(eventPath: root + "/.git/HEAD", root: root))
        #expect(GitEventFilter.isRelevant(eventPath: root + "/.git/index", root: root))
        #expect(GitEventFilter.isRelevant(eventPath: root + "/.git/refs/remotes/origin/main", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/.git/index.lock", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/.git/objects/ab/cdef", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/.git/FETCH_HEAD", root: root))
        #expect(!GitEventFilter.isRelevant(eventPath: root + "/.git/logs/HEAD", root: root))
    }
}
