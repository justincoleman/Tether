import Foundation
import Observation
import TetherCore

/// What's New: the bundled release notes and which ones this Mac has seen.
/// Adding a release is one entry at the top of `Resources/ReleaseNotes.json`
/// (a test fails if it doesn't match the app's version).
@MainActor
@Observable
final class ReleaseNotesStore {
    private static let seenKey = "lastSeenReleaseVersion"

    let notes: [ReleaseNote]
    let current: String
    private(set) var lastSeen: String?
    private var toastDismissed = false

    init() {
        if let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? ReleaseNotes.parse(data) {
            notes = parsed
        } else {
            notes = []
        }
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        current = bundleVersion.flatMap { SemanticVersion($0) != nil ? $0 : nil } ?? notes.first?.version ?? "0"
        lastSeen = UserDefaults.standard.string(forKey: Self.seenKey)
    }

    /// Releases to announce since this Mac last opened What's New.
    var unseen: [ReleaseNote] {
        ReleaseNotes.unseen(notes, lastSeen: lastSeen, current: current)
    }

    var showToast: Bool { !unseen.isEmpty && !toastDismissed }

    /// The window shows what's new, or the latest release when there's nothing new.
    var displayed: [ReleaseNote] {
        unseen.isEmpty ? Array(notes.prefix(1)) : unseen
    }

    /// Reading, closing the window or dismissing the toast all count as seen.
    func markSeen() {
        lastSeen = current
        toastDismissed = true
        UserDefaults.standard.set(current, forKey: Self.seenKey)
    }
}
