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
    @AppStorage("showChat") private var showChat = false

    var body: some View {
        let panes = model.panes(for: project.id)
        let overlayOpen = model.openDiffTarget?.projectId == project.id
            || model.openFileTarget?.projectId == project.id
        let selectedPane = panes.first { $0.id == model.selectedPaneId }
        // Chat replaces the terminal only for Claude tabs; shells have no conversation.
        let chatShown = showChat && selectedPane?.isClaude == true
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
                    // Hidden while a diff, a file or the chat covers the terminal,
                    // so keystrokes and rendering go there instead.
                    let selected = pane.id == model.selectedPaneId && !overlayOpen && !chatShown
                    TerminalSurfaceView(context: pane.terminal)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .onChange(of: selected, initial: true) { _, isSelected in
                            pane.setVisible(isSelected)
                            if isSelected { pane.focus() }
                        }
                }
                if chatShown, let selectedPane {
                    MirrorView(paneId: selectedPane.id)
                        .padding(.horizontal, -10)
                        .padding(.vertical, -8)
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
                } else if let target = model.openFileTarget, target.projectId == project.id {
                    FileViewer(target: target)
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
    @AppStorage("showChat") private var showChat = false
    @State private var showNewAgent = false
    @State private var showHistory = false
    @State private var editingShortcuts = false

    /// Shortcuts with their own button; the rest are in the + menu.
    private static let barShortcutLimit = 3

    var body: some View {
        let shortcuts = model.quickActions(for: project.id)
        let selectedIsClaude = panes.first { $0.id == model.selectedPaneId }?.isClaude == true
        HStack(spacing: 4) {
            if !showSidebar {
                ChromeButton(systemImage: "sidebar.left", help: "Show sidebar (⌃⌘S)") { showSidebar = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(panes) { pane in
                        TabButton(pane: pane, selected: pane.id == model.selectedPaneId) {
                            model.closeOverlays()
                            model.selectedPaneId = pane.id
                        } close: {
                            model.requestClose(pane.id)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            ViewModeToggle(showChat: $showChat, chatAvailable: selectedIsClaude)
                .padding(.trailing, 4)
            ToolbarPill(title: "Claude", systemImage: "sparkles", iconColor: theme.claude,
                        help: "New Claude tab (⌘T)") {
                Task { await model.openClaudePane(project: project) }
            }
            ToolbarPill(title: "History", systemImage: "clock.arrow.circlepath", help: "Past sessions") {
                showHistory.toggle()
            }
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                HistoryPopover(project: project) { showHistory = false }
                    .environment(model)
                    .environment(\.theme, theme)
            }
            ForEach(shortcuts.prefix(Self.barShortcutLimit)) { action in
                ToolbarPill(title: action.label, systemImage: "play.fill", iconColor: theme.green,
                            monospaced: true, help: action.command) {
                    Task { await model.runQuickAction(action) }
                }
            }
            Menu {
                Button("Claude") { Task { await model.openClaudePane(project: project) } }
                Button("Shell") { Task { await model.openShellPane(project: project) } }
                Button("Agent on a Branch…") { showNewAgent = true }
                if !model.remoteHosts.isEmpty {
                    Divider()
                    ForEach(model.remoteHosts) { host in
                        Button("ssh \(host.name)") { Task { await model.openSSHPane(project: project, host: host) } }
                    }
                }
                if !shortcuts.isEmpty {
                    Divider()
                    ForEach(shortcuts) { action in
                        Button(action.label) { Task { await model.runQuickAction(action) } }
                    }
                }
                Divider()
                Button("Edit Shortcuts…") { editingShortcuts = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("New tab or shortcut")
            ChromeButton(systemImage: "sidebar.right", active: model.showInspector,
                         help: "Changes and files (⇧⌘D, ⇧⌘E)") { model.toggleInspector() }
        }
        .padding(.leading, showSidebar ? 0 : ChromeMetrics.trafficLightsWidth)
        .frame(height: ChromeMetrics.headerHeight)
        .sheet(isPresented: $showNewAgent) {
            NewAgentSheet(project: project)
        }
        .sheet(isPresented: $editingShortcuts) {
            ShortcutsEditor(project: project)
        }
    }
}

/// Terminal or chat for the selected Claude tab, as two icon segments.
private struct ViewModeToggle: View {
    @Environment(\.theme) private var theme
    @Binding var showChat: Bool
    let chatAvailable: Bool

    var body: some View {
        HStack(spacing: 2) {
            segment(chat: false, systemImage: "apple.terminal", help: "Terminal (⇧⌘M)")
            segment(chat: true, systemImage: "bubble.left.and.text.bubble.right",
                    help: chatAvailable ? "Chat (⇧⌘M)" : "Chat is for Claude tabs")
                .disabled(!chatAvailable)
        }
        .padding(2)
        .background(theme.hover, in: RoundedRectangle(cornerRadius: 8))
    }

    private func segment(chat: Bool, systemImage: String, help: String) -> some View {
        // A shell tab always shows its terminal, whatever the setting.
        let selected = chat == (showChat && chatAvailable)
        return Button { showChat = chat } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? theme.text : theme.secondaryText)
                .frame(width: 30, height: 22)
                .background(selected ? theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// An icon-and-label button in the top bar.
struct ToolbarPill: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    var iconColor: Color?
    var monospaced = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor ?? theme.secondaryText)
                Text(title)
                    .font(monospaced ? .callout.monospaced().weight(.medium) : .callout.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(hovering ? theme.text : theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(hovering ? theme.elevated : theme.hover, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "New Agent on a Branch": a worktree on a new branch with its own Claude tab.
struct NewAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var branch = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent on a Branch").font(.headline)
            Text("Creates a worktree of \(project.name) on a new branch from \(project.baseBranch), with its own Claude tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Branch, e.g. fix-login", text: $branch)
            TextField("Task for Claude (optional)", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(branch.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 440)
    }

    private func create() {
        working = true
        error = nil
        Task {
            do {
                try await model.startSession(projectId: project.id, branch: branch, prompt: prompt, select: true)
                dismiss()
            } catch {
                self.error = "\(error)"
            }
            working = false
        }
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

    private var isClaude: Bool { pane.isClaude }

    private var icon: String {
        switch pane.descriptor.kind {
        case .claude: "sparkles"
        case .shell: "terminal"
        case .ssh: "network"
        case .command: "play"
        }
    }
}
