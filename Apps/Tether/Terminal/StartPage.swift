import SwiftUI
import TetherCore
import TetherProtocol

/// What a project shows with no tabs open, and what + shows in place of the
/// current tab: start Claude or Codex, the other kinds of tab, the dev server,
/// shortcuts, and the last few conversations to pick back up.
struct StartPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("useProjectIcons") private var useProjectIcons = true
    let project: Project
    @State private var recent: [PastSession]?
    @State private var showNewAgent = false
    @State private var editingShortcuts = false

    private static let recentLimit = 5

    var body: some View {
        let shortcuts = model.quickActions(for: project.id)
        let servers = model.preview.servers(in: project.path)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(spacing: 10) {
                    StartButton(title: "Start Claude", systemImage: "sparkles", shortcut: "⌘T", tint: theme.claude) {
                        go { await model.openClaudePane(project: project) }
                    }
                    StartButton(title: "Start Codex Chat", systemImage: "chevron.left.forwardslash.chevron.right",
                                shortcut: "", tint: theme.codex) {
                        go { await model.openCodexChatPane(project: project) }
                    }
                }
                section("More") {
                    FlowRow {
                        StartPill(title: "Codex Terminal", systemImage: "chevron.left.forwardslash.chevron.right", help: "New Codex terminal (⌥⌘T)") {
                            go { await model.openCodexPane(project: project) }
                        }
                        StartPill(title: "Shell", systemImage: "terminal", help: "New shell tab (⇧⌘T)") {
                            go { await model.openShellPane(project: project) }
                        }
                        StartPill(title: "Agent on a Branch…", systemImage: "arrow.triangle.branch",
                                  help: "A new branch in its own worktree, with its own agent tab") {
                            showNewAgent = true
                        }
                        StartPill(title: servers.first.map { "Preview localhost:\($0.port)" } ?? "Preview",
                                  systemImage: "globe",
                                  help: servers.isEmpty ? "Open the Preview panel" : "Show the dev server in the Preview panel") {
                            model.newTabPage = nil
                            model.toggleInspector(.preview)
                        }
                        ForEach(model.remoteHosts) { host in
                            StartPill(title: "ssh \(host.name)", systemImage: "network", help: "New ssh tab") {
                                go { await model.openSSHPane(project: project, host: host) }
                            }
                        }
                    }
                }
                section("Shortcuts") {
                    FlowRow {
                        ForEach(shortcuts) { action in
                            StartPill(title: action.label, systemImage: "play.fill", iconColor: theme.green,
                                      monospaced: true, help: action.command) {
                                go { await model.runQuickAction(action) }
                            }
                        }
                        StartPill(title: shortcuts.isEmpty ? "Add a Shortcut…" : "Edit…", systemImage: "pencil",
                                  help: "Commands you run often, one click each") {
                            editingShortcuts = true
                        }
                    }
                }
                section("Pick up where you left off") { recentList }
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.surface)
        .task(id: project.id) {
            recent = Array(await model.pastSessions(for: project.id).prefix(Self.recentLimit))
        }
        .sheet(isPresented: $showNewAgent) {
            NewAgentSheet(project: project)
        }
        .sheet(isPresented: $editingShortcuts) {
            ShortcutsEditor(project: project)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if useProjectIcons, let icon = model.projectIcons[project.id] {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Text(project.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.avatarText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.avatar(for: project.name))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                Label(model.branchLabel(for: project), systemImage: "arrow.triangle.branch")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if !model.panes(for: project.id).isEmpty {
                Button("Back to Tabs") { model.newTabPage = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close this page (Esc)")
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if let recent {
            if recent.isEmpty {
                Text("No conversations in \(project.name) yet.")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent) { session in
                        HistoryRow(title: session.title, firstPrompt: session.firstPrompt,
                                   displayTitle: session.displayTitle, branch: session.branch,
                                   lastActivity: session.lastActivity,
                                   isOpen: model.pane(forSession: session.id) != nil) {
                            go { await model.openPastSession(session, projectId: project.id) }
                        }
                    }
                }
                .padding(.horizontal, -10)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            content()
        }
    }

    /// Closes the page and does the thing.
    private func go(_ action: @escaping @MainActor () async -> Void) {
        model.newTabPage = nil
        Task { await action() }
    }
}

/// One of the two big buttons.
struct StartButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let shortcut: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 8)
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(hovering ? theme.hover : theme.elevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(hovering ? 0.9 : 0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A smaller button, like the top bar's pills but a little larger.
struct StartPill: View {
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
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor ?? theme.secondaryText)
                Text(title)
                    .font(monospaced ? .body.monospaced() : .body)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(hovering ? theme.hover : theme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Lays its children out left to right, wrapping to a new line when full.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
