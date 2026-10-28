import GhosttyTerminal
import SwiftUI
import TetherCore
import TetherProtocol

/// Tab strip plus every pane of the selected project mounted at once. Hidden
/// panes keep their grid and scrollback; only rendering stops.
struct TerminalTabsView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let panes = model.panes(for: project.id)
        let diffOpen = model.openDiffTarget?.projectId == project.id
        VStack(spacing: 0) {
            TabStrip(project: project, panes: panes)
            Divider()
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
            .overlay {
                if let target = model.openDiffTarget, target.projectId == project.id {
                    DiffViewer(target: target)
                }
            }
            .overlay(alignment: .bottom) {
                // Added after the diff so a permission prompt stays on top of it.
                if let paneId = model.selectedPaneId,
                   let request = model.pendingPermissions.first(where: { $0.paneId == paneId }) {
                    PermissionPromptView(request: request)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.pendingPermissions.map(\.id))
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let panes: [TerminalPane]

    var body: some View {
        HStack(spacing: 4) {
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
                .padding(.horizontal, 6)
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
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 8)
        }
        .frame(height: 30)
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var model
    let pane: TerminalPane
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(pane.title).lineLimit(1)
            StatusBadge(state: state).scaleEffect(0.75)
            if pane.hasExited {
                Text("exited").font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .opacity(hovering || selected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    private var state: SessionState { model.paneStates[pane.id] ?? .idle }

    private var icon: String {
        switch pane.descriptor.kind {
        case .claude: "sparkles"
        case .shell: "terminal"
        case .ssh: "network"
        }
    }
}
