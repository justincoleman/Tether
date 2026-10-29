import Dispatch
import Foundation

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

    public init(number: Int, title: String, url: String, state: State, isDraft: Bool,
                passed: Int, failed: Int, pending: Int, failedNames: [String]) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.failedNames = failedNames
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
    public static let fields = "number,title,url,state,isDraft,statusCheckRollup"

    private struct Raw: Decodable {
        var number: Int
        var title: String
        var url: String
        var state: String
        var isDraft: Bool?
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
                                 passed: passed, failed: failed, pending: pending, failedNames: failedNames)
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

    public init(path: String, timeout: TimeInterval = 20) {
        self.path = path
        self.timeout = timeout
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
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        let environment = env
        let path = self.path
        let limit = timeout
        let output: GitOutput = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try GitRunner.runBlocking(executable: path, arguments: args, directory: directory,
                                              environment: environment, timeout: limit, allowedExitCodes: [0, 1])
                })
            }
        }
        if output.status != 0 {
            if PullRequestParser.isNoPullRequest(output.stderr) { return nil }
            let line = output.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(output.status)"
            throw Failure.failed("gh: \(line)")
        }
        return try PullRequestParser.parse(output.stdout)
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
