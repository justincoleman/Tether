import Dispatch
import Foundation
import TetherProtocol

/// A branch's pull request and its checks, from `gh pr view --json`.
public struct PullRequestStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    /// The checks taken together: any failure wins, then anything still running.
    public enum Checks: String, Codable, Hashable, Sendable {
        case none, pending, passing, failing
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State
    public var isDraft: Bool
    public var passed: Int
    public var failed: Int
    public var pending: Int
    /// Names of the failing checks, for the tooltip.
    public var failedNames: [String]
    /// Exact revision returned by GitHub, used to guard mutations.
    public var headRevision: String

    public init(number: Int, title: String, url: String, state: State, isDraft: Bool,
                passed: Int, failed: Int, pending: Int, failedNames: [String], headRevision: String = "") {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.failedNames = failedNames
        self.headRevision = headRevision
    }

    public var checks: Checks {
        if failed > 0 { return .failing }
        if pending > 0 { return .pending }
        return passed > 0 ? .passing : .none
    }

    /// "2 passed, 1 failed (lint)".
    public var checksSummary: String {
        var parts: [String] = []
        if passed > 0 { parts.append("\(passed) passed") }
        if failed > 0 { parts.append("\(failed) failed (\(failedNames.joined(separator: ", ")))") }
        if pending > 0 { parts.append("\(pending) running") }
        return parts.isEmpty ? "No checks" : parts.joined(separator: ", ")
    }
}

public enum PullRequestParser {
    /// Fields asked of `gh pr view --json`.
    public static let fields = "number,title,url,state,isDraft,statusCheckRollup,headRefOid"

    private struct Raw: Decodable {
        var number: Int
        var title: String
        var url: String
        var state: String
        var isDraft: Bool?
        var headRefOid: String?
        var statusCheckRollup: [RawCheck]?
    }

    /// A `CheckRun` (Actions and other apps) has status and conclusion; a
    /// `StatusContext` (the older commit status API) has context and state.
    private struct RawCheck: Decodable {
        var name: String?
        var context: String?
        var status: String?
        var conclusion: String?
        var state: String?
    }

    private enum Outcome { case passed, failed, pending }

    public static func parse(_ data: Data) throws -> PullRequestStatus {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var passed = 0, failed = 0, pending = 0
        var failedNames: [String] = []
        for check in raw.statusCheckRollup ?? [] {
            switch outcome(of: check) {
            case .passed: passed += 1
            case .pending: pending += 1
            case .failed:
                failed += 1
                failedNames.append(check.name ?? check.context ?? "check")
            }
        }
        return PullRequestStatus(number: raw.number, title: raw.title, url: raw.url,
                                 state: PullRequestStatus.State(rawValue: raw.state) ?? .open,
                                 isDraft: raw.isDraft ?? false,
                                 passed: passed, failed: failed, pending: pending, failedNames: failedNames,
                                 headRevision: raw.headRefOid ?? "")
    }

    private static func outcome(of check: RawCheck) -> Outcome {
        if let state = check.state {
            switch state {
            case "SUCCESS": return .passed
            case "PENDING", "EXPECTED": return .pending
            default: return .failed // FAILURE, ERROR
            }
        }
        guard check.status == "COMPLETED" else { return .pending }
        switch check.conclusion {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return .passed
        case nil, "": return .pending
        default: return .failed // FAILURE, TIMED_OUT, CANCELLED, ACTION_REQUIRED, STARTUP_FAILURE, STALE
        }
    }

    /// `gh pr view` exits 1 with this when the branch has no pull request.
    public static func isNoPullRequest(_ stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("no pull requests found")
    }
}

/// Runs the GitHub CLI, which is optional: without it, or signed out, there
/// is simply no pull request status.
public struct GitHubCLI: Sendable {
    public var path: String
    public var timeout: TimeInterval
    public var environment: [String: String]
    public var gitPath: String

    public init(path: String, timeout: TimeInterval = 20, environment: [String: String] = [:], gitPath: String = "git") {
        self.path = path
        self.timeout = timeout
        self.environment = environment
        self.gitPath = gitPath
    }

    /// Apps opened from the Dock don't get the login shell's PATH, so look
    /// where Homebrew and the installer put `gh`.
    public static func locate(candidates: [String] = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]) -> GitHubCLI? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { GitHubCLI(path: $0) }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case failed(String)

        public var description: String {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    /// The pull request for `branch`, run in its worktree so `gh` picks the
    /// repository from its remotes. Nil when the branch has none.
    public func pullRequest(branch: String, in directory: String) async throws -> PullRequestStatus? {
        let args = ["pr", "view", branch, "--json", PullRequestParser.fields]
        let output = try await run(executable: path, arguments: args, in: directory, allowedExitCodes: [0, 1])
        if output.status != 0 {
            if PullRequestParser.isNoPullRequest(output.stderr) { return nil }
            let line = output.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(output.status)"
            throw Failure.failed("gh: \(line)")
        }
        return try PullRequestParser.parse(output.stdout)
    }

    /// Explicit user actions only. Branch publication is intentionally left to
    /// the user's git workflow; this method never pushes a local branch.
    public func perform(_ action: PullRequestAction, branch: String, expectedBase: String,
                        in directory: String) async throws -> String {
        guard !branch.isEmpty, !expectedBase.isEmpty, !branch.hasPrefix("-"),
              !expectedBase.hasPrefix("-"), branch != expectedBase else {
            throw Failure.failed("Choose a feature branch, separate from the pull request base.")
        }
        if case .create(let title, let body) = action {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.failed("Enter a pull request title and description.")
            }
        }
        let expectedHead: String?
        switch action {
        case .create: expectedHead = nil
        case .merge(let head), .rerunChecks(let head):
            guard !head.isEmpty, head.allSatisfy({ $0.isHexDigit }) else {
                throw Failure.failed("Refresh the pull request before continuing.")
            }
            expectedHead = head
        }
        try await validateLocal(branch: branch, head: expectedHead, in: directory)
        switch action {
        case .create(let title, let body):
            do {
                return try await checkedGH(["pr", "create", "--base", expectedBase, "--head", branch,
                                            "--title", title, "--body", body], in: directory)
            } catch {
                throw Failure.failed("\(error) Publish this branch with your git workflow if it is not on GitHub, then retry.")
            }
        case .merge(let head):
            let pr = try await validateRemote(branch: branch, base: expectedBase, head: head, in: directory)
            try await validateLocal(branch: branch, head: head, in: directory)
            return try await checkedGH(["pr", "merge", String(pr.number), "--squash", "--match-head-commit", head], in: directory)
        case .rerunChecks(let head):
            _ = try await validateRemote(branch: branch, base: expectedBase, head: head, in: directory)
            let raw = try await run(executable: path, arguments: ["run", "list", "--branch", branch,
                "--commit", head, "--status", "failure", "--limit", "50", "--json", "databaseId"], in: directory)
            struct Run: Decodable { var databaseId: Int }
            let runs = try JSONDecoder().decode([Run].self, from: raw.stdout)
            guard !runs.isEmpty else { throw Failure.failed("No failed GitHub Actions runs for this revision.") }
            guard runs.count <= 50, runs.allSatisfy({ $0.databaseId > 0 }) else {
                throw Failure.failed("GitHub returned an invalid set of failed Actions runs.")
            }
            _ = try await validateRemote(branch: branch, base: expectedBase, head: head, in: directory)
            try await validateLocal(branch: branch, head: head, in: directory)
            for id in Set(runs.map(\.databaseId)).sorted() {
                _ = try await checkedGH(["run", "rerun", String(id), "--failed"], in: directory)
            }
            return "Requested rerun of \(runs.count) failed GitHub Actions run(s)."
        }
    }

    private struct FreshPullRequest: Decodable {
        var number: Int
        var state: String
        var headRefName: String
        var baseRefName: String
        var headRefOid: String
    }

    private func validateRemote(branch: String, base: String, head: String, in directory: String) async throws -> FreshPullRequest {
        let output = try await run(executable: path, arguments: ["pr", "view", branch, "--json",
            "number,state,headRefName,baseRefName,headRefOid"], in: directory)
        let pr = try JSONDecoder().decode(FreshPullRequest.self, from: output.stdout)
        guard pr.number > 0, pr.state == "OPEN", pr.headRefName == branch,
              pr.baseRefName == base, pr.headRefOid == head else {
            throw Failure.failed("The pull request changed. Refresh it and review its current branch, base and revision.")
        }
        return pr
    }

    private func validateLocal(branch: String, head: String?, in directory: String) async throws {
        let current = try await run(executable: gitPath, arguments: ["branch", "--show-current"], in: directory)
        let revision = try await run(executable: gitPath, arguments: ["rev-parse", "HEAD"], in: directory)
        guard current.text.trimmingCharacters(in: .whitespacesAndNewlines) == branch,
              !revision.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              head == nil || revision.text.trimmingCharacters(in: .whitespacesAndNewlines) == head else {
            throw Failure.failed("The local branch or revision changed. Refresh before continuing.")
        }
    }

    private func checkedGH(_ arguments: [String], in directory: String) async throws -> String {
        let output = try await run(executable: path, arguments: arguments, in: directory)
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(executable: String, arguments: [String], in directory: String,
                     allowedExitCodes: Set<Int32> = [0]) async throws -> GitOutput {
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        let environment = env
        let limit = timeout
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try GitRunner.runBlocking(executable: executable, arguments: arguments, directory: directory,
                                              environment: environment, timeout: limit, allowedExitCodes: allowedExitCodes)
                })
            }
        }
    }

}

/// How often to ask GitHub about a branch's pull request.
public enum PullRequestPolicy {
    /// Running checks are worth watching closely; a finished pull request
    /// barely changes. Everything slows down when Tether is in the background
    /// and again in Low Power Mode.
    public static func interval(for status: PullRequestStatus?, appActive: Bool, lowPower: Bool) -> TimeInterval {
        var seconds: TimeInterval
        switch (status?.state, status?.checks) {
        case (.merged?, _), (.closed?, _): seconds = 600
        case (_, .pending?): seconds = 20
        default: seconds = 90
        }
        if !appActive { seconds = max(seconds, 300) }
        if lowPower { seconds *= 3 }
        return seconds
    }
}
