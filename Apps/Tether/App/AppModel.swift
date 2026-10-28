import Foundation
import Observation
import TetherCore
import TetherProtocol

/// Main-actor façade over the TetherCore actors. Views bind to this; it never
/// does I/O itself beyond forwarding to the store.
@MainActor
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
    private(set) var sessionStates: [ProjectID: SessionState] = [:]
    var selectedProjectId: ProjectID?
    var addProjectRequested = false

    private let store = ProjectStore(fileURL: ProjectStore.defaultFileURL())
    let registry = SessionRegistry()

    init() {
        Task { await reload() }
    }

    func reload() async {
        projects = await store.orderedProjects()
        if selectedProjectId == nil { selectedProjectId = projects.first?.id }
    }

    func addProject(at url: URL) async {
        do {
            let p = try await store.addProject(name: url.lastPathComponent, path: url.path)
            await reload()
            selectedProjectId = p.id
        } catch {
            // Phase 0: surface in a log. Phase 1 adds user-visible errors.
            print("addProject failed: \(error)")
        }
    }

    func removeProject(_ id: ProjectID) async {
        try? await store.removeProject(id)
        await reload()
    }
}
