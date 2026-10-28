import GhosttyTerminal
import SwiftUI
import TetherCore
import TetherProtocol

/// Header row (tabs and panel buttons) over a rounded card holding every
/// pane of the selected project. Hidden panes keep their grid and
/// scrollback; only rendering stops. A split shows two panes at once.
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
            TerminalCard(panes: panes, overlayOpen: overlayOpen, chatShown: chatShown)
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

/// Every pane of the project, stacked, with the selected one (and its split
/// partner) on top. Panes are never re-parented: a split only changes their
/// frames, so libghostty surfaces keep their state.
private struct TerminalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let panes: [TerminalPane]
    let overlayOpen: Bool
    let chatShown: Bool
    /// The divider position while it's being dragged.
    @State private var dragFraction: Double?

    /// Room between the halves; the divider line sits in the middle.
    private static let gap: CGFloat = 9

    var body: some View {
        let selectedId = model.selectedPaneId
        let split = visibleSplit
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            let halves = split.map { Self.halves(in: full, axis: $0.axis, fraction: dragFraction ?? $0.fraction) }
            ZStack(alignment: .topLeading) {
                if panes.isEmpty {
                    ContentUnavailableView("No terminals",
                                           systemImage: "terminal",
                                           description: Text("Open a Claude session with the + button."))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                ForEach(panes) { pane in
                    let rect = frame(of: pane.id, split: split, halves: halves, full: full)
                    // Hidden while a diff or a file covers the card, and while the
                    // chat covers this pane, so keystrokes and rendering go there.
                    let shown = rect != nil && !overlayOpen && !(chatShown && pane.id == selectedId)
                    let focused = shown && pane.id == selectedId
                    let r = rect ?? full
                    TerminalSurfaceView(context: pane.terminal)
                        .frame(width: r.width, height: r.height)
                        .overlay {
                            // First click on the other half focuses it, like Ghostty.
                            if shown && !focused {
                                theme.window.opacity(0.22)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectedPaneId = pane.id }
                            }
                        }
                        .offset(x: r.minX, y: r.minY)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .onChange(of: shown, initial: true) { _, isShown in
                            pane.setVisible(isShown)
                        }
                        .onChange(of: focused, initial: true) { _, isFocused in
                            if isFocused {
                                pane.setVisible(true)
                                pane.focus()
                            }
                        }
                }
                if chatShown, let selectedId {
                    let r = frame(of: selectedId, split: split, halves: halves, full: full) ?? full
                    MirrorView(paneId: selectedId)
                        // Alone, the chat fills the card edge to edge.
                        .padding(.horizontal, split == nil ? -10 : 0)
                        .padding(.vertical, split == nil ? -8 : 0)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                if let split, let halves, !overlayOpen {
                    divider(split: split, rect: halves.divider, size: geo.size)
                }
            }
            .coordinateSpace(.named("terminalCard"))
        }
    }

    /// The selected tab's split, when both of its tabs are in this project.
    private var visibleSplit: PaneSplit? {
        guard let id = model.selectedPaneId, let split = model.split(containing: id),
              let partner = split.partner(of: id) else { return nil }
        return panes.contains { $0.id == partner } ? split : nil
    }

    private func frame(of id: PaneID, split: PaneSplit?,
                       halves: (first: CGRect, second: CGRect, divider: CGRect)?, full: CGRect) -> CGRect? {
        if let split, let halves {
            if id == split.first { return halves.first }
            if id == split.second { return halves.second }
            return nil
        }
        return id == model.selectedPaneId ? full : nil
    }

    static func halves(in full: CGRect, axis: SplitAxis, fraction: Double)
        -> (first: CGRect, second: CGRect, divider: CGRect) {
        switch axis {
        case .horizontal:
            let w = max(full.width - gap, 0)
            let a = (w * fraction).rounded()
            return (CGRect(x: 0, y: 0, width: a, height: full.height),
                    CGRect(x: a + gap, y: 0, width: w - a, height: full.height),
                    CGRect(x: a, y: 0, width: gap, height: full.height))
        case .vertical:
            let h = max(full.height - gap, 0)
            let a = (h * fraction).rounded()
            return (CGRect(x: 0, y: 0, width: full.width, height: a),
                    CGRect(x: 0, y: a + gap, width: full.width, height: h - a),
                    CGRect(x: 0, y: a, width: full.width, height: gap))
        }
    }

    private func divider(split: PaneSplit, rect: CGRect, size: CGSize) -> some View {
        let horizontal = split.axis == .horizontal
        let pane = split.first
        return ZStack {
            Color.clear
            Rectangle()
                .fill(theme.border)
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .pointerStyle(horizontal ? .columnResize : .rowResize)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("terminalCard"))
                .onChanged { value in
                    let total = horizontal ? size.width : size.height
                    guard total > Self.gap else { return }
                    let at = horizontal ? value.location.x : value.location.y
                    dragFraction = PaneSplit.clamp(Double((at - Self.gap / 2) / (total - Self.gap)))
                }
                .onEnded { _ in
                    if let dragFraction { model.setSplitFraction(dragFraction, forPane: pane) }
                    dragFraction = nil
                }
        )
        .onTapGesture(count: 2) { model.setSplitFraction(0.5, forPane: pane) }
        .contextMenu {
            Button(horizontal ? "Stack Vertically" : "Side by Side") {
                Task { await model.toggleSplitAxis(forPane: pane) }
            }
            Button("Even Split") { model.setSplitFraction(0.5, forPane: pane) }
            Divider()
            Button("Unsplit") { Task { await model.unsplit(pane) } }
        }
        .help("Drag to resize. Double-click to even out.")
        .offset(x: rect.minX, y: rect.minY)
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
                    let partner = model.selectedPaneId.flatMap { model.split(containing: $0)?.partner(of: $0) }
                    ForEach(panes) { pane in
                        TabButton(pane: pane, selected: pane.id == model.selectedPaneId,
                                  besideSelected: pane.id == partner) {
                            model.closeOverlays()
                            model.selectedPaneId = pane.id
                        } close: {
                            model.requestClose(pane.id)
                        }
                        // Drag a tab onto another to move it there.
                        .draggable(pane.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first.flatMap(UUID.init(uuidString:)),
                                  dragged != pane.id else { return false }
                            Task { await model.movePane(dragged, onto: pane.id) }
                            return true
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
    /// The other half of the selected tab's split, shown with it.
    let besideSelected: Bool
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
        .background(selected ? theme.elevated : hovering || besideSelected ? theme.hover : .clear, in: Capsule())
        .overlay {
            if besideSelected { Capsule().strokeBorder(theme.border) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .contextMenu {
            if !selected && !besideSelected {
                Button("Show Beside Current Tab") { Task { await model.showBesideSelected(pane.id) } }
            }
            if model.split(containing: pane.id) != nil {
                Button("Unsplit") { Task { await model.unsplit(pane.id) } }
            }
            Divider()
            Button("Close Tab", action: close)
        }
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
