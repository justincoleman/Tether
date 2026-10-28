import GhosttyTerminal
import SwiftUI
import TetherCore
import TetherProtocol

/// Header row (tabs and panel buttons) over a rounded card holding every
/// pane of the selected project. Hidden panes keep their grid and
/// scrollback; only rendering stops.
struct TerminalTabsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let project: Project
    @Binding var showSidebar: Bool

    var body: some View {
        let panes = model.panes(for: project.id)
        let diffOpen = model.openDiffTarget?.projectId == project.id
        let card = RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius)
        VStack(spacing: 0) {
            TabStrip(project: project, panes: panes, showSidebar: $showSidebar)
            ZStack {
                if panes.isEmpty {
                    ContentUnavailableView("No terminals",
                                           systemImage: "terminal",
                                           description: Text("Open a Claude session with the + button."))
                }
                ForEach(panes) { pane in
                    // Hidden while a diff covers the terminal, so keystrokes and
                    // rendering go to the diff instead.
                    let selected = pane.id == model.selectedPaneId && !diffOpen
                    TerminalSurfaceView(context: pane.terminal)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .onChange(of: selected, initial: true) { _, isSelected in
                            pane.setVisible(isSelected)
                            if isSelected { pane.focus() }
                        }
                }
            }
            // The card is the terminal's own background, so this inset reads
            // as padding and the AppKit surface never needs clipping.
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.surface, in: card)
            .overlay {
                if let target = model.openDiffTarget, target.projectId == project.id {
                    DiffViewer(target: target)
                        .clipShape(card)
                }
            }
            .overlay(card.strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5))
            .overlay(alignment: .bottom) {
                // Added after the diff so a permission prompt stays on top of it.
                if let paneId = model.selectedPaneId,
                   let request = model.pendingPermissions.first(where: { $0.paneId == paneId }) {
                    PermissionPromptView(request: request)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.pendingPermissions.map(\.id))
            .padding(.bottom, 8)
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let project: Project
    let panes: [TerminalPane]
    @Binding var showSidebar: Bool

    var body: some View {
        HStack(spacing: 4) {
            if !showSidebar {
                ChromeButton(systemImage: "sidebar.left", help: "Show sidebar (⌃⌘S)") { showSidebar = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(panes) { pane in
                        TabButton(pane: pane, selected: pane.id == model.selectedPaneId) {
                            model.closeDiff()
                            model.selectedPaneId = pane.id
                        } close: {
                            Task { await model.closePane(pane.id) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("New Claude Session") { Task { await model.openClaudePane(project: project) } }
                Button("New Shell") { Task { await model.openShellPane(project: project) } }
                if !model.remoteHosts.isEmpty {
                    Divider()
                    ForEach(model.remoteHosts) { host in
                        Button("ssh \(host.name)") { Task { await model.openSSHPane(project: project, host: host) } }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("New tab")
            ChromeButton(systemImage: "bubble.left.and.text.bubble.right",
                         active: model.showInspector && model.inspectorTab == .chat,
                         help: "Chat (⇧⌘M)") { model.toggleInspector(.chat) }
            ChromeButton(systemImage: "plusminus.circle",
                         active: model.showInspector && model.inspectorTab == .changes,
                         help: "Changes against the base branch (⇧⌘D)") { model.toggleInspector(.changes) }
        }
        .padding(.leading, showSidebar ? 0 : ChromeMetrics.trafficLightsWidth)
        .frame(height: ChromeMetrics.headerHeight)
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let pane: TerminalPane
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isClaude ? theme.claude : theme.secondaryText)
            Text(pane.title)
                .font(.callout.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? theme.text : theme.secondaryText)
                .lineLimit(1)
            StatusBadge(state: state).scaleEffect(0.75)
            if pane.hasExited {
                Text("exited").font(.caption2).foregroundStyle(theme.secondaryText)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .opacity(hovering || selected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? theme.elevated : hovering ? theme.hover : .clear, in: Capsule())
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    private var state: SessionState { model.paneStates[pane.id] ?? .idle }

    private var isClaude: Bool {
        if case .claude = pane.descriptor.kind { return true }
        return false
    }

    private var icon: String {
        switch pane.descriptor.kind {
        case .claude: "sparkles"
        case .shell: "terminal"
        case .ssh: "network"
        }
    }
}
