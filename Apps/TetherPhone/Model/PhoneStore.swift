import Foundation
import Observation
import TetherProtocol

/// Every paired Mac and its connection. Owned by the app, shared by all views.
@MainActor
@Observable
final class PhoneStore {
    private(set) var connections: [MacConnection] = []
    /// A pairing in progress, shown by the pairing sheet.
    private(set) var pairing: MacConnection?
    /// Bumped on each successful pairing, so the pairing sheet can close.
    private(set) var pairedCount = 0

    init() {
        connections = MacKeychain.load().map(MacConnection.init(mac:))
    }

    var isEmpty: Bool { connections.isEmpty }

    func connection(_ macId: UUID) -> MacConnection? {
        connections.first { $0.id == macId }
    }

    func connectAll() { connections.forEach { $0.connect() } }
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
        connections.append(connection)
        pairedCount += 1
        persist()
        connection.connect()
    }

    private func persist() {
        MacKeychain.save(connections.map(\.mac))
    }
}
