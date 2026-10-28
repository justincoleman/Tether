import SwiftUI
import UniformTypeIdentifiers
import TetherProtocol

/// Header rows line up with the traffic lights, which the hidden title bar
/// leaves floating over the content.
enum ChromeMetrics {
    static let headerHeight: CGFloat = 44
    /// Room for the traffic lights at the window's leading edge.
    static let trafficLightsWidth: CGFloat = 78
    static let cardRadius: CGFloat = 10
}

/// Sidebar | terminal card | inspector, drawn by hand rather than with
/// NavigationSplitView so every surface takes the theme's colors.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0
    @AppStorage("inspectorWidth") private var inspectorWidth = 420.0

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(showSidebar: $showSidebar)
                    .frame(width: sidebarWidth)
                ColumnResizer(width: $sidebarWidth, range: 180...400, sign: 1)
            }
            detail
                .padding(.leading, showSidebar ? 0 : 8)
                .padding(.trailing, model.showInspector ? 0 : 8)
            if model.showInspector {
                ColumnResizer(width: $inspectorWidth, range: 300...720, sign: -1)
                InspectorView()
                    .frame(width: inspectorWidth)
            }
        }
        .background(theme.window)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.2), value: showSidebar)
        .animation(.snappy(duration: 0.2), value: model.showInspector)
        .fileImporter(isPresented: $model.addProjectRequested,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.addProject(at: url) }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedProjectId,
           let project = model.projects.first(where: { $0.id == id }) {
            TerminalTabsView(project: project, showSidebar: $showSidebar)
        } else {
            VStack(spacing: 0) {
                HStack {
                    if !showSidebar {
                        ChromeButton(systemImage: "sidebar.left", help: "Show sidebar (⌃⌘S)") { showSidebar = true }
                    }
                    Spacer()
                }
                .padding(.leading, showSidebar ? 0 : ChromeMetrics.trafficLightsWidth)
                .frame(height: ChromeMetrics.headerHeight)
                ContentUnavailableView("No project selected",
                                       systemImage: "folder",
                                       description: Text("Add a project with ⇧⌘N."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
                    .padding(.bottom, 8)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Binding var showSidebar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                ChromeButton(systemImage: "sidebar.left", help: "Hide sidebar (⌃⌘S)") { showSidebar = false }
            }
            .padding(.leading, ChromeMetrics.trafficLightsWidth)
            .padding(.trailing, 8)
            .frame(height: ChromeMetrics.headerHeight)

            HStack {
                Text("Projects")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button { model.addProjectRequested = true } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("Add project (⇧⌘N)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.projects) { project in
                        ProjectRow(project: project, selected: model.selectedProjectId == project.id)
                    }
                }
                .padding(.horizontal, 8)
            }

            if let message = model.hookStatusMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .padding(12)
            }
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let project: Project
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let state = model.sessionStates[project.id] ?? .idle
        HStack(spacing: 10) {
            ProjectAvatar(name: project.name, state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(model.branchLabel(for: project))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 4)
            StatusBadge(state: state)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedProjectId = project.id }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove Project", role: .destructive) {
                Task { await model.removeProject(project.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var rowFill: Color {
        if selected { return theme.elevated }
        return hovering ? theme.hover : .clear
    }
}

/// Letter tile in a color derived from the project name. A ring in the
/// status color shows across the room when Claude needs you or is done.
struct ProjectAvatar: View {
    @Environment(\.theme) private var theme
    let name: String
    let state: SessionState

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(theme.avatarText)
            .frame(width: 30, height: 30)
            .background(theme.avatar(for: name), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if let ring = state.ringColor(theme) {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(ring, lineWidth: 2)
                        .padding(-3)
                }
            }
            .padding(3)
    }
}
