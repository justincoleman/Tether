import SwiftUI
import TetherProtocol

struct SessionRoute: Hashable {
    var macId: UUID
    var paneId: PaneID
}

/// Every paired Mac's projects in the Mac's sidebar order, each with its
/// Claude tabs underneath. Anything waiting on you is pinned on top.
struct OverviewView: View {
    @Environment(PhoneStore.self) private var store
    @Binding var showPairing: Bool
    @State private var path = NavigationPath()
    @State private var answering: (connection: MacConnection, request: PermissionRequested)?
    @State private var newTask: NewTaskTarget?
    @State private var reordering: MacConnection?

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
                    list
                }
            }
            .navigationTitle("Tether")
            .navigationDestination(for: SessionRoute.self) { route in
                if let connection = store.connection(route.macId) {
                    SessionView(connection: connection, paneId: route.paneId)
                }
            }
            .toolbar { toolbar }
            .sheet(item: $newTask) { target in
                NewTaskView(initialMacId: target.macId, initialProjectId: target.projectId) { route in
                    path.append(route)
                }
                .environment(store)
            }
            .sheet(item: $reordering) { connection in
                ReorderProjectsView(connection: connection)
            }
            .sheet(isPresented: Binding(get: { answering != nil }, set: { if !$0 { answering = nil } })) {
                if let answering {
                    PermissionSheet(connection: answering.connection, request: answering.request)
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }

    private var list: some View {
        List {
            let waiting = store.connections.flatMap { c in
                (c.snapshot?.permissions ?? []).map { WaitingPermission(connection: c, request: $0) }
            }
            if !waiting.isEmpty {
                Section("Needs you") {
                    ForEach(waiting) { item in
                        Button { answering = (item.connection, item.request) } label: {
                            PermissionRow(request: item.request, snapshot: item.connection.snapshot)
                        }
                    }
                }
            }
            ForEach(store.connections) { connection in
                MacProjects(connection: connection, showMacName: store.connections.count > 1) { projectId in
                    newTask = NewTaskTarget(macId: connection.id, projectId: projectId)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { store.connectAll() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let editable = store.connections.filter { $0.snapshot != nil }
        if !editable.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                if editable.count == 1 {
                    Button("Edit") { reordering = editable[0] }
                } else {
                    Menu("Edit") {
                        ForEach(editable) { c in
                            Button("Projects on \(c.mac.name)") { reordering = c }
                        }
                    }
                }
            }
        }
        if !store.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newTask = NewTaskTarget(macId: nil, projectId: nil) } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New task")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Pair a Mac", systemImage: "qrcode.viewfinder") { showPairing = true }
                ForEach(store.connections) { connection in
                    Button("Remove \(connection.mac.name)", systemImage: "trash", role: .destructive) {
                        store.remove(connection.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct WaitingPermission: Identifiable {
    let connection: MacConnection
    let request: PermissionRequested
    var id: UUID { request.id }
}

struct NewTaskTarget: Identifiable {
    let id = UUID()
    var macId: UUID?
    var projectId: ProjectID?
}

/// One Mac: a status row when it matters, then a section per project.
private struct MacProjects: View {
    let connection: MacConnection
    let showMacName: Bool
    let startTask: (ProjectID) -> Void

    var body: some View {
        if showMacName || connection.status != .online || connection.snapshot == nil {
            Section {
                HStack {
                    Label(connection.mac.name, systemImage: "desktopcomputer")
                    Spacer()
                    ConnectionStatusLabel(status: connection.status)
                }
                .font(.subheadline)
                if case .offline(let reason) = connection.status {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if case .rejected(let reason) = connection.status {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let snapshot = connection.snapshot {
            ForEach(snapshot.projects) { project in
                let sessions = snapshot.sessions.filter { $0.projectId == project.id }
                Section {
                    if sessions.isEmpty {
                        Button("Start a task", systemImage: "plus") { startTask(project.id) }
                            .font(.subheadline)
                    }
                    ForEach(sessions) { session in
                        NavigationLink(value: SessionRoute(macId: connection.id, paneId: session.id)) {
                            ThreadRow(session: session)
                        }
                    }
                } header: {
                    ProjectHeader(project: project, sessions: sessions) { startTask(project.id) }
                }
            }
        }
    }
}

private struct ProjectHeader: View {
    let project: ProjectSummary
    let sessions: [SessionSummary]
    let startTask: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProjectTile(name: project.name)
            VStack(alignment: .leading, spacing: 0) {
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let branch = project.branch {
                    Text(branch).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button(action: startTask) {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .accessibilityLabel("New task in \(project.name)")
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

/// Letter tile, colored like the Mac sidebar in its system appearance.
struct ProjectTile: View {
    let name: String

    private static let colors: [Color] = [.red, .orange, .green, .blue, .purple, .teal]

    /// FNV-1a, the same as ChromePalette.avatarIndex on the Mac.
    private var color: Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Self.colors[Int(hash % UInt64(Self.colors.count))]
    }

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One Claude tab: status, title, and the latest message.
private struct ThreadRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhoneStatusBadge(state: session.state)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    if let note = session.statusNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(session.state == .needsInput ? Color.blue : Color.secondary)
                    }
                }
                Text(session.preview ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .opacity(session.state == .detached ? 0.5 : 1)
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
    let snapshot: Snapshot?

    private var prefix: String {
        projectName.map { $0 + ": " } ?? ""
    }

    private var projectName: String? {
        guard let snapshot, let pane = request.paneId,
              let session = snapshot.sessions.first(where: { $0.id == pane }) else { return nil }
        return snapshot.projects.first { $0.id == session.projectId }?.name
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(prefix + "Claude wants to " + request.title.lowercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(request.detail).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary)
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
        case .detached: return "Ended"
        default: return nil
        }
    }
}
