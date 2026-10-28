import Foundation
import TetherProtocol

/// "New Agent on a Branch": a git worktree on a new branch, so a second
/// Claude can work without touching the main checkout.
///
/// Worktrees live under `root/<repo>/<branch-slug>` (by default in Tether's
/// Application Support folder), and the branch starts from the freshest base
/// available: `origin/<base>`, else the local `<base>`, else `HEAD`.
public struct WorktreeCreator: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidBranch(String)
        case branchExists(String)
        case dirty
        case git(String)

        public var description: String {
            switch self {
            case .invalidBranch(let b): return "“\(b)” isn't a valid branch name."
            case .branchExists(let b): return "A branch named “\(b)” already exists."
            case .dirty: return "The worktree has uncommitted changes."
            case .git(let message): return message
            }
        }
    }

    public let root: URL
    public let runner: GitRunner

    public init(root: URL = WorktreeCreator.defaultRoot(), runner: GitRunner = GitRunner()) {
        self.root = root
        self.runner = runner
    }

    public static func defaultRoot() -> URL {
        ProjectStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("Worktrees")
    }

    /// Creates the branch and worktree; returns the worktree's path.
    public func create(repoPath: String, branch rawBranch: String, baseBranch: String) async throws -> String {
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidBranchName(branch) else { throw Failure.invalidBranch(branch) }
        if (try? await runner.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoPath)) != nil {
            throw Failure.branchExists(branch)
        }
        let start = await startPoint(repoPath: repoPath, baseBranch: baseBranch)
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
        var path = root.appendingPathComponent(repoName).appendingPathComponent(Self.slug(branch)).path
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = root.appendingPathComponent(repoName).appendingPathComponent("\(Self.slug(branch))-\(n)").path
            n += 1
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            _ = try await runner.run(["worktree", "add", "-b", branch, path, start], in: repoPath, timeout: 120)
        } catch let error as GitError {
            throw Failure.git(error.description)
        }
        return path
    }

    public struct Removal: Equatable, Sendable {
        /// False when git refused `branch -d` because the branch has unmerged
        /// commits; the branch is kept so no work is lost.
        public var branchDeleted: Bool
    }

    /// Removes a worktree Tether created and, if fully merged, its branch.
    /// Without `force`, a worktree with uncommitted changes is refused with
    /// `.dirty` so nothing is lost by accident.
    public func remove(repoPath: String, worktreePath: String, branch: String, force: Bool) async throws -> Removal {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        do {
            _ = try await runner.run(args, in: repoPath, timeout: 120)
        } catch let error as GitError {
            if case .failed(_, _, let stderr) = error,
               stderr.contains("modified or untracked files") || stderr.contains("use --force") {
                throw Failure.dirty
            }
            // Already gone from disk: prune the stale registration and carry on.
            guard !FileManager.default.fileExists(atPath: worktreePath) else { throw Failure.git(error.description) }
            _ = try? await runner.run(["worktree", "prune"], in: repoPath)
        }
        let deleted = (try? await runner.run(["branch", "-d", branch], in: repoPath)) != nil
        return Removal(branchDeleted: deleted)
    }

    func startPoint(repoPath: String, baseBranch: String) async -> String {
        for candidate in ["origin/\(baseBranch)", baseBranch] {
            if (try? await runner.run(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: repoPath)) != nil {
                return candidate
            }
        }
        return "HEAD"
    }

    /// The common cases of `git check-ref-format --branch`, checked up front
    /// so the phone gets a clear message instead of git's.
    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), name != "@",
              !name.contains(".."), !name.contains("//"), !name.contains("@{")
        else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        guard name.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }
        return !name.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// `feature/login` → `feature-login`, for the folder name.
    public static func slug(_ branch: String) -> String {
        let mapped = branch.lowercased().map { c -> Character in
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." ? c : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "branch" : collapsed
    }
}
