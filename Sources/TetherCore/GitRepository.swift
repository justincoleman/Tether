import Foundation
import TetherProtocol

/// Reads one worktree's state from git. Everything here only reads, apart
/// from `fetch`, which updates remote-tracking refs.
public struct GitRepository: Sendable {
    public let path: String
    public let runner: GitRunner

    public init(path: String, runner: GitRunner = GitRunner()) {
        self.path = path
        self.runner = runner
    }

    // MARK: Snapshot

    /// Files changed and commits made since this branch left `baseBranch`.
    ///
    /// Files are compared against the merge base, not the tip of the base
    /// branch, so commits that landed on the base after this branch started do
    /// not show up as reversed changes.
    public func snapshot(baseBranch: String) async throws -> ChangesSnapshot {
        let statusOutput = try await runner.run(
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: path)
        let status = GitStatus.parse(statusOutput.stdout)
        let uncommitted = Set(status.entries.map(\.path))

        var baseRef: String?
        var mergeBase: String?
        if let oid = status.oid {
            if let base = await resolveBase(baseBranch: baseBranch, currentBranch: status.branch) {
                baseRef = base.ref
                mergeBase = base.mergeBase
            } else {
                mergeBase = oid // no base branch: show only uncommitted changes
            }
        }

        var byPath: [String: ChangedFile] = [:]
        var commits: [CommitInfo] = []

        if let mergeBase {
            async let nameStatus = runner.run(
                ["diff", "--name-status", "-z", "-M", "--no-ext-diff", mergeBase, "--"], in: path)
            async let numstat = runner.run(
                ["diff", "--numstat", "-z", "-M", "--no-ext-diff", mergeBase, "--"], in: path)
            let (names, counts) = try await (nameStatus, numstat)

            for entry in GitDiffSummary.parseNameStatus(names.stdout) {
                byPath[entry.path] = ChangedFile(path: entry.path, oldPath: entry.oldPath, kind: entry.kind,
                                                 hasUncommittedChanges: uncommitted.contains(entry.path))
            }
            for count in GitDiffSummary.parseNumstat(counts.stdout) {
                guard var file = byPath[count.path] else { continue }
                file.additions = count.additions
                file.deletions = count.deletions
                file.isBinary = count.additions == nil
                byPath[count.path] = file
            }
            if baseRef != nil {
                commits = (try? await loadCommits(since: mergeBase)) ?? []
            }
        }

        var untrackedCounted = 0
        for entry in status.entries {
            if entry.isUnmerged {
                byPath[entry.path] = ChangedFile(path: entry.path, kind: .conflicted, hasUncommittedChanges: true)
            } else if entry.isUntracked {
                var file = ChangedFile(path: entry.path, kind: .untracked, hasUncommittedChanges: true)
                if untrackedCounted < 200 {
                    untrackedCounted += 1
                    if let counts = countLines(ofUntracked: entry.path) {
                        file.additions = counts.lines
                        file.isBinary = counts.isBinary
                    }
                }
                byPath[entry.path] = file
            } else if mergeBase == nil {
                // No commits yet, so there is nothing to diff against.
                byPath[entry.path] = ChangedFile(
                    path: entry.path, oldPath: entry.originalPath,
                    kind: entry.approximateKind, hasUncommittedChanges: true)
            }
        }

        let files = byPath.values
            .sorted { $0.path.lowercased() < $1.path.lowercased() }
        return ChangesSnapshot(
            branch: status.branch,
            commitShort: status.oid.map { String($0.prefix(7)) },
            upstream: status.upstream,
            ahead: status.ahead,
            behind: status.behind,
            baseRef: baseRef,
            mergeBase: mergeBase,
            files: Array(files.prefix(1000)),
            commits: commits)
    }

    /// The first of origin/<base>, origin's default branch, or the local base
    /// branch that shares history with HEAD.
    func resolveBase(baseBranch: String, currentBranch: String?) async -> (ref: String, mergeBase: String)? {
        var candidates = ["origin/\(baseBranch)"]
        if let head = try? await runner.run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
                                            in: path, allowedExitCodes: [0, 1]),
           head.status == 0 {
            let target = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if target.hasPrefix("refs/remotes/") {
                candidates.append(String(target.dropFirst("refs/remotes/".count)))
            }
        }
        if currentBranch != baseBranch { candidates.append(baseBranch) }

        var seen = Set<String>()
        for ref in candidates where seen.insert(ref).inserted {
            guard let result = try? await runner.run(["merge-base", "HEAD", ref], in: path),
                  case let sha = result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sha.isEmpty else { continue }
            return (ref, sha)
        }
        return nil
    }

    func loadCommits(since mergeBase: String) async throws -> [CommitInfo] {
        let output = try await runner.run(
            ["log", "-n", "50", "--format=%H%x1f%h%x1f%an%x1f%at%x1f%s%x1e", "\(mergeBase)..HEAD", "--"],
            in: path)
        return Self.parseLog(output.text)
    }

    static func parseLog(_ text: String) -> [CommitInfo] {
        text.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { record in
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let timestamp = TimeInterval(parts[3]) else { return nil }
            return CommitInfo(hash: String(parts[0]), shortHash: String(parts[1]), author: String(parts[2]),
                              date: Date(timeIntervalSince1970: timestamp), subject: String(parts[4]))
        }
    }

    // MARK: Diffs

    /// The diff for one file against the merge base. Untracked files, which git
    /// does not diff, are shown as all additions.
    public func fileDiff(_ file: ChangedFile, mergeBase: String?, maxLines: Int = 5000) async throws -> FileDiff {
        if file.kind == .untracked || mergeBase == nil {
            return untrackedDiff(for: file, maxLines: maxLines)
        }
        guard let mergeBase else { return FileDiff(path: file.path) }
        if file.kind == .conflicted {
            return FileDiff(path: file.path, kind: .conflicted)
        }
        var arguments = ["diff", "-M", "--no-ext-diff", "--no-color", "--unified=3", mergeBase, "--"]
        if let old = file.oldPath { arguments.append(old) }
        arguments.append(file.path)
        let output = try await runner.run(arguments, in: path)
        let diffs = UnifiedDiff.parse(output.text, maxLines: maxLines)
        var diff = diffs.first { $0.path == file.path } ?? diffs.first ?? FileDiff(path: file.path, kind: file.kind)
        diff.kind = file.kind
        diff.oldPath = file.oldPath
        return diff
    }

    private func untrackedDiff(for file: ChangedFile, maxLines: Int) -> FileDiff {
        let url = URL(fileURLWithPath: path).appendingPathComponent(file.path)
        let size = TranscriptTail.fileSize(url.path) ?? 0
        if size > UInt64(UntrackedDiff.maxBytes) {
            return FileDiff(path: file.path, kind: file.kind, truncated: true)
        }
        guard let data = try? Data(contentsOf: url) else {
            return FileDiff(path: file.path, kind: file.kind)
        }
        var diff = UntrackedDiff.make(path: file.path, data: data, maxLines: maxLines)
        diff.kind = file.kind
        return diff
    }

    private func countLines(ofUntracked relativePath: String) -> (lines: Int, isBinary: Bool)? {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relativePath)
        let size = TranscriptTail.fileSize(url.path) ?? 0
        guard size <= UInt64(UntrackedDiff.maxBytes), let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8000).contains(0) { return (0, true) }
        if data.isEmpty { return (0, false) }
        let newlines = data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        return (data.last == 10 ? newlines : newlines + 1, false)
    }

    // MARK: Fetch

    /// Updates `origin/<baseBranch>`. Bounded in time, and told never to prompt
    /// for credentials, so a missing key fails fast instead of hanging.
    public func fetch(baseBranch: String) async throws {
        var runner = self.runner
        if ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil,
           runner.environment["GIT_SSH_COMMAND"] == nil {
            runner.environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        _ = try await runner.run(["fetch", "--quiet", "origin", baseBranch], in: path, timeout: 45)
    }
}
