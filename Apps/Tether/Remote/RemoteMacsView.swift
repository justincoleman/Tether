import AppKit
import SwiftUI
import TetherCore
import TetherProtocol

/// The Remote Macs window: Claude tabs on other Macs running Tether, paired
/// like an iPhone. Read the conversation, answer permissions, send messages.
struct RemoteMacsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var selection: RemoteSelection?

    var body: some View {
        let remote = model.remote
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(remote.connections) { connection in
                    Section {
                        sessions(of: connection)
                    } header: {
                        MacHeader(connection: connection) { remote.remove(connection.id) }
                    }
                }
            }
            .overlay {
                if remote.connections.isEmpty {
                    ContentUnavailableView {
                        Label("No Macs paired", systemImage: "desktopcomputer")
                    } description: {
                        Text("Pair another Mac running Tether to follow its Claude tabs from here.")
                    } actions: {
                        SettingsLink { Text("Pair a Mac in Settings…") }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let selection, let connection = remote.connection(selection.macId) {
                RemoteSessionView(connection: connection, paneId: selection.paneId)
                    .id(selection)
            } else {
                ContentUnavailableView("Pick a Claude tab", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .background(theme.window)
        .onAppear { remote.retain() }
        .onDisappear { remote.release() }
    }

    @ViewBuilder
    private func sessions(of connection: MacConnection) -> some View {
        let snapshot = connection.snapshot
        let projects = snapshot?.projects ?? []
        ForEach(snapshot?.sessions ?? []) { session in
            let project = projects.first { $0.id == session.projectId }
            RemoteSessionRow(session: session, projectName: project?.name ?? "Project",
                             waiting: snapshot?.permissions.contains { $0.paneId == session.id } ?? false)
                .tag(RemoteSelection(macId: connection.id, paneId: session.id))
        }
        if connection.status == .online, snapshot?.sessions.isEmpty ?? true {
            Text("No Claude tabs open").foregroundStyle(theme.secondaryText)
        }
    }
}

struct RemoteSelection: Hashable {
    var macId: UUID
    var paneId: PaneID
}

private struct MacHeader: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let remove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(connection.mac.name)
            Spacer()
            Menu {
                if case .offline = connection.status {
                    Button("Reconnect") { connection.connect() }
                }
                Button("Forget This Mac…", role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(statusText)
        .confirmationDialog("Forget \(connection.mac.name)?", isPresented: $confirmRemove) {
            Button("Forget", role: .destructive, action: remove)
        } message: {
            Text("To pair again, copy a new link from its Settings → Macs tab. To revoke this Mac there too, remove it from its paired devices.")
        }
    }

    private var color: Color {
        switch connection.status {
        case .online: theme.green
        case .connecting: theme.claude
        case .offline, .updateNeeded, .rejected: theme.red
        }
    }

    private var statusText: String {
        switch connection.status {
        case .online: "Connected"
        case .connecting: "Connecting…"
        case .offline(let reason): "Offline: \(reason)"
        case .updateNeeded(let version): "Update Tether on both Macs (protocol \(version) vs \(ProtocolVersion.current))."
        case .rejected(let reason): reason
        }
    }
}

private struct RemoteSessionRow: View {
    @Environment(\.theme) private var theme
    let session: SessionSummary
    let projectName: String
    let waiting: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(state: session.state).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(projectName).lineLimit(1)
                Text(session.statusNote ?? session.preview ?? session.title)
                    .font(.caption)
                    .foregroundStyle(waiting ? theme.blue : theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One remote tab: its conversation, any permission it's waiting on, and a
/// compose box. Messages queue on the other Mac like the phone's do.
struct RemoteSessionView: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    /// The Remote Macs window has no tab strip above it, so it draws its own.
    let showsHeader: Bool
    @State private var text = ""

    init(connection: MacConnection, paneId: PaneID, showsHeader: Bool = true) {
        self.connection = connection
        self.paneId = paneId
        self.showsHeader = showsHeader
    }

    private var session: SessionSummary? {
        connection.snapshot?.sessions.first { $0.id == paneId }
    }

    private var permission: PermissionRequested? {
        connection.snapshot?.permissions.first { $0.paneId == paneId }
    }

    var body: some View {
        let sessionId = session?.sessionId
        let transcript = sessionId.flatMap { connection.transcripts[$0] }
        VStack(spacing: 0) {
            if showsHeader {
                header
            } else {
                chatHeader(transcript)
            }
            Divider()
            if let transcript, !transcript.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(transcript.items) { item in
                                TranscriptItemView(item: item).id(item.id)
                            }
                            if session?.state == .working {
                                ProgressView().controlSize(.small).id("working")
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: MirrorView.columnWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: transcript.items.count, initial: true) {
                        if let last = transcript.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            } else {
                ContentUnavailableView(session == nil ? "Tab closed" : "Nothing yet",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(session == nil
                                           ? "This Claude tab is no longer open on \(connection.mac.name)."
                                           : "Messages appear here as Claude works."))
                    .frame(maxHeight: .infinity)
            }
            if let permission {
                PermissionBar(request: permission) { allow in connection.decide(permission.id, allow: allow) }
            }
            if session != nil {
                compose
            }
        }
        // Also on each state change, so a subscription that went missing
        // heals itself: the Mac answers with the whole transcript again.
        .task(id: "\(sessionId ?? "")-\(String(describing: session?.state))") {
            connection.subscribe(sessionId)
        }
        .onDisappear { if let sessionId { connection.unsubscribe(sessionId) } }
    }

    /// The strip above a chat on this Mac: its title, state and context use.
    private func chatHeader(_ transcript: TranscriptModel?) -> some View {
        HStack(spacing: 8) {
            Text("Chat").font(.headline)
            if let session { StatusBadge(state: session.state) }
            Spacer()
            if let status = session?.status {
                let parts = [status.modelName, status.costUSD.map { $0.formatted(.currency(code: "USD")) }]
                    .compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            if let limits = connection.snapshot?.limits {
                PlanUsageMeters(limits: limits)
            }
            if let usage = transcript?.usage {
                ContextMeter(usage: usage.reported(window: session?.status?.contextWindow))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let session {
                StatusBadge(state: session.state)
                Text(connection.snapshot?.projects.first { $0.id == session.projectId }?.name ?? "Session")
                    .font(.headline)
                Text(session.title).foregroundStyle(theme.secondaryText).lineLimit(1)
            }
            Spacer()
            if let model = session?.status?.modelName {
                Text(model).font(.caption).foregroundStyle(theme.secondaryText)
            }
            Text("on \(connection.mac.name)").font(.caption).foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var canSend: Bool {
        connection.status == .online && session?.state != .detached
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var note: String? {
        switch connection.sendResults[paneId] {
        case "queued"?: return "Queued. \(connection.mac.name) sends it when Claude is ready."
        case "failed"?: return "\(connection.mac.name) couldn't send that."
        default: break
        }
        guard let session else { return nil }
        if session.state == .working { return "Claude is working. Your message waits for this turn to finish." }
        if session.state == .needsInput, session.attention == .dialog {
            return "Claude is waiting on a prompt only \(connection.mac.name) can answer."
        }
        return nil
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Claude on \(connection.mac.name)", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? theme.accent : theme.secondaryText)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 0.5))
            if let note {
                Text(note).font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: MirrorView.columnWidth)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        guard canSend else { return }
        connection.send(text, to: paneId)
        text = ""
    }
}

private struct PermissionBar: View {
    @Environment(\.theme) private var theme
    let request: PermissionRequested
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Claude wants to \(request.title.lowercased())", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(theme.blue)
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text(request.toolName).font(.caption.monospaced()).foregroundStyle(theme.secondaryText)
                Spacer()
                Button("Deny") { decide(false) }
                Button("Allow") { decide(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(theme.elevated)
    }
}
