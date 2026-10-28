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
    @ObservationIgnored private var paths: [SessionID: String] = [:]

    func model(for sessionId: SessionID?) -> TranscriptModel? {
        sessionId.flatMap { models[$0] }
    }

    /// Starts following a session's transcript once its path is known.
    func track(_ session: Session) {
        guard let path = session.transcriptPath else { return }
        if paths[session.id] == path, feeds[session.id] != nil { return }
        stop(session.id)
        paths[session.id] = path
        let id = session.id
        let feed = TranscriptFeed(path: path)
        feeds[id] = Task { [weak self] in
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
