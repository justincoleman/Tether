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

    func model(for sessionId: SessionID?) -> TranscriptModel? {
        sessionId.flatMap { models[$0] }
    }

    /// Follows a session's transcript. With no path, the file is located by
    /// session id, waiting for it to appear if the session is brand new.
    func track(sessionId: SessionID, path: String?) {
        if feeds[sessionId] != nil {
            // Already following that file, or still locating and no better info.
            if path == nil || paths[sessionId] == path { return }
        }
        stop(sessionId)
        let id = sessionId
        feeds[id] = Task { [weak self] in
            var resolved = path
            while resolved == nil {
                resolved = TranscriptLocator.find(sessionId: id)
                if resolved == nil {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
            }
            guard let transcriptPath = resolved else { return }
            self?.paths[id] = transcriptPath
            let feed = TranscriptFeed(path: transcriptPath)
            while !Task.isCancelled {
                let events = await feed.poll()
                if !events.isEmpty {
                    guard let self else { return }
                    var model = self.models[id] ?? TranscriptModel()
                    model.apply(events)
                    self.models[id] = model
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop(_ sessionId: SessionID) {
        feeds.removeValue(forKey: sessionId)?.cancel()
        paths[sessionId] = nil
        models[sessionId] = nil
    }
}
