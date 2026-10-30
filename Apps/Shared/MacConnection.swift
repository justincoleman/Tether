import Foundation
import Observation
import TetherProtocol
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// The live link to one Mac: connects, authenticates (or pairs), keeps the
/// Mac's snapshot and the subscribed transcript, and reconnects with backoff.
/// The iPhone app and the Mac app (pairing with another Mac) both use it.
/// The Mac answering is told apart from this one only by `deviceName`.
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
    /// Project icons the Mac found in its project folders.
    private(set) var projectIcons: [ProjectID: PlatformImage] = [:]
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
    /// Sent after each authentication and whenever it changes.
    @ObservationIgnored var pushRegistration: PushRegistration? {
        didSet {
            if status == .online, let pushRegistration, pushRegistration != oldValue {
                channel?.send(PhoneMessage.registerPush(pushRegistration))
            }
        }
    }
    /// Live Activity tokens waiting for the connection.
    @ObservationIgnored private var pendingActivityTokens: [PaneID: String?] = [:]
    @ObservationIgnored private var pendingStarts: [UUID: CheckedContinuation<StartOutcome, Never>] = [:]
    /// Waiting `requestChanges` / `requestDiff` answers; nil on timeout or disconnect.
    @ObservationIgnored private var pendingReplies: [UUID: CheckedContinuation<MacMessage?, Never>] = [:]

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
            channel.send(PhoneMessage.hello(Hello(appVersion: Self.appVersion, deviceName: Self.deviceName)))
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

    /// Stops streaming `sessionId`, unless another session has been subscribed
    /// since. A closing view's cleanup can run after the next view's setup.
    func unsubscribe(_ sessionId: SessionID) {
        if subscribed == sessionId { subscribe(nil) }
    }

    func send(_ text: String, to paneId: PaneID) {
        sendResults[paneId] = nil
        channel?.send(PhoneMessage.sendMessage(paneId: paneId, text: text))
    }

    /// Switches the tab's model: the Mac types `/model <model>`, queued like
    /// a message, so the answer arrives in `sendResults`.
    func setModel(_ model: String, for paneId: PaneID) {
        sendResults[paneId] = nil
        channel?.send(PhoneMessage.setModel(paneId: paneId, model: model))
    }

    /// Asks the Mac to open a Claude or Codex tab, optionally on a new branch.
    /// Creating a worktree can take a while on a big repo.
    func startSession(projectId: ProjectID, branch: String?, prompt: String,
                      permissionMode: String?, agent: AgentKind = .claude) async -> StartOutcome {
        await startRequest { requestId in
            PhoneMessage.startSession(requestId: requestId, projectId: projectId,
                                      branch: branch, prompt: prompt, permissionMode: permissionMode,
                                      agent: agent == .claude ? nil : agent)
        }
    }

    /// Opens a past session in a tab on the Mac, or finds the tab running it.
    func resumeSession(_ sessionId: SessionID, projectId: ProjectID) async -> StartOutcome {
        await startRequest { PhoneMessage.resumeSession(requestId: $0, projectId: projectId, sessionId: sessionId) }
    }

    /// The project's past sessions, newest first.
    func history(for projectId: ProjectID) async -> Result<[PastSessionInfo], ReplyError> {
        switch await request({ PhoneMessage.requestHistory(requestId: $0, projectId: projectId) }) {
        case .history(_, let sessions?, _)?: return .success(sessions)
        case .history(_, nil, let error)?: return .failure(ReplyError(message: error ?? "No history."))
        default: return .failure(ReplyError(message: "\(mac.name) didn't answer."))
        }
    }

    private func startRequest(_ make: (UUID) -> PhoneMessage) async -> StartOutcome {
        guard status == .online, let channel else { return .failed("\(mac.name) is offline.") }
        let requestId = UUID()
        let message = make(requestId)
        return await withCheckedContinuation { continuation in
            pendingStarts[requestId] = continuation
            channel.send(message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                self?.finishStart(requestId, .failed("\(self?.mac.name ?? "The Mac") didn't answer."))
            }
        }
    }

    /// A photo for Claude, with optional text. The answer arrives in `sendResults`.
    func sendImage(_ jpeg: Data, text: String, to paneId: PaneID) {
        sendResults[paneId] = nil
        channel?.send(PhoneMessage.sendImage(paneId: paneId, image: jpeg, text: text))
    }

    /// The tab's Changes list, as the Mac's panel shows it.
    func changes(for paneId: PaneID) async -> Result<ChangesSnapshot, ReplyError> {
        switch await request({ PhoneMessage.requestChanges(requestId: $0, paneId: paneId) }) {
        case .changes(_, let snapshot?, _)?: return .success(snapshot)
        case .changes(_, nil, let error)?: return .failure(ReplyError(message: error ?? "No changes."))
        default: return .failure(ReplyError(message: "\(mac.name) didn't answer."))
        }
    }

    func diff(of file: ChangedFile, in paneId: PaneID) async -> Result<FileDiff, ReplyError> {
        switch await request({ PhoneMessage.requestDiff(requestId: $0, paneId: paneId, file: file) }) {
        case .fileDiff(_, let diff?, _)?: return .success(diff)
        case .fileDiff(_, nil, let error)?: return .failure(ReplyError(message: error ?? "No diff."))
        default: return .failure(ReplyError(message: "\(mac.name) didn't answer."))
        }
    }

    /// Relative paths of the tab's worktree, as the Mac's Files panel lists them.
    func fileList(for paneId: PaneID) async -> Result<[String], ReplyError> {
        switch await request({ PhoneMessage.requestFileList(requestId: $0, paneId: paneId) }) {
        case .fileList(_, let paths?, _)?: return .success(paths)
        case .fileList(_, nil, let error)?: return .failure(ReplyError(message: error ?? "No files."))
        default: return .failure(ReplyError(message: "\(mac.name) didn't answer."))
        }
    }

    func file(_ path: String, in paneId: PaneID) async -> Result<RemoteFile, ReplyError> {
        switch await request({ PhoneMessage.requestFile(requestId: $0, paneId: paneId, path: path) }) {
        case .fileContent(_, let file?, _)?: return .success(file)
        case .fileContent(_, nil, let error)?: return .failure(ReplyError(message: error ?? "No file."))
        default: return .failure(ReplyError(message: "\(mac.name) didn't answer."))
        }
    }

    func devServers(for paneId: PaneID) async -> Result<[DevServerInfo], ReplyError> {
        switch await request({ PhoneMessage.requestDevServers(requestId: $0, paneId: paneId) }) {
        case .devServers(_, let servers?, _)?: return .success(servers)
        case .devServers(_, nil, let error)?: return .failure(ReplyError(message: error ?? "No servers."))
        default: return .failure(ReplyError(message: "\(mac.name) didn't answer."))
        }
    }

    struct ReplyError: Error {
        var message: String
    }

    private func request(_ make: (UUID) -> PhoneMessage) async -> MacMessage? {
        guard status == .online, let channel else { return nil }
        let requestId = UUID()
        let message = make(requestId)
        return await withCheckedContinuation { continuation in
            pendingReplies[requestId] = continuation
            channel.send(message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishReply(requestId, nil)
            }
        }
    }

    private func finishReply(_ requestId: UUID, _ message: MacMessage?) {
        pendingReplies.removeValue(forKey: requestId)?.resume(returning: message)
    }

    func reorderProjects(_ ids: [ProjectID]) {
        channel?.send(PhoneMessage.reorderProjects(ids: ids))
        // Show the new order now, among the listed projects only (the pinned
        // ones); the next snapshot confirms it.
        if var snapshot {
            let slots = snapshot.projects.indices.filter { ids.contains(snapshot.projects[$0].id) }
            let moved = ids.compactMap { id in snapshot.projects.first { $0.id == id } }
            for (slot, project) in zip(slots, moved) { snapshot.projects[slot] = project }
            self.snapshot = snapshot
        }
    }

    func reportActivity(paneId: PaneID, token: String?) {
        if status == .online, let channel {
            channel.send(PhoneMessage.registerActivity(paneId: paneId, token: token))
        } else {
            pendingActivityTokens[paneId] = token
        }
    }

    func closeSession(paneId: PaneID) {
        channel?.send(PhoneMessage.closeSession(paneId: paneId))
        // Drop the row now; the next snapshot confirms.
        snapshot?.sessions.removeAll { $0.id == paneId }
    }

    /// Pin to Top or unpin. The Mac re-sorts; the next snapshot carries it.
    func setProjectPinned(_ id: ProjectID, _ pinned: Bool) {
        channel?.send(PhoneMessage.setProjectPinned(id: id, pinned: pinned))
        if var snapshot, let i = snapshot.projects.firstIndex(where: { $0.id == id }) {
            snapshot.projects[i].pinned = pinned
            if pinned { snapshot.projects[i].active = true }
            self.snapshot = snapshot
        }
    }

    /// Make Active or Move to Inactive.
    func setProjectActive(_ id: ProjectID, _ active: Bool) {
        channel?.send(PhoneMessage.setProjectActive(id: id, active: active))
        if var snapshot, let i = snapshot.projects.firstIndex(where: { $0.id == id }) {
            snapshot.projects[i].active = active
            if !active { snapshot.projects[i].pinned = false }
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

    /// Stops Claude's current turn in that tab.
    func interrupt(_ paneId: PaneID) {
        channel?.send(PhoneMessage.interrupt(paneId: paneId))
    }

    func answer(_ requestId: UUID, answer: String) {
        channel?.send(PhoneMessage.answerQuestion(requestId: requestId, answer: answer))
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
        case .projectIcons(let icons):
            projectIcons = Dictionary(icons.compactMap { icon in
                PlatformImage(data: icon.png).map { (icon.id, $0) }
            }, uniquingKeysWith: { _, latest in latest })
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            #if os(iOS)
            LiveActivities.reconcile(macId: mac.id, snapshot: snapshot)
            #endif
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
        case .changes(let requestId, _, _), .fileDiff(let requestId, _, _), .history(let requestId, _, _),
             .fileList(let requestId, _, _), .fileContent(let requestId, _, _), .devServers(let requestId, _, _):
            finishReply(requestId, message)
        case .error(let message):
            print("Mac says: \(message)")
        }
    }

    private func didConnect() {
        status = .online
        attempt = 0
        if let pushRegistration { channel?.send(PhoneMessage.registerPush(pushRegistration)) }
        for (paneId, token) in pendingActivityTokens {
            channel?.send(PhoneMessage.registerActivity(paneId: paneId, token: token))
        }
        pendingActivityTokens = [:]
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
        for id in Array(pendingReplies.keys) { finishReply(id, nil) }
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

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
