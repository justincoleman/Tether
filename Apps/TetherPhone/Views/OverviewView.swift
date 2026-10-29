import SwiftUI
import TetherProtocol
import UIKit

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
    @State private var closeRequest: CloseRequest?

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
            .onChange(of: store.openRoute, initial: true) { _, route in
                // From a notification tap or a Live Activity.
                guard let route else { return }
                store.openRoute = nil
                path = NavigationPath([route])
            }
            .sheet(item: $newTask) { target in
                NewTaskView(initialMacId: target.macId, initialProjectId: target.projectId) { route in
                    path.append(route)
                }
                .environment(store)
            }
            // Presented from here, not from the row: a swiped row is being torn
            // down and takes its dialog with it.
            .confirmationDialog("Close this thread?", isPresented: Binding(get: { closeRequest != nil },
                                                                           set: { if !$0 { closeRequest = nil } }),
                                titleVisibility: .visible, presenting: closeRequest) { request in
                Button("Close “\(request.session.title)”", role: .destructive) {
                    request.connection.closeSession(paneId: request.session.id)
                }
            } message: { request in
                Text(request.session.state == .working
                     ? "Claude is working right now. Closing stops it."
                     : "The tab closes on \(request.connection.mac.name). The conversation stays in Claude's history.")
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
                MacProjects(connection: connection, showMacName: store.connections.count > 1,
                            startTask: { projectId in
                    newTask = NewTaskTarget(macId: connection.id, projectId: projectId)
                }, askToClose: { session in
                    closeRequest = CloseRequest(connection: connection, session: session)
                })
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

private struct CloseRequest: Identifiable {
    let connection: MacConnection
    let session: SessionSummary
    var id: PaneID { session.id }
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
    let askToClose: (SessionSummary) -> Void

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
        if let limits = connection.snapshot?.limits, limits.fiveHour != nil || limits.sevenDay != nil {
            Section(showMacName ? "Plan usage · \(connection.mac.name)" : "Plan usage") {
                if let limit = limits.fiveHour { UsageLimitRow(label: "5-hour", limit: limit) }
                if let limit = limits.sevenDay { UsageLimitRow(label: "Weekly", limit: limit) }
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Not role: .destructive, which animates the row away
                            // before the answer to "are you sure?" is known.
                            Button("Close", systemImage: "xmark.circle") { askToClose(session) }
                                .tint(.red)
                        }
                    }
                } header: {
                    ProjectHeader(project: project, sessions: sessions,
                                  icon: connection.projectIcons[project.id]) { startTask(project.id) }
                }
            }
        }
    }
}

private struct ProjectHeader: View {
    let project: ProjectSummary
    let sessions: [SessionSummary]
    var icon: UIImage?
    let startTask: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProjectTile(name: project.name, icon: icon)
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
    /// The project's own app icon, when the Mac found one.
    var icon: UIImage?

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
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                HStack(spacing: 6) {
                    Text(session.title).font(.subheadline.weight(.semibold))
                    if let mode = session.permissionMode {
                        PermissionModeTag(mode: mode)
                    }
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
                if let summary = session.status?.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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

/// One plan limit from Claude Code's status line, like its 5h and 7d bars.
private struct UsageLimitRow: View {
    let label: String
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(limit.usedPercent.rounded()))%").monospacedDigit()
            }
            .font(.subheadline)
            ProgressView(value: min(max(limit.usedPercent, 0), 100), total: 100)
                .tint(limit.usedPercent >= 90 ? .red : .orange)
            if let reset = limit.resetsAt {
                Text("Resets \(reset, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

extension SessionStatus {
    /// "Opus 5.5 · $1.23", or whichever half is known.
    var summary: String? {
        let parts = [modelName, costUSD.map { $0.formatted(.currency(code: "USD")) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
