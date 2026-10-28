import ActivityKit
import Foundation
import TetherProtocol

/// Keeps Live Activities and their push tokens in step with the Macs.
/// Activities are started by the Mac (push-to-start); the phone reports the
/// tokens the Mac needs to update and end them, and while it's open it also
/// updates or ends them itself from each snapshot.
@MainActor
enum LiveActivities {
    static func observeTokens(store: PhoneStore) {
        Task {
            for await data in Activity<LiveActivityAttributes>.pushToStartTokenUpdates {
                store.setPushToStartToken(hex(data))
            }
        }
        for activity in Activity<LiveActivityAttributes>.activities { watch(activity, store: store) }
        Task {
            for await activity in Activity<LiveActivityAttributes>.activityUpdates {
                watch(activity, store: store)
            }
        }
    }

    private static func watch(_ activity: Activity<LiveActivityAttributes>, store: PhoneStore) {
        let id = activity.id
        guard let macId = UUID(uuidString: activity.attributes.macId),
              let paneId = UUID(uuidString: activity.attributes.paneId) else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                await store.reportActivityToken(hex(data), macId: macId, paneId: paneId)
            }
        }
        Task {
            guard let same = Activity<LiveActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
            for await state in same.activityStateUpdates where state == .ended || state == .dismissed {
                await store.reportActivityToken(nil, macId: macId, paneId: paneId)
                return
            }
        }
    }

    /// While connected: match every activity for this Mac to its tab's state.
    static func reconcile(macId: UUID, snapshot: Snapshot) {
        for activity in Activity<LiveActivityAttributes>.activities where activity.attributes.macId == macId.uuidString {
            let session = snapshot.sessions.first { $0.id.uuidString == activity.attributes.paneId }
            var content = activity.content.state
            if let session {
                content.state = session.state.rawValue
                content.detail = session.preview ?? content.detail
            }
            let active = session.map { $0.state == .working || $0.state == .needsInput } ?? false
            let next = ActivityContent(state: content, staleDate: nil)
            guard next.state != activity.content.state || !active else { continue }
            Task {
                if active {
                    await activity.update(next)
                } else {
                    await activity.end(next, dismissalPolicy: .after(Date().addingTimeInterval(15 * 60)))
                }
            }
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
