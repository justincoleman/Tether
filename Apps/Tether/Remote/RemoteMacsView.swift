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
    @State private var showingPair = false

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
                        Button("Pair a Mac…") { showingPair = true }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { showingPair = true } label: {
                    Label("Pair a Mac…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(10)
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
        .sheet(isPresented: $showingPair) { PairMacSheet() }
        .onAppear { remote.connectAll() }
        .onDisappear { remote.disconnectAll() }
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
            Text("To pair again, copy a new link from its Settings. To revoke this Mac there too, remove it from its paired devices.")
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
private struct RemoteSessionView: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    @State private var text = ""

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
            header
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
        .task(id: sessionId) { connection.subscribe(sessionId) }
        .onDisappear { connection.subscribe(nil) }
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

/// Paste the link the other Mac shows under its pairing QR code.
private struct PairMacSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var link = ""
    @State private var error: String?
    @State private var startCount = 0

    var body: some View {
        let remote = model.remote
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair a Mac").font(.title2.bold())
            Text("On the other Mac, open Tether → Settings → iPhone, click Pair iPhone or Mac…, then Copy Link, and paste it here. Both Macs need Tailscale on the same tailnet. The link expires after a few minutes.")
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("tether://pair?…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            if let error {
                Text(error).foregroundStyle(theme.red).font(.callout)
            } else if let pairing = remote.pairing {
                HStack(spacing: 6) {
                    switch pairing.status {
                    case .rejected(let reason):
                        Text(reason).foregroundStyle(theme.red)
                    case .offline(let reason):
                        Text("Couldn't reach \(pairing.mac.name): \(reason)").foregroundStyle(theme.red)
                    case .updateNeeded:
                        Text("Update Tether on both Macs to the same version.").foregroundStyle(theme.red)
                    case .connecting, .online:
                        ProgressView().controlSize(.small)
                        Text("Pairing with \(pairing.mac.name)…")
                    }
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    remote.cancelPairing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Pair", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            startCount = remote.pairedCount
            // Prefill from the clipboard when it holds a pairing link.
            if let text = NSPasteboard.general.string(forType: .string), text.hasPrefix("tether://pair") {
                link = text
            }
        }
        .onChange(of: remote.pairedCount) {
            if remote.pairedCount > startCount { dismiss() }
        }
    }

    private func start() {
        error = model.remote.pair(text: link, ownName: model.companion.macName)
    }
}
