import AppKit
import Foundation
import Observation
import TetherCore

/// Pull request and check status per worktree, from the GitHub CLI. Without
/// `gh` (or signed out) nothing is shown and nothing else changes.
@MainActor
@Observable
final class PullRequestStore {
    /// By worktree path. Only branches other than the project's base are asked about.
    private(set) var statuses: [String: PullRequestStatus] = [:]

    /// Worktree path to branch name: what to ask about right now.
    @ObservationIgnored var targets: () -> [String: String] = { [:] }
    @ObservationIgnored private let cli = GitHubCLI.locate()
    @ObservationIgnored private var lastChecked: [String: (branch: String, at: Date)] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start() {
        guard cli != nil, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkDue()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Asks again on the next pass, e.g. after a Claude turn that may have pushed.
    func refreshSoon(_ path: String) {
        lastChecked[path] = nil
        checkDue()
    }

    private func checkDue() {
        guard let cli else { return }
        let targets = targets()
        for path in Array(statuses.keys) where targets[path] == nil {
            statuses[path] = nil
            lastChecked[path] = nil
        }
        let now = Date()
        let active = NSApp.isActive
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        for (path, branch) in targets where !inFlight.contains(path) {
            if let last = lastChecked[path], last.branch == branch {
                let interval = PullRequestPolicy.interval(for: statuses[path], appActive: active, lowPower: lowPower)
                if now.timeIntervalSince(last.at) < interval { continue }
            } else if lastChecked[path] != nil {
                statuses[path] = nil // switched branches: the old pull request isn't this one
            }
            lastChecked[path] = (branch, now)
            inFlight.insert(path)
            Task { [weak self] in
                // Signed out, offline, or not a GitHub remote: show nothing.
                let status = try? await cli.pullRequest(branch: branch, in: path)
                guard let self else { return }
                self.inFlight.remove(path)
                // Dropped or moved to another branch while gh ran.
                guard self.lastChecked[path]?.branch == branch else { return }
                if self.statuses[path] != status { self.statuses[path] = status }
            }
        }
    }
}
