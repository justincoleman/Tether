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
    let pushSettings = PushSettings()
    /// The last APNs failure, shown in Settings; nil after a success.
    private(set) var pushProblem: String?

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let server = CompanionServer()
    @ObservationIgnored private let auth = CompanionAuth(
        fileURL: ProjectStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("companion.json"))
    @ObservationIgnored private var clients: [ObjectIdentifier: CompanionClient] = [:]
    @ObservationIgnored private let sender = PushSender()
    @ObservationIgnored private var macId: UUID?
    /// When each tab's current working stretch began, for the activity timer.
    @ObservationIgnored private var workingSince: [PaneID: Date] = [:]
    /// Live Activity updates are sent at most every `activityInterval`.
    @ObservationIgnored private var lastActivityPush: [PaneID: Date] = [:]
    @ObservationIgnored private var pendingActivity: [PaneID: LiveActivityContent] = [:]
    @ObservationIgnored private let activityInterval: TimeInterval = 10
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
        Task {
            self.devices = await self.auth.devices
            self.macId = await self.auth.macId
        }
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
        model?.updatePolling()
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
        if let icons = model?.companionProjectIcons(), !icons.isEmpty {
            client.send(.projectIcons(icons))
        }
    }

    /// The icon set changed (or the setting did): resend it to every phone.
    func sendProjectIcons() {
        guard let icons = model?.companionProjectIcons() else { return }
        for client in clients.values where client.device != nil {
            client.send(.projectIcons(icons))
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
        case .setModel(let paneId, let name):
            let outcome: String = switch model.setModel(name, forPane: paneId) {
            case .sent: "sent"
            case .queued: "queued"
            case .failed: "failed"
            }
            client.send(.sendResult(paneId: paneId, outcome: outcome))
        case .interrupt(let paneId):
            model.interrupt(pane: paneId)
        case .permissionDecision(let requestId, let allow):
            model.resolvePermission(requestId, allow ? .allow : .deny(message: "Denied from iPhone."))
        case .answerQuestion(let requestId, let answer):
            model.answerQuestion(requestId, answer: answer)
        case .startSession(let requestId, let projectId, let branch, let prompt, let permissionMode):
            Task {
                do {
                    let paneId = try await model.startSession(projectId: projectId, branch: branch, prompt: prompt,
                                                              permissionMode: permissionMode, select: false)
                    client.send(.startResult(requestId: requestId, paneId: paneId, error: nil))
                } catch {
                    client.send(.startResult(requestId: requestId, paneId: nil, error: "\(error)"))
                }
            }
        case .reorderProjects(let ids):
            Task { await model.reorderProjects(ids) }
        case .closeSession(let paneId):
            Task { await model.closePane(paneId) }
        case .renameProject(let id, let name):
            Task { await model.renameProject(id, to: name) }
        case .registerPush(let registration):
            guard let device = client.device else { return }
            Task {
                await auth.setPush(registration, for: device.id)
                devices = await auth.devices
            }
        case .registerActivity(let paneId, let token):
            guard let device = client.device else { return }
            Task {
                await auth.setActivityToken(token, pane: paneId.uuidString, for: device.id)
                devices = await auth.devices
            }
        case .requestChanges(let requestId, let paneId):
            switch model.changesForPhone(paneId: paneId) {
            case .success(let snapshot):
                client.send(.changes(requestId: requestId, snapshot: snapshot, error: nil))
            case .failure(let error):
                client.send(.changes(requestId: requestId, snapshot: nil, error: error.message))
            }
        case .requestDiff(let requestId, let paneId, let file):
            Task {
                switch await model.diffForPhone(paneId: paneId, file: file) {
                case .success(let diff):
                    client.send(.fileDiff(requestId: requestId, diff: diff, error: nil))
                case .failure(let error):
                    client.send(.fileDiff(requestId: requestId, diff: nil, error: error.message))
                }
            }
        case .requestFileList(let requestId, let paneId):
            Task {
                switch await model.fileListForPhone(paneId: paneId) {
                case .success(let paths):
                    client.send(.fileList(requestId: requestId, paths: paths, error: nil))
                case .failure(let error):
                    client.send(.fileList(requestId: requestId, paths: nil, error: error.message))
                }
            }
        case .requestFile(let requestId, let paneId, let path):
            Task {
                switch await model.fileForPhone(paneId: paneId, path: path) {
                case .success(let file):
                    client.send(.fileContent(requestId: requestId, file: file, error: nil))
                case .failure(let error):
                    client.send(.fileContent(requestId: requestId, file: nil, error: error.message))
                }
            }
        case .requestDevServers(let requestId, let paneId):
            Task {
                switch await model.devServersForPhone(paneId: paneId) {
                case .success(let servers):
                    client.send(.devServers(requestId: requestId, servers: servers, error: nil))
                case .failure(let error):
                    client.send(.devServers(requestId: requestId, servers: nil, error: error.message))
                }
            }
        case .requestHistory(let requestId, let projectId):
            Task {
                let sessions = await model.pastSessions(for: projectId).map {
                    PastSessionInfo(id: $0.id, title: $0.title, firstPrompt: $0.firstPrompt,
                                    branch: $0.branch, lastActivity: $0.lastActivity)
                }
                client.send(.history(requestId: requestId, sessions: sessions, error: nil))
            }
        case .resumeSession(let requestId, let projectId, let sessionId):
            Task {
                do {
                    let paneId = try await model.resumePastSession(sessionId, projectId: projectId, select: false)
                    client.send(.startResult(requestId: requestId, paneId: paneId, error: nil))
                } catch {
                    client.send(.startResult(requestId: requestId, paneId: nil, error: "\(error)"))
                }
            }
        case .sendImage(let paneId, let image, let text):
            let outcome: String = switch model.sendImage(image, text: text, toPane: paneId) {
            case .sent: "sent"
            case .queued: "queued"
            case .failed: "failed"
            }
            client.send(.sendResult(paneId: paneId, outcome: outcome))
        case .hello, .pair, .authenticate:
            break
        }
    }

    // MARK: Push

    /// A tab changed state: alerts and Live Activity changes for every phone.
    func sessionChanged(paneId: PaneID, projectName: String, title: String, previous: SessionState?,
                        state: SessionState, attention: AttentionReason?, preview: String?, steps: Int) {
        let active: Set<SessionState> = [.working, .needsInput]
        if state == .working, !(previous.map(active.contains) ?? false) { workingSince[paneId] = Date() }
        guard let macId else { return }
        let change = PushPlanner.Change(
            macId: macId, paneId: paneId, projectName: projectName, title: title, previous: previous,
            state: state, attention: attention, preview: preview, steps: steps,
            startedAt: workingSince[paneId] ?? Date())
        if !active.contains(state) { workingSince[paneId] = nil }
        deliver(PushPlanner.intents(for: change))
    }

    func permissionRequested(_ request: PermissionRequested, projectName: String) {
        deliver([.permission(request, projectName: projectName)])
    }

    /// New transcript output while working: refresh the Live Activity, throttled.
    func activityContentChanged(paneId: PaneID, state: SessionState, preview: String?, steps: Int) {
        guard let since = workingSince[paneId] else { return }
        let content = LiveActivityContent(state: state.rawValue, detail: preview ?? "", steps: steps,
                                          startedAt: since.timeIntervalSince1970)
        deliver([.activityUpdate(paneId: paneId, content)])
    }

    /// Settings → Send Test Notification.
    func sendTest() {
        guard let macId else { return }
        let request = PermissionRequested(id: UUID(), paneId: nil, sessionId: "test", toolName: "Test",
                                          title: "Send a test notification", detail: "Notifications from \(macName) work.")
        Task { await send(.permission(request, projectName: "Tether"), macId: macId) }
    }

    private func deliver(_ intents: [PushIntent]) {
        guard let macId, !intents.isEmpty, pushSettings.isComplete else { return }
        for intent in intents {
            if case .activityUpdate(let paneId, let content) = intent {
                throttleActivity(paneId: paneId, content: content, macId: macId)
            } else {
                if case .activityEnd(let paneId, _) = intent {
                    pendingActivity[paneId] = nil
                    lastActivityPush[paneId] = nil
                }
                Task { await send(intent, macId: macId) }
            }
        }
    }

    private func throttleActivity(paneId: PaneID, content: LiveActivityContent, macId: UUID) {
        let wait = (lastActivityPush[paneId].map { activityInterval - Date().timeIntervalSince($0) }) ?? 0
        if wait <= 0 {
            lastActivityPush[paneId] = Date()
            Task { await send(.activityUpdate(paneId: paneId, content), macId: macId) }
            return
        }
        let alreadyScheduled = pendingActivity[paneId] != nil
        pendingActivity[paneId] = content
        guard !alreadyScheduled else { return }
        Task {
            try? await Task.sleep(for: .seconds(wait))
            guard let latest = pendingActivity.removeValue(forKey: paneId) else { return }
            lastActivityPush[paneId] = Date()
            await send(.activityUpdate(paneId: paneId, latest), macId: macId)
        }
    }

    private func send(_ intent: PushIntent, macId: UUID) async {
        guard let credentials = pushSettings.credentials() else { return }
        let request = PushPayload.request(for: intent, macId: macId)
        for device in await auth.devices {
            guard let push = device.push else { continue }
            let token: String?
            switch intent {
            case .activityStart(let attributes, let content):
                // A tab whose activity is still alive gets an update instead.
                if let existing = device.activityTokens?[attributes.paneId] {
                    let update = PushPayload.request(for: .activityUpdate(paneId: UUID(), content), macId: macId)
                    await post(update, token: existing, device: device, push: push, credentials: credentials)
                    continue
                }
                token = push.pushToStartToken
            case .activityUpdate(let paneId, _), .activityEnd(let paneId, _):
                token = device.activityTokens?[paneId.uuidString]
                if case .activityEnd = intent, token != nil {
                    await auth.setActivityToken(nil, pane: paneId.uuidString, for: device.id)
                }
            default:
                token = push.deviceToken
            }
            guard let token else { continue }
            await post(request, token: token, device: device, push: push, credentials: credentials)
        }
    }

    private func post(_ request: APNsRequest, token: String, device: PairedDevice, push: PushRegistration,
                         credentials: PushSender.Credentials) async {
        let result = await sender.send(request, token: token, bundleId: push.bundleId, sandbox: push.sandbox,
                                       credentials: credentials)
        switch result {
        case .sent:
            pushProblem = nil
        case .unregistered:
            if token == push.deviceToken {
                await auth.dropDeviceToken(token)
            } else {
                // A dead activity token: that activity is gone.
                for (pane, t) in device.activityTokens ?? [:] where t == token {
                    await auth.setActivityToken(nil, pane: pane, for: device.id)
                }
            }
            devices = await auth.devices
        case .failed(let reason):
            pushProblem = "Push to \(device.name) failed: \(reason)"
            print("APNs: \(pushProblem ?? "")")
        }
    }
}
