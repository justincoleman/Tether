import Foundation
import Observation
import TetherProtocol
import UIKit

/// The live link to one Mac: connects, authenticates (or pairs), keeps the
/// Mac's snapshot and the subscribed transcript, and reconnects with backoff.
@MainActor
@Observable
final class MacConnection: Identifiable {
    enum Status: Equatable {
        case connecting
        case online
        case offline(String)
        /// The Mac speaks another protocol version.
        case updateNeeded(macVersion: Int)
        /// The Mac rejected the token or pairing code. No retries.
        case rejected(String)
    }

    private(set) var mac: PairedMac
    private(set) var status: Status = .offline("Not connected")
    private(set) var snapshot: Snapshot?
    private(set) var transcripts: [SessionID: TranscriptModel] = [:]
    /// Last answer to a sent message, per tab, e.g. "queued".
    private(set) var sendResults: [PaneID: String] = [:]

    nonisolated var id: UUID { macIdForIdentity }
    private nonisolated let macIdForIdentity: UUID

    /// Set while pairing: sent instead of the token on the first connection.
    @ObservationIgnored private var pairingCode: String?
    @ObservationIgnored var onPaired: ((PairedMac) -> Void)?
    @ObservationIgnored private var channel: WebSocketChannel?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var pinger: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var subscribed: SessionID?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var pendingStarts: [UUID: CheckedContinuation<StartOutcome, Never>] = [:]

    enum StartOutcome {
        case started(PaneID)
        case failed(String)
    }

    init(mac: PairedMac) {
        self.mac = mac
        self.macIdForIdentity = mac.id
    }

    /// A connection that redeems a pairing link instead of a token.
    init(pairing link: PairingLink) {
        let placeholder = PairedMac(id: UUID(), name: link.macName, host: link.host, port: link.port, token: "")
        self.mac = placeholder
        self.macIdForIdentity = placeholder.id
        self.pairingCode = link.code
    }

    func connect() {
        wanted = true
        guard channel == nil else { return }
        if case .rejected = status { return }
        if case .updateNeeded = status { return }
        retry?.cancel()
        status = .connecting
        let channel = WebSocketChannel(host: mac.host, port: mac.port)
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.send(PhoneMessage.hello(Hello(appVersion: Self.appVersion, deviceName: UIDevice.current.name)))
            if let code = self.pairingCode {
                channel.send(PhoneMessage.pair(code: code))
            } else {
                channel.send(PhoneMessage.authenticate(token: self.mac.token))
            }
        }
        channel.onMessage = { [weak self] data in self?.received(data) }
        channel.onClose = { [weak self, weak channel] error in
            guard let self, let channel, self.channel === channel else { return }
            self.channelClosed(error?.localizedDescription)
        }
        self.channel = channel
        channel.start()
    }

    func disconnect() {
        wanted = false
        retry?.cancel()
        pinger?.cancel()
        let old = channel
        channel = nil
        old?.close()
        if status == .online || status == .connecting { status = .offline("Not connected") }
    }

    /// Streams one session's transcript; nil stops.
    func subscribe(_ sessionId: SessionID?) {
        subscribed = sessionId
        if status == .online { channel?.send(PhoneMessage.subscribe(sessionId: sessionId)) }
    }

    func send(_ text: String, to paneId: PaneID) {
        sendResults[paneId] = nil
        channel?.send(PhoneMessage.sendMessage(paneId: paneId, text: text))
    }

    /// Asks the Mac to open a Claude tab, optionally on a new branch.
    /// Creating a worktree can take a while on a big repo.
    func startSession(projectId: ProjectID, branch: String?, prompt: String,
                      permissionMode: String?) async -> StartOutcome {
        guard status == .online, let channel else { return .failed("\(mac.name) is offline.") }
        let requestId = UUID()
        return await withCheckedContinuation { continuation in
            pendingStarts[requestId] = continuation
            channel.send(PhoneMessage.startSession(requestId: requestId, projectId: projectId,
                                                   branch: branch, prompt: prompt,
                                                   permissionMode: permissionMode))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                self?.finishStart(requestId, .failed("\(self?.mac.name ?? "The Mac") didn't answer."))
            }
        }
    }

    func reorderProjects(_ ids: [ProjectID]) {
        channel?.send(PhoneMessage.reorderProjects(ids: ids))
        // Show the new order now; the next snapshot confirms it.
        if var snapshot {
            snapshot.projects.sort { (ids.firstIndex(of: $0.id) ?? .max) < (ids.firstIndex(of: $1.id) ?? .max) }
            self.snapshot = snapshot
        }
    }

    func renameProject(_ id: ProjectID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        channel?.send(PhoneMessage.renameProject(id: id, name: clean))
        if var snapshot, let i = snapshot.projects.firstIndex(where: { $0.id == id }) {
            snapshot.projects[i].name = clean
            self.snapshot = snapshot
        }
    }

    private func finishStart(_ requestId: UUID, _ outcome: StartOutcome) {
        pendingStarts.removeValue(forKey: requestId)?.resume(returning: outcome)
    }

    func decide(_ requestId: UUID, allow: Bool) {
        channel?.send(PhoneMessage.permissionDecision(requestId: requestId, allow: allow))
        // Hide it now; the next snapshot confirms.
        snapshot?.permissions.removeAll { $0.id == requestId }
    }

    // MARK: Incoming

    private func received(_ data: Data) {
        guard let message = try? WireCodec.decoder().decode(MacMessage.self, from: data) else { return }
        switch message {
        case .hello(let hello):
            if hello.protocolVersion != ProtocolVersion.current {
                status = .updateNeeded(macVersion: hello.protocolVersion)
                closeChannel()
            }
        case .paired(let macId, let macName, let token):
            pairingCode = nil
            mac = PairedMac(id: macId, name: macName, host: mac.host, port: mac.port, token: token)
            didConnect()
            // The store replaces this connection with a regular one.
            onPaired?(mac)
        case .authenticated(_, let macName):
            mac.name = macName
            didConnect()
        case .authFailed(let reason):
            status = .rejected(reason)
            closeChannel()
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            // A queued message has gone out once the Mac's queue for that tab is empty.
            for session in snapshot.sessions where session.queued == 0 && sendResults[session.id] == "queued" {
                sendResults[session.id] = nil
            }
        case .transcript(let sessionId, let events, let reset):
            var model = reset ? TranscriptModel() : (transcripts[sessionId] ?? TranscriptModel())
            model.apply(events)
            transcripts[sessionId] = model
        case .sendResult(let paneId, let outcome):
            sendResults[paneId] = outcome
        case .startResult(let requestId, let paneId, let error):
            finishStart(requestId, paneId.map(StartOutcome.started) ?? .failed(error ?? "The Mac couldn't start it."))
        case .error(let message):
            print("Mac says: \(message)")
        }
    }

    private func didConnect() {
        status = .online
        attempt = 0
        if let subscribed { channel?.send(PhoneMessage.subscribe(sessionId: subscribed)) }
        pinger?.cancel()
        pinger = Task { [weak self] in
            // Keeps NAT and Tailscale paths warm, and surfaces a dead link.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, let channel = self.channel else { return }
                channel.sendPing()
            }
        }
    }

    private func closeChannel() {
        let old = channel
        channel = nil
        pinger?.cancel()
        old?.close()
    }

    private func channelClosed(_ reason: String?) {
        channel = nil
        pinger?.cancel()
        for id in Array(pendingStarts.keys) { finishStart(id, .failed("Lost the connection to \(mac.name).")) }
        switch status {
        case .rejected, .updateNeeded: return
        default: break
        }
        status = .offline(reason ?? "Disconnected")
        guard wanted, pairingCode == nil else { return }
        attempt += 1
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wanted else { return }
            self.connect()
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
