import SwiftUI
import TetherProtocol

struct SessionRoute: Hashable {
    var macId: UUID
    var paneId: PaneID
}

/// Every Claude tab on every paired Mac, waiting ones first.
struct OverviewView: View {
    @Environment(PhoneStore.self) private var store
    @Binding var showPairing: Bool
    @State private var path = NavigationPath()
    @State private var answering: (connection: MacConnection, request: PermissionRequested)?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.isEmpty {
                    ContentUnavailableView {
                        Label("No Macs paired", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text("On your Mac, open Tether → Settings → iPhone and click Pair iPhone.")
                    } actions: {
                        Button("Pair a Mac") { showPairing = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.connections) { connection in
                            MacSection(connection: connection) { request in
                                answering = (connection, request)
                            }
                        }
                    }
                    .refreshable { store.connectAll() }
                }
            }
            .navigationTitle("Overview")
            .navigationDestination(for: SessionRoute.self) { route in
                if let connection = store.connection(route.macId) {
                    SessionView(connection: connection, paneId: route.paneId)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Pair a Mac", systemImage: "qrcode.viewfinder") { showPairing = true }
                        if !store.isEmpty {
                            Section("Paired Macs") {
                                ForEach(store.connections) { connection in
                                    Button("Remove \(connection.mac.name)", systemImage: "trash", role: .destructive) {
                                        store.remove(connection.id)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: Binding(get: { answering != nil }, set: { if !$0 { answering = nil } })) {
                if let answering {
                    PermissionSheet(connection: answering.connection, request: answering.request)
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }
}

private struct MacSection: View {
    let connection: MacConnection
    let answer: (PermissionRequested) -> Void

    var body: some View {
        Section {
            if let snapshot = connection.snapshot {
                ForEach(snapshot.permissions) { request in
                    Button { answer(request) } label: {
                        PermissionRow(request: request, snapshot: snapshot)
                    }
                }
                let sessions = snapshot.sessions.sorted { $0.state.urgency > $1.state.urgency }
                if sessions.isEmpty {
                    Text("No Claude tabs open.").foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    NavigationLink(value: SessionRoute(macId: connection.id, paneId: session.id)) {
                        SessionRow(session: session,
                                   project: snapshot.projects.first { $0.id == session.projectId })
                    }
                }
            } else if case .online = connection.status {
                ProgressView()
            }
        } header: {
            HStack {
                Text(connection.mac.name)
                Spacer()
                ConnectionStatusLabel(status: connection.status)
            }
        }
    }
}

struct ConnectionStatusLabel: View {
    let status: MacConnection.Status

    var body: some View {
        switch status {
        case .online:
            Label("Online", systemImage: "circle.fill").foregroundStyle(.green)
        case .connecting:
            Label("Connecting", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .offline:
            Label("Offline", systemImage: "circle").foregroundStyle(.secondary)
        case .updateNeeded:
            Label("Update needed", systemImage: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
        case .rejected:
            Label("Not paired", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }
}

private struct PermissionRow: View {
    let request: PermissionRequested
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude wants to \(request.title.lowercased())").font(.subheadline.weight(.semibold))
                Text(request.detail).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let project: ProjectSummary?

    var body: some View {
        HStack(spacing: 12) {
            PhoneStatusBadge(state: session.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(project?.name ?? "Project").font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Text(session.title)
                    if let branch = project?.branch { Text("· \(branch)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let note = session.statusNote {
                    Text(note).font(.caption).foregroundStyle(session.state == .needsInput ? Color.blue : Color.secondary)
                }
            }
        }
    }
}

struct PhoneStatusBadge: View {
    let state: SessionState

    var body: some View {
        Group {
            switch state {
            case .working:
                Image(systemName: "sparkles").foregroundStyle(.orange).symbolEffect(.pulse)
            case .needsInput:
                Image(systemName: "circle.fill").foregroundStyle(.blue).symbolEffect(.pulse)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .idle, .detached:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 22)
    }
}

extension SessionState {
    var urgency: Int {
        switch self {
        case .needsInput: 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        case .detached: 0
        }
    }
}

extension SessionSummary {
    var statusNote: String? {
        if state == .needsInput {
            switch attention {
            case .permission: return "Needs permission"
            case .question: return "Asked you a question"
            case .dialog: return "Waiting on a prompt on the Mac"
            case nil: return "Needs your input"
            }
        }
        if queued > 0 { return "\(queued) queued" }
        switch state {
        case .working: return "Working"
        case .detached: return "Claude isn't running"
        default: return nil
        }
    }
}
