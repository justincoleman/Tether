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
    @AppStorage("useMacColors") private var useMacColors = true

    /// The first paired Mac that reports its colors.
    private var macTheme: MacTheme? {
        store.connections.lazy.compactMap { $0.snapshot?.theme }.first
    }

    /// What `.macColors` puts in the environment, for this view's own rows.
    private var theme: PhoneTheme {
        (useMacColors ? macTheme.flatMap(PhoneTheme.init(mac:)) : nil) ?? .system
    }

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
                            .tint(theme.claude)
                    }
                } else {
                    list
                }
            }
            .macColors(macTheme)
            .navigationTitle("Tether")
            .toolbarTitleDisplayMode(.inlineLarge)
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
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.connections) { MacStatusChip(connection: $0) }
                        }
                    }
                    .scrollClipDisabled()
                    if let summary = activitySummary {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                    ForEach(store.connections) { MacNotice(connection: $0) }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // Not flush with the edge: the section clips anything that touches it.
                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 4, trailing: 6))
            }
            let waiting = store.connections.flatMap { c in
                (c.snapshot?.permissions ?? []).map { WaitingPermission(connection: c, request: $0) }
            }
            // A section each, so every request is its own rounded card that the
            // list draws (and clips) itself.
            ForEach(waiting) { item in
                Section {
                    NeedsYouCard(connection: item.connection, request: item.request,
                                 context: item.context, framed: false) {
                        answering = (item.connection, item.request)
                    }
                    .listRowBackground(NeedsYouCard.rowBackground(theme))
                } header: {
                    if item.id == waiting.first?.id {
                        SectionLabel(title: "Needs you", count: waiting.count)
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
        .listSectionSpacing(.compact)
        .refreshable { store.connectAll() }
    }

    /// "2 working · 1 done", across every Mac.
    private var activitySummary: String? {
        let sessions = store.connections.flatMap { $0.snapshot?.sessions ?? [] }
        guard !sessions.isEmpty else { return nil }
        let working = sessions.filter { $0.state == .working }.count
        // A folder-trust prompt can come from a tab that still reads idle.
        let permissions = store.connections.reduce(0) { $0 + ($1.snapshot?.permissions.count ?? 0) }
        let waiting = max(sessions.filter { $0.state == .needsInput }.count, permissions)
        let done = sessions.filter { $0.state == .done }.count
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if working > 0 { parts.append("\(working) working") }
        if done > 0 { parts.append("\(done) done") }
        if parts.isEmpty { return "\(sessions.count) Claude tab\(sessions.count == 1 ? "" : "s"), all quiet" }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let editable = store.connections.filter { $0.snapshot != nil }
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
                if editable.count == 1 {
                    Button("Edit Projects", systemImage: "list.bullet") { reordering = editable[0] }
                } else if !editable.isEmpty {
                    Menu("Edit Projects", systemImage: "list.bullet") {
                        ForEach(editable) { c in
                            Button("Projects on \(c.mac.name)") { reordering = c }
                        }
                    }
                }
                Button("Pair a Mac", systemImage: "qrcode.viewfinder") { showPairing = true }
                Toggle("Use Mac's Colors", systemImage: "paintpalette", isOn: $useMacColors)
                ForEach(store.connections) { connection in
                    Button("Remove \(connection.mac.name)", systemImage: "trash", role: .destructive) {
                        store.remove(connection.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
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

    /// "Tether · Claude": the project and tab that asked.
    @MainActor var context: String? {
        guard let snapshot = connection.snapshot, let pane = request.paneId,
              let session = snapshot.sessions.first(where: { $0.id == pane }) else { return nil }
        let project = snapshot.projects.first { $0.id == session.projectId }?.name
        return [project, session.title].compactMap { $0 }.joined(separator: " · ")
    }
}

struct NewTaskTarget: Identifiable {
    let id = UUID()
    var macId: UUID?
    var projectId: ProjectID?
}

/// One Mac: its plan usage, then a section per project.
private struct MacProjects: View {
    @Environment(\.phoneTheme) private var theme
    let connection: MacConnection
    let showMacName: Bool
    let startTask: (ProjectID) -> Void
    let askToClose: (SessionSummary) -> Void
    @State private var showInactive = false

    var body: some View {
        if let limits = connection.snapshot?.limits, limits.fiveHour != nil || limits.sevenDay != nil {
            Section {
                UsageCard(limits: limits, macName: showMacName ? connection.mac.name : nil)
                    .listRowBackground(theme.card)
            }
        }
        if let snapshot = connection.snapshot {
            // The Mac sends pinned, then Active by recent use, then Inactive.
            ForEach(snapshot.projects.filter(\.active)) { project in
                projectSection(project, snapshot: snapshot)
            }
            let inactive = snapshot.projects.filter { !$0.active }
            if !inactive.isEmpty {
                Section {
                    Button { withAnimation { showInactive.toggle() } } label: {
                        HStack {
                            Text("Inactive")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.text)
                            Text("\(inactive.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                                .rotationEffect(.degrees(showInactive ? 90 : 0))
                        }
                    }
                    .listRowBackground(theme.card)
                } footer: {
                    if !showInactive {
                        Text("Projects not used for a while. Long-press a project to pin it or move it here.")
                    }
                }
                if showInactive {
                    ForEach(inactive) { project in
                        projectSection(project, snapshot: snapshot)
                    }
                }
            }
        }
    }

    private func projectSection(_ project: ProjectSummary, snapshot: Snapshot) -> some View {
        let sessions = snapshot.sessions.filter { $0.projectId == project.id }
        return Section {
            if sessions.isEmpty {
                Button { startTask(project.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(theme.elevated, in: Circle())
                        Text("Start a task")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                .listRowBackground(theme.card)
            }
            ForEach(sessions) { session in
                NavigationLink(value: SessionRoute(macId: connection.id, paneId: session.id)) {
                    ThreadRow(session: session)
                }
                .listRowBackground(theme.card)
                .listRowSeparatorTint(theme.border)
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
                .contextMenu {
                    Button(project.pinned ? "Unpin" : "Pin to Top",
                           systemImage: project.pinned ? "pin.slash" : "pin") {
                        connection.setProjectPinned(project.id, !project.pinned)
                    }
                    Button(project.active ? "Move to Inactive" : "Make Active",
                           systemImage: project.active ? "moon.zzz" : "sun.max") {
                        connection.setProjectActive(project.id, !project.active)
                    }
                }
        }
    }
}

/// "NEEDS YOU  2", in the list's section header spot.
private struct SectionLabel: View {
    @Environment(\.phoneTheme) private var theme
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
            if let count, count > 1 {
                Text("\(count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.blue, in: Capsule())
            }
        }
        .textCase(nil)
    }
}

private struct ProjectHeader: View {
    @Environment(\.phoneTheme) private var theme
    let project: ProjectSummary
    let sessions: [SessionSummary]
    var icon: UIImage?
    let startTask: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProjectTile(name: project.name, icon: icon)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if project.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityLabel("Pinned")
                    }
                }
                if let branch = project.branch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            Button(action: startTask) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 30, height: 30)
                    .background(theme.card, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New task in \(project.name)")
        }
        .textCase(nil)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// Letter tile, colored like the Mac sidebar in its system appearance.
struct ProjectTile: View {
    let name: String
    /// The project's own app icon, when the Mac found one.
    var icon: UIImage?
    var size: CGFloat = 32

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
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// One Claude tab: status, title, mode, and the latest message.
private struct ThreadRow: View {
    @Environment(\.phoneTheme) private var theme
    let session: SessionSummary

    private var noteColor: Color {
        switch session.state {
        case .needsInput: theme.blue
        case .working: theme.claude
        case .error: theme.red
        default: theme.secondaryText
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhoneStatusBadge(state: session.state)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if let mode = session.permissionMode {
                        PermissionModeTag(mode: mode)
                    }
                    Spacer(minLength: 4)
                    if let note = session.statusNote {
                        Text(note)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(noteColor)
                            .lineLimit(1)
                    }
                }
                Text(session.preview ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(session.preview == nil ? theme.tertiaryText : theme.secondaryText)
                    .lineLimit(2)
                if let summary = session.status?.summary {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(session.state == .detached ? 0.5 : 1)
    }
}

extension SessionStatus {
    /// "Opus 5.5 · $1.23", or whichever half is known.
    var summary: String? {
        let parts = [modelName, costUSD.map { $0.formatted(.currency(code: "USD")) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
