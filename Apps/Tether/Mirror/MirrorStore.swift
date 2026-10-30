import Foundation
import Observation
import TetherCore
import TetherProtocol

/// One transcript feed per live session. Parsing runs on the feed actor;
/// only the folded model lands on the main actor.
@MainActor
@Observable
final class MirrorStore {
    private(set) var models: [SessionID: TranscriptModel] = [:]
    @ObservationIgnored private var feeds: [SessionID: Task<Void, Never>] = [:]
    /// Resolved transcript path per tracked session; nil while still looking.
    @ObservationIgnored private var paths: [SessionID: String] = [:]
    @ObservationIgnored private var agents: [SessionID: AgentKind] = [:]
    /// Raw events per session, so a phone that subscribes late gets the history.
    @ObservationIgnored private var logs: [SessionID: [MirrorEvent]] = [:]
    /// New events as they arrive, for the companion server.
    @ObservationIgnored var onEvents: ((SessionID, [MirrorEvent]) -> Void)?
    /// A mode record the transcript wrote, e.g. after Shift-Tab.
    @ObservationIgnored var onMode: ((SessionID, String) -> Void)?
    /// How often transcripts are read. The app slows it when nobody is looking.
    @ObservationIgnored var pollInterval: Duration = .milliseconds(500)

    /// The most recent events for a session, capped so a resend stays small.
    func events(for sessionId: SessionID, limit: Int = 1500) -> [MirrorEvent] {
        Array((logs[sessionId] ?? []).suffix(limit))
    }

    func model(for sessionId: SessionID?) -> TranscriptModel? {
        sessionId.flatMap { models[$0] }
    }

    /// Follows a session's transcript. With no path, the file is located by
    /// session id, waiting for it to appear if the session is brand new.
    func track(sessionId: SessionID, path: String?, agent: AgentKind = .claude) {
        if feeds[sessionId] != nil, agents[sessionId] == agent {
            // Already following that file, or still locating and no better info.
            if path == nil || paths[sessionId] == path { return }
        }
        stop(sessionId)
        let id = sessionId
        agents[id] = agent
        feeds[id] = Task { [weak self] in
            var resolved: String?
            if agent == .claude { resolved = path }
            while resolved == nil {
                resolved = await Task.detached(priority: .utility) {
                    if agent == .codex {
                        if let path, let validated = CodexTranscriptLocator.validatedPath(path, sessionId: id) { return validated }
                        return CodexTranscriptLocator.find(sessionId: id)
                    }
                    return TranscriptLocator.find(sessionId: id)
                }.value
                if Task.isCancelled { return }
                if resolved == nil {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
            }
            guard let transcriptPath = resolved else { return }
            self?.paths[id] = transcriptPath
            let feed = TranscriptFeed(path: transcriptPath, agent: agent)
            while !Task.isCancelled {
                let events = await feed.poll()
                if let mode = await feed.takeMode() { self?.onMode?(id, mode) }
                guard !Task.isCancelled else { return }
                self?.append(events, for: id)
                let wait = self?.pollInterval ?? .seconds(3)
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// Shared sink for file feeds and native app-server events. Native sessions
    /// use this directly and must not also start a transcript file feed.
    func append(_ events: [MirrorEvent], for sessionId: SessionID) {
        guard !events.isEmpty else { return }
        var model = models[sessionId] ?? TranscriptModel()
        model.apply(events)
        models[sessionId] = model
        logs[sessionId, default: []].append(contentsOf: events)
        onEvents?(sessionId, events)
    }

    func stop(_ sessionId: SessionID) {
        feeds.removeValue(forKey: sessionId)?.cancel()
        paths[sessionId] = nil
        agents[sessionId] = nil
        models[sessionId] = nil
        logs[sessionId] = nil
    }
}
