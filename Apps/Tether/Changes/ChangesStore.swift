import Foundation
import Observation
import TetherCore
import TetherProtocol

/// Keeps a git snapshot per worktree fresh: watches the folder, refreshes
/// shortly after changes settle, and fetches the base branch periodically.
@MainActor
@Observable
final class ChangesStore {
    struct FetchInfo: Equatable {
        var at: Date
        var error: String?
    }

    private(set) var snapshots: [String: ChangesSnapshot] = [:]
    /// How staged each uncommitted file is, by worktree then file path.
    private(set) var staging: [String: [String: StagingState]] = [:]
    /// The last stage or unstage that failed, by worktree, until the next one.
    private(set) var stagingErrors: [String: String] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var fetchInfo: [String: FetchInfo] = [:]
    private(set) var refreshing: Set<String> = []
    /// Bumped whenever a worktree's snapshot content changes, so an open diff
    /// knows to reload.
    private(set) var revisions: [String: Int] = [:]

    @ObservationIgnored private var baseBranches: [String: String] = [:]
    @ObservationIgnored private var watchers: [String: FSEventsWatcher] = [:]
    @ObservationIgnored private var debounceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var firstPending: [String: Date] = [:]
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var lastFetchAttempt: [String: Date] = [:]
    @ObservationIgnored private var fetchLoop: Task<Void, Never>?
    @ObservationIgnored private var focusedPath: String?
    @ObservationIgnored private let runner = GitRunner()

    // MARK: Tracking

    /// Follows exactly these worktrees (path to base branch name).
    func sync(_ worktrees: [String: String]) {
        for path in Array(baseBranches.keys) where worktrees[path] == nil { remove(path) }
        for (path, base) in worktrees {
            let previous = baseBranches[path]
            baseBranches[path] = base
            if previous == nil {
                startWatching(path)
                scheduleRefresh(path, immediate: true)
            } else if previous != base {
                scheduleRefresh(path, immediate: true)
            }
        }
        startFetchLoop()
    }

    /// The worktree the user is looking at gets fresher data.
    func focus(_ path: String?) {
        focusedPath = path
        guard let path, baseBranches[path] != nil else { return }
        scheduleRefresh(path, immediate: true)
        fetchNow(path)
    }

    func refresh(_ path: String) {
        scheduleRefresh(path, immediate: true)
    }

    private func remove(_ path: String) {
        watchers[path]?.stop()
        watchers[path] = nil
        debounceTasks[path]?.cancel()
        debounceTasks[path] = nil
        baseBranches[path] = nil
        snapshots[path] = nil
        staging[path] = nil
        stagingErrors[path] = nil
        errors[path] = nil
        fetchInfo[path] = nil
        revisions[path] = nil
        firstPending[path] = nil
        dirty.remove(path)
        lastFetchAttempt[path] = nil
    }

    private func startWatching(_ path: String) {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        watchers[path] = FSEventsWatcher(path: path) { [weak self] events in
            guard events.contains(where: { GitEventFilter.isRelevant(eventPath: $0, root: root) }) else { return }
            Task { @MainActor in self?.scheduleRefresh(path) }
        }
    }

    // MARK: Refresh

    /// Waits for a burst of events to settle, but never starves a refresh for
    /// more than two seconds while edits keep arriving.
    private func scheduleRefresh(_ path: String, immediate: Bool = false) {
        guard baseBranches[path] != nil else { return }
        let started = firstPending[path] ?? Date()
        firstPending[path] = started
        debounceTasks[path]?.cancel()
        let starved = Date().timeIntervalSince(started) >= 2
        let delay: Double = (immediate || starved) ? 0 : 0.3
        debounceTasks[path] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.firstPending[path] = nil
            await self.runRefresh(path)
        }
    }

    private func runRefresh(_ path: String) async {
        guard baseBranches[path] != nil else { return }
        if running.contains(path) {
            dirty.insert(path) // pick up what changed while the last run was going
            return
        }
        running.insert(path)
        refreshing.insert(path)
        repeat {
            dirty.remove(path)
            guard let base = baseBranches[path] else { break }
            do {
                let (snapshot, staged) = try await GitRepository(path: path, runner: runner)
                    .snapshotAndStaging(baseBranch: base)
                if staging[path] != staged { staging[path] = staged }
                if let old = snapshots[path], old.sameContent(as: snapshot) {
                    // Nothing new; keep the existing value so views do not redraw.
                } else {
                    snapshots[path] = snapshot
                    revisions[path, default: 0] += 1
                }
                errors[path] = nil
            } catch {
                errors[path] = Self.describe(error)
            }
        } while dirty.contains(path) && baseBranches[path] != nil
        running.remove(path)
        refreshing.remove(path)
    }

    // MARK: Staging

    /// Stages the files' uncommitted changes, both sides of a rename included.
    func stage(_ files: [ChangedFile], in path: String) {
        changeIndex(files, in: path) { try await $0.stage($1) }
    }

    func unstage(_ files: [ChangedFile], in path: String) {
        changeIndex(files, in: path) { try await $0.unstage($1) }
    }

    private func changeIndex(_ files: [ChangedFile], in path: String,
                             _ action: @escaping @Sendable (GitRepository, [String]) async throws -> Void) {
        let paths = files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }
        let repository = GitRepository(path: path, runner: runner)
        Task { [weak self] in
            var failure: String?
            do {
                try await action(repository, paths)
            } catch {
                failure = Self.describe(error)
            }
            guard let self else { return }
            self.stagingErrors[path] = failure
            self.scheduleRefresh(path, immediate: true)
        }
    }

    // MARK: Fetch

    /// Fetches the base branch, at most once every 20 seconds per worktree.
    func fetchNow(_ path: String, force: Bool = false) {
        guard let base = baseBranches[path] else { return }
        let now = Date()
        if !force, let last = lastFetchAttempt[path], now.timeIntervalSince(last) < 20 { return }
        lastFetchAttempt[path] = now
        let runner = self.runner
        Task { [weak self] in
            var failure: String?
            do {
                try await GitRepository(path: path, runner: runner).fetch(baseBranch: base)
            } catch {
                failure = Self.describe(error)
            }
            guard let self else { return }
            self.fetchInfo[path] = FetchInfo(at: Date(), error: failure)
            self.scheduleRefresh(path, immediate: true)
        }
    }

    private func startFetchLoop() {
        guard fetchLoop == nil else { return }
        fetchLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.fetchDue()
            }
        }
    }

    /// The focused worktree every two minutes, the rest every ten.
    private func fetchDue() {
        let now = Date()
        for path in Array(baseBranches.keys) {
            // Low Power Mode: a third as many network round trips.
            let scale: TimeInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 3 : 1
            let interval: TimeInterval = (path == focusedPath ? 120 : 600) * scale
            if now.timeIntervalSince(lastFetchAttempt[path] ?? .distantPast) >= interval {
                fetchNow(path, force: true)
            }
        }
    }

    // MARK: Diffs

    func loadDiff(path: String, file: ChangedFile) async throws -> FileDiff {
        let mergeBase = snapshots[path]?.mergeBase
        return try await GitRepository(path: path, runner: runner).fileDiff(file, mergeBase: mergeBase)
    }

    static func describe(_ error: Error) -> String {
        (error as? GitError)?.description ?? error.localizedDescription
    }
}
