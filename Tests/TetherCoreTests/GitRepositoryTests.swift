import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

private let gitAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")

/// A bare "remote" plus a clone with one commit on main, built with real git.
private struct Fixture {
    let root: URL
    let work: String
    let remote: String
    let runner: GitRunner

    static let environment = [
        "GIT_AUTHOR_NAME": "Tether Test", "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Tether Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        // Ignore the developer's own git config (signing, hooks, aliases).
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    ]

    static func make() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = GitRunner(environment: environment)
        let remote = root.appendingPathComponent("remote.git").path
        let work = root.appendingPathComponent("work").path
        _ = try await runner.run(["init", "-q", "--bare", "-b", "main", remote], in: root.path)
        _ = try await runner.run(["clone", "-q", remote, work], in: root.path)
        let fixture = Fixture(root: root, work: work, remote: remote, runner: runner)
        try fixture.write("a.txt", "one\ntwo\nthree\n")
        try fixture.write("keep.txt", "keep\n")
        try await fixture.git("checkout", "-q", "-B", "main")
        try await fixture.git("add", "-A")
        try await fixture.git("commit", "-q", "-m", "base")
        try await fixture.git("push", "-q", "-u", "origin", "main")
        return fixture
    }

    func write(_ name: String, _ content: String) throws {
        let url = URL(fileURLWithPath: work).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    @discardableResult
    func git(_ args: String..., in directory: String? = nil) async throws -> String {
        try await runner.run(args, in: directory ?? work).text
    }

    var repository: GitRepository { GitRepository(path: work, runner: runner) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.enabled(if: gitAvailable)) struct GitRepositoryTests {
    @Test func cleanCheckoutOfMainHasNothingToShow() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        let snapshot = try await f.repository.snapshot(baseBranch: "main")
        #expect(snapshot.branch == "main")
        #expect(snapshot.baseRef == "origin/main")
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.files.isEmpty && snapshot.commits.isEmpty && snapshot.isClean)
        #expect(snapshot.ahead == 0 && snapshot.behind == 0)
    }

    @Test func featureBranchShowsCommittedAndUncommittedChanges() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try await f.git("checkout", "-q", "-b", "feat/x")
        try f.write("a.txt", "one\nTWO\nthree\nfour\n")
        try f.write("n.txt", "new\n")
        try await f.git("add", "-A")
        try await f.git("commit", "-q", "-m", "feat: change")
        // Then, on top of the commit: another edit and an untracked file.
        try f.write("a.txt", "one\nTWO\nthree\nfour\nfive\n")
        try f.write("untracked.txt", "hello\n")

        let snapshot = try await f.repository.snapshot(baseBranch: "main")
        #expect(snapshot.branch == "feat/x")
        #expect(snapshot.baseRef == "origin/main")
        #expect(snapshot.commits.map(\.subject) == ["feat: change"])
        #expect(snapshot.files.map(\.path) == ["a.txt", "n.txt", "untracked.txt"])

        let a = snapshot.files[0]
        #expect(a.kind == .modified && a.additions == 3 && a.deletions == 1 && a.hasUncommittedChanges)
        let n = snapshot.files[1]
        #expect(n.kind == .added && n.additions == 1 && !n.hasUncommittedChanges)
        let u = snapshot.files[2]
        #expect(u.kind == .untracked && u.additions == 1 && u.hasUncommittedChanges)
        #expect(snapshot.additions == 5 && snapshot.deletions == 1)
    }

    @Test func renamesAreDetected() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try await f.git("checkout", "-q", "-b", "mv")
        try await f.git("mv", "keep.txt", "moved.txt")
        let snapshot = try await f.repository.snapshot(baseBranch: "main")
        #expect(snapshot.files.count == 1)
        #expect(snapshot.files[0].kind == .renamed)
        #expect(snapshot.files[0].path == "moved.txt" && snapshot.files[0].oldPath == "keep.txt")
    }

    @Test func fetchedCommitsOnTheBaseCountAsBehind() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        // Someone else pushes to main.
        let other = f.root.appendingPathComponent("other").path
        _ = try await f.runner.run(["clone", "-q", f.remote, other], in: f.root.path)
        try Data("r\n".utf8).write(to: URL(fileURLWithPath: other).appendingPathComponent("r.txt"))
        _ = try await f.runner.run(["add", "-A"], in: other)
        _ = try await f.runner.run(["commit", "-q", "-m", "remote work"], in: other)
        _ = try await f.runner.run(["push", "-q", "origin", "main"], in: other)

        #expect(try await f.repository.snapshot(baseBranch: "main").behind == 0)
        try await f.repository.fetch(baseBranch: "main")
        let after = try await f.repository.snapshot(baseBranch: "main")
        #expect(after.behind == 1)
        // Being behind is not a change of ours.
        #expect(after.files.isEmpty && after.commits.isEmpty)
    }

    @Test func fileDiffForTrackedAndUntrackedFiles() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try await f.git("checkout", "-q", "-b", "d")
        try f.write("a.txt", "one\nTWO\nthree\nfour\n")
        try f.write("fresh.txt", "x\ny")
        let snapshot = try await f.repository.snapshot(baseBranch: "main")

        let modified = try #require(snapshot.files.first { $0.path == "a.txt" })
        let diff = try await f.repository.fileDiff(modified, mergeBase: snapshot.mergeBase)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.contains(DiffLine(kind: .add, oldNumber: nil, newNumber: 2, text: "TWO")))
        #expect(diff.hunks[0].lines.contains(DiffLine(kind: .delete, oldNumber: 2, newNumber: nil, text: "two")))

        let fresh = try #require(snapshot.files.first { $0.path == "fresh.txt" })
        let freshDiff = try await f.repository.fileDiff(fresh, mergeBase: snapshot.mergeBase)
        #expect(freshDiff.kind == .untracked)
        #expect(freshDiff.hunks[0].lines.map(\.text) == ["x", "y"])
        #expect(freshDiff.hunks[0].lines[1].noNewlineAtEnd)
    }

    @Test func repositoryWithoutAnOriginShowsUncommittedChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = GitRunner(environment: Fixture.environment)
        _ = try await runner.run(["init", "-q", "-b", "main"], in: root.path)
        try Data("1\n".utf8).write(to: root.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"], in: root.path)
        _ = try await runner.run(["commit", "-q", "-m", "init"], in: root.path)
        try Data("1\n2\n".utf8).write(to: root.appendingPathComponent("f.txt"))

        let snapshot = try await GitRepository(path: root.path, runner: runner).snapshot(baseBranch: "main")
        #expect(snapshot.baseRef == nil)
        #expect(snapshot.mergeBase != nil)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.files.map(\.path) == ["f.txt"])
        #expect(snapshot.files[0].additions == 1)
    }

    @Test func repositoryWithNoCommitsListsUntrackedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = GitRunner(environment: Fixture.environment)
        _ = try await runner.run(["init", "-q", "-b", "main"], in: root.path)
        try Data("hi\n".utf8).write(to: root.appendingPathComponent("f.txt"))

        let snapshot = try await GitRepository(path: root.path, runner: runner).snapshot(baseBranch: "main")
        #expect(snapshot.branch == "main" && snapshot.commitShort == nil && snapshot.mergeBase == nil)
        #expect(snapshot.files.map(\.path) == ["f.txt"] && snapshot.files[0].kind == .untracked)
        #expect(snapshot.branchLabel == "main")
    }

    @Test func aFolderThatIsNotARepositoryThrowsAClearError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-plain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep git from finding a repository in a parent of the temp folder.
        let runner = GitRunner(environment: Fixture.environment.merging(
            ["GIT_CEILING_DIRECTORIES": root.deletingLastPathComponent().path]) { _, new in new })
        do {
            _ = try await GitRepository(path: root.path, runner: runner).snapshot(baseBranch: "main")
            Issue.record("expected an error")
        } catch let error as GitError {
            #expect(error == .notARepository)
        }
    }

    @Test func missingFolderIsReportedNotCrashed() async {
        do {
            _ = try await GitRunner().run(["status"], in: "/nonexistent/\(UUID().uuidString)")
            Issue.record("expected an error")
        } catch let error as GitError {
            guard case .launchFailed = error else { Issue.record("wrong error \(error)"); return }
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
