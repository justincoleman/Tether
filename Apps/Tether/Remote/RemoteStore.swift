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
    /// Name of the Mac the last pairing succeeded with, until the next attempt.
    private(set) var lastPairedName: String?
    /// The Mac whose projects the sidebar shows; nil is this Mac.
    var selectedMacId: UUID?
    /// The Claude tab open in the main area while a paired Mac is selected.
    var selectedPaneId: PaneID?
    /// The project whose tabs the header shows; follows the selected tab.
    var selectedProjectId: ProjectID?
    /// Views that need the connections up; they drop when the last one leaves.
    @ObservationIgnored private var holds = 0

    init() {
        connections = MacKeychain.load().map(MacConnection.init(mac:))
    }

    func connection(_ macId: UUID) -> MacConnection? {
        connections.first { $0.id == macId }
    }

    var selectedConnection: MacConnection? {
        selectedMacId.flatMap { connection($0) }
    }

    func retain() {
        holds += 1
        connections.forEach { $0.connect() }
    }

    func release() {
        holds = max(0, holds - 1)
        if holds == 0 { connections.forEach { $0.disconnect() } }
    }

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
        lastPairedName = nil
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
        if selectedMacId == macId {
            selectedMacId = nil
            selectedPaneId = nil
            selectedProjectId = nil
        }
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
        lastPairedName = mac.name
        persist()
        connection.connect()
    }

    private func persist() {
        MacKeychain.save(connections.map(\.mac))
    }
}
