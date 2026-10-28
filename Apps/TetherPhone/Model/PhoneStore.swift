import Foundation
import Observation
import TetherProtocol
import UIKit

/// Every paired Mac and its connection. Owned by the app, shared by all views.
@MainActor
@Observable
final class PhoneStore {
    private(set) var connections: [MacConnection] = []
    /// A pairing in progress, shown by the pairing sheet.
    private(set) var pairing: MacConnection?
    /// Bumped on each successful pairing, so the pairing sheet can close.
    private(set) var pairedCount = 0
    /// A session to open, from a notification tap or a Live Activity.
    var openRoute: SessionRoute?
    /// The tab on screen, so its own notifications don't show as banners.
    var visiblePaneId: PaneID?

    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var pushToStartToken: String?

    init() {
        connections = MacKeychain.load().map(MacConnection.init(mac:))
    }

    /// Opened from a Live Activity: tether://session?mac=<id>&pane=<id>.
    func open(_ url: URL) -> Bool {
        guard url.scheme == PairingLink.scheme, url.host == "session",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let mac = items.first(where: { $0.name == "mac" })?.value.flatMap(UUID.init(uuidString:)),
              let pane = items.first(where: { $0.name == "pane" })?.value.flatMap(UUID.init(uuidString:))
        else { return false }
        openRoute = SessionRoute(macId: mac, paneId: pane)
        return true
    }

    var isEmpty: Bool { connections.isEmpty }

    func connection(_ macId: UUID) -> MacConnection? {
        connections.first { $0.id == macId }
    }

    func connectAll() { connections.forEach { $0.connect() } }

    // MARK: Push

    private var registration: PushRegistration? {
        guard let deviceToken else { return nil }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        return PushRegistration(deviceToken: deviceToken, pushToStartToken: pushToStartToken,
                                bundleId: Bundle.main.bundleIdentifier ?? "", sandbox: sandbox)
    }

    func setDeviceToken(_ token: String) {
        deviceToken = token
        shareRegistration()
    }

    func setPushToStartToken(_ token: String) {
        pushToStartToken = token
        shareRegistration()
    }

    private func shareRegistration() {
        let registration = self.registration
        for connection in connections { connection.pushRegistration = registration }
    }

    /// Tells the Mac which token updates a tab's Live Activity, connecting
    /// in the background if needed.
    func reportActivityToken(_ token: String?, macId: UUID, paneId: PaneID) async {
        await perform(on: macId) { $0.reportActivity(paneId: paneId, token: token) }
    }

    /// Runs `action` on a Mac's connection once it's online. Used from
    /// notification actions, when the app was launched in the background and
    /// is not connected. Disconnects again unless the app is in front.
    func perform(on macId: UUID, timeout: Duration = .seconds(20), _ action: (MacConnection) -> Void) async {
        guard let connection = connection(macId) else { return }
        connection.connect()
        let deadline = ContinuousClock.now + timeout
        while connection.status != .online, ContinuousClock.now < deadline {
            if case .rejected = connection.status { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard connection.status == .online else { return }
        action(connection)
        // Give the frame time to leave before iOS suspends the app.
        try? await Task.sleep(for: .seconds(1.5))
        if UIApplication.shared.applicationState != .active { connection.disconnect() }
    }
    func disconnectAll() { connections.forEach { $0.disconnect() } }

    func pair(_ link: PairingLink) {
        pairing?.disconnect()
        let connection = MacConnection(pairing: link)
        connection.onPaired = { [weak self, weak connection] mac in
            guard let self, let connection else { return }
            self.adopt(connection, mac: mac)
        }
        pairing = connection
        connection.connect()
    }

    func cancelPairing() {
        pairing?.disconnect()
        pairing = nil
    }

    func remove(_ macId: UUID) {
        connection(macId)?.disconnect()
        connections.removeAll { $0.id == macId }
        persist()
    }

    /// The pairing connection becomes that Mac's connection, replacing an
    /// older pairing with the same Mac. Its stable id comes from the Mac.
    private func adopt(_ pairingConnection: MacConnection, mac: PairedMac) {
        pairingConnection.disconnect()
        pairing = nil
        if let old = connection(mac.id) {
            old.disconnect()
            connections.removeAll { $0.id == mac.id }
        }
        let connection = MacConnection(mac: mac)
        connection.pushRegistration = registration
        connections.append(connection)
        pairedCount += 1
        persist()
        connection.connect()
    }

    private func persist() {
        MacKeychain.save(connections.map(\.mac))
    }
}
