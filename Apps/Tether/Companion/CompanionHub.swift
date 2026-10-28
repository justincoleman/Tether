import Foundation
import Observation
import TetherCore
import TetherProtocol

/// One connected phone.
@MainActor
final class CompanionClient {
    let channel: WebSocketChannel
    let peer: String
    var hello: Hello?
    var device: PairedDevice?
    var subscribed: SessionID?
    /// Messages are handled one at a time, in order: `authenticate` awaits the
    /// token store, and a `subscribe` right behind it must not overtake it.
    var inbox: Task<Void, Never>?

    init(channel: WebSocketChannel, peer: String) {
        self.channel = channel
        self.peer = peer
    }

    func send(_ message: MacMessage) { channel.send(message) }
}

/// The Mac side of the iPhone companion: pairing, auth, and pushing state
/// and transcripts to connected phones. Protocol in docs/PROTOCOL.md.
@MainActor
@Observable
final class CompanionHub {
    struct PairingWindow: Equatable {
        var link: PairingLink
        var expires: Date
    }

    /// Why phones can't connect, or nil when listening.
    private(set) var problem: String?
    /// This Mac's Tailscale address, if it has one.
    private(set) var tailnetAddress: String?
    private(set) var devices: [PairedDevice] = []
    private(set) var connectedDeviceIds: Set<UUID> = []
    private(set) var pairing: PairingWindow?

    let macName = Host.current().localizedName ?? "Mac"
    let port = CompanionServer.defaultPort

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let server = CompanionServer()
    @ObservationIgnored private let auth = CompanionAuth(
        fileURL: ProjectStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("companion.json"))
    @ObservationIgnored private var clients: [ObjectIdentifier: CompanionClient] = [:]
    @ObservationIgnored private var snapshotScheduled = false
    @ObservationIgnored private var lastSnapshot: Snapshot?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func start() {
        server.onConnection = { [weak self] channel, peer in self?.connected(channel, peer: peer) }
        server.onStateChange = { [weak self] problem in self?.problem = problem }
        do {
            try server.start(port: port)
        } catch {
            problem = "Phone connections are off: \(error.localizedDescription)"
        }
        refreshAddress()
        Task { self.devices = await self.auth.devices }
    }

    func refreshAddress() {
        tailnetAddress = Tailnet.preferredAddress(from: CompanionServer.localAddresses())
    }

    // MARK: Pairing

    /// Opens a two-minute pairing window and returns the link the QR encodes.
    func beginPairing() async {
        refreshAddress()
        guard let host = tailnetAddress else { return }
        let (code, expires) = await auth.issueCode()
        pairing = PairingWindow(link: PairingLink(host: host, port: Int(port), code: code, macName: macName),
                                expires: expires)
    }

    func cancelPairing() {
        pairing = nil
        Task { await auth.cancelCode() }
    }

    func revoke(_ id: UUID) {
        Task {
            await auth.revoke(id)
            devices = await auth.devices
            for client in clients.values where client.device?.id == id {
                client.send(.authFailed(reason: "\(macName) removed this iPhone. Pair again to reconnect."))
                client.channel.close()
            }
        }
    }

    // MARK: State out

    /// Coalesces bursts of hook events into one snapshot per runloop hop.
    func setNeedsSnapshot() {
        guard !snapshotScheduled, !clients.isEmpty else { return }
        snapshotScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            snapshotScheduled = false
            guard let snapshot = model?.companionSnapshot(macName: macName), snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            for client in clients.values where client.device != nil {
                client.send(.snapshot(snapshot))
            }
        }
    }

    func publish(_ events: [MirrorEvent], sessionId: SessionID) {
        for client in clients.values where client.device != nil && client.subscribed == sessionId {
            client.send(.transcript(sessionId: sessionId, events: events, reset: false))
        }
    }

    // MARK: Connections

    private func connected(_ channel: WebSocketChannel, peer: String) {
        let client = CompanionClient(channel: channel, peer: peer)
        let key = ObjectIdentifier(client)
        clients[key] = client
        channel.onMessage = { [weak self, weak client] data in
            guard let self, let client else { return }
            let previous = client.inbox
            client.inbox = Task {
                await previous?.value
                await self.received(data, from: client)
            }
        }
        channel.onClose = { [weak self] error in
            print("Companion: \(peer) closed\(error.map { ": \($0)" } ?? "")")
            guard let self else { return }
            self.clients[key] = nil
            self.updateConnected()
        }
    }

    private func updateConnected() {
        connectedDeviceIds = Set(clients.values.compactMap(\.device?.id))
    }

    private func received(_ data: Data, from client: CompanionClient) async {
        guard let message = try? WireCodec.decoder().decode(PhoneMessage.self, from: data) else {
            print("Companion: unreadable message from \(client.peer)")
            client.send(.error(message: "The Mac couldn't read that message. Update Tether on both devices."))
            return
        }
        switch message {
        case .hello(let hello):
            print("Companion: hello from \(hello.deviceName), protocol \(hello.protocolVersion)")
            client.hello = hello
            client.send(.hello(Hello(appVersion: appVersion, deviceName: macName)))
            if hello.protocolVersion != ProtocolVersion.current {
                // The phone compares versions too and shows "Update needed".
                client.channel.close()
            }
        case .pair(let code):
            guard let result = await auth.pair(code: code, deviceName: client.hello?.deviceName ?? "iPhone") else {
                print("Companion: pairing code rejected")
                client.send(.authFailed(reason: "That pairing code is wrong or expired. Show a new QR code on the Mac."))
                client.channel.close()
                return
            }
            client.device = result.device
            pairing = nil
            devices = await auth.devices
            let macId = await auth.macId
            client.send(.paired(macId: macId, macName: macName, token: result.token))
            didAuthenticate(client)
        case .authenticate(let token):
            guard let device = await auth.authenticate(token: token) else {
                print("Companion: unknown token")
                client.send(.authFailed(reason: "This iPhone is no longer paired with \(macName). Pair again."))
                client.channel.close()
                return
            }
            client.device = device
            devices = await auth.devices
            let macId = await auth.macId
            client.send(.authenticated(macId: macId, macName: macName))
            didAuthenticate(client)
        default:
            guard client.device != nil else {
                client.send(.authFailed(reason: "Not paired."))
                client.channel.close()
                return
            }
            handleAuthenticated(message, from: client)
        }
    }

    private func didAuthenticate(_ client: CompanionClient) {
        updateConnected()
        if let snapshot = model?.companionSnapshot(macName: macName) {
            client.send(.snapshot(snapshot))
        }
    }

    private func handleAuthenticated(_ message: PhoneMessage, from client: CompanionClient) {
        guard let model else { return }
        switch message {
        case .subscribe(let sessionId):
            client.subscribed = sessionId
            if let sessionId {
                client.send(.transcript(sessionId: sessionId, events: model.mirror.events(for: sessionId), reset: true))
            }
        case .sendMessage(let paneId, let text):
            let outcome: String = switch model.sendOrQueue(text, toPane: paneId) {
            case .sent: "sent"
            case .queued: "queued"
            case .failed: "failed"
            }
            client.send(.sendResult(paneId: paneId, outcome: outcome))
        case .permissionDecision(let requestId, let allow):
            model.resolvePermission(requestId, allow ? .allow : .deny(message: "Denied from iPhone."))
        case .startSession, .reorderProjects, .registerPush:
            client.send(.error(message: "This Mac doesn't support that yet."))
        case .hello, .pair, .authenticate:
            break
        }
    }
}
