import Foundation
import Observation
import TetherProtocol

/// Other Macs this one is paired with, as their companion: the same pairing
/// and protocol as the iPhone app, minus push. Connected while the Remote
/// Macs window is open.
@MainActor
@Observable
final class RemoteStore {
    private(set) var connections: [MacConnection] = []
    /// A pairing in progress, shown in the pairing sheet.
    private(set) var pairing: MacConnection?
    /// Bumped on each successful pairing, so the sheet can close.
    private(set) var pairedCount = 0

    init() {
        connections = MacKeychain.load().map(MacConnection.init(mac:))
    }

    func connection(_ macId: UUID) -> MacConnection? {
        connections.first { $0.id == macId }
    }

    func connectAll() { connections.forEach { $0.connect() } }
    func disconnectAll() { connections.forEach { $0.disconnect() } }

    /// Starts pairing from the link the other Mac shows under its QR code.
    /// Returns what's wrong with the text, or nil once pairing has started.
    func pair(text: String, ownName: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let link = PairingLink(url: url) else {
            return "That isn't a pairing link. It starts with tether://pair."
        }
        guard link.macName != ownName else {
            return "That link is for this Mac. Copy it from the other Mac's settings."
        }
        pairing?.disconnect()
        let connection = MacConnection(pairing: link)
        connection.onPaired = { [weak self, weak connection] mac in
            guard let self, let connection else { return }
            self.adopt(connection, mac: mac)
        }
        pairing = connection
        connection.connect()
        return nil
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
    /// older pairing with the same Mac.
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
