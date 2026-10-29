import SwiftUI
import TetherCore
import TetherProtocol

/// Every Claude tab across projects as a grid of cards, in sidebar and tab
/// order so cards don't jump around while you read them. Clicking a card
/// opens that tab.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Binding var showSidebar: Bool

    var body: some View {
        let entries = self.entries
        VStack(spacing: 0) {
            HStack {
                if !showSidebar {
                    ChromeButton(systemImage: "sidebar.left", help: "Show sidebar (⌃⌘S)") { showSidebar = true }
                }
                Spacer()
            }
            .padding(.leading, showSidebar ? 0 : ChromeMetrics.trafficLightsWidth)
            .frame(height: ChromeMetrics.headerHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Overview")
                            .font(.title.weight(.semibold))
                        ForEach(summary(entries), id: \.label) { item in
                            Text("\(item.count) \(item.label)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(theme.elevated, in: Capsule())
                        }
                    }
                    if model.projects.isEmpty {
                        ContentUnavailableView("No projects",
                                               systemImage: "folder",
                                               description: Text("Add a project with ⇧⌘N."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .tab(let project, let pane, let showTitle):
                                    OverviewCard(project: project, pane: pane, showTitle: showTitle)
                                case .empty(let project):
                                    EmptyProjectCard(project: project)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5))
            .padding(.bottom, 8)
        }
    }

    private enum Entry: Identifiable {
        case tab(Project, TerminalPane, showTitle: Bool)
        /// A project with no Claude tab open.
        case empty(Project)

        var id: String {
            switch self {
            case .tab(_, let pane, _): "pane-\(pane.id)"
            case .empty(let project): "project-\(project.id)"
            }
        }
    }

    private var entries: [Entry] {
        model.projects.flatMap { project -> [Entry] in
            let tabs = model.panes(for: project.id).filter(\.isClaude)
            if tabs.isEmpty { return [.empty(project)] }
            return tabs.map { .tab(project, $0, showTitle: tabs.count > 1) }
        }
    }

    private struct SummaryItem {
        var label: String
        var count: Int
        var color: Color
    }

    /// "1 needs you", "2 working", … for the states that have any tabs.
    private func summary(_ entries: [Entry]) -> [SummaryItem] {
        var counts: [OverviewStatus: Int] = [:]
        for case .tab(_, let pane, _) in entries {
            counts[OverviewStatus(pane: pane, model: model), default: 0] += 1
        }
        return OverviewStatus.allCases.compactMap { status in
            guard let n = counts[status], n > 0 else { return nil }
            return SummaryItem(label: status.summaryLabel, count: n, color: status.color(theme))
        }
    }
}

/// What a card says about its tab, most urgent first.
private enum OverviewStatus: CaseIterable {
    case needsYou, working, error, done, idle, exited

    @MainActor
    init(pane: TerminalPane, model: AppModel) {
        if pane.hasExited { self = .exited; return }
        switch model.paneStates[pane.id] ?? .idle {
        case .needsInput: self = .needsYou
        case .working: self = .working
        case .error: self = .error
        case .done: self = .done
        case .idle, .detached: self = .idle
        }
    }

    var label: String {
        switch self {
        case .needsYou: "NEEDS YOU"
        case .working: "WORKING"
        case .error: "ERROR"
        case .done: "DONE"
        case .idle: "IDLE"
        case .exited: "EXITED"
        }
    }

    var summaryLabel: String {
        switch self {
        case .needsYou: "need you"
        case .working: "working"
        case .error: "errored"
        case .done: "done"
        case .idle: "idle"
        case .exited: "exited"
        }
    }

    func color(_ theme: Theme) -> Color {
        switch self {
        case .needsYou: theme.blue
        case .working: theme.claude
        case .error: theme.red
        case .done: theme.green
        case .idle, .exited: theme.secondaryText
        }
    }
}

private struct OverviewCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("useProjectIcons") private var useProjectIcons = true
    let project: Project
    let pane: TerminalPane
    /// The tab's title, when the project has more than one Claude tab.
    let showTitle: Bool
    @State private var hovering = false

    var body: some View {
        let status = OverviewStatus(pane: pane, model: model)
        let path = model.worktreePath(forPane: pane.id) ?? project.path
        let snapshot = model.changes.snapshots[path]
        let text = headline(status)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MiniAvatar(name: project.name, icon: useProjectIcons ? model.projectIcons[project.id] : nil)
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle(branch: snapshot?.branchLabel ?? project.baseBranch))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if status == .working || status == .needsYou {
                    StatusBadge(state: model.paneStates[pane.id] ?? .idle).scaleEffect(0.8)
                }
                Text(status.label)
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(status.color(theme))
            }
            Text(text.title)
                .font(.title3.weight(.medium))
                .foregroundStyle(status == .idle || status == .exited ? theme.secondaryText : theme.text)
                .lineLimit(1)
            if let detail = text.detail, !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer(snapshot: snapshot)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? theme.hover : theme.window, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(status == .needsYou ? theme.blue : theme.border.opacity(0.6),
                              lineWidth: status == .needsYou ? 1.5 : 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { model.select(pane: pane) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open Tab") { model.select(pane: pane) }
            Divider()
            Button("Close Tab", role: .destructive) { model.requestClose(pane.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func subtitle(branch: String) -> String {
        showTitle ? "\(pane.title) · \(branch)" : branch
    }

    private func headline(_ status: OverviewStatus) -> (title: String, detail: String?) {
        let preview = model.mirror.model(for: model.sessionId(forPane: pane.id))?.preview()
        switch status {
        case .exited:
            return ("Not running", "Claude quit in this tab. The conversation is in History.")
        case .needsYou:
            if let request = model.pendingPermissions.first(where: { $0.paneId == pane.id }) {
                let summary = PermissionSummary.describe(toolName: request.toolName, input: request.toolInput)
                return ("Wants to \(summary.title.prefix(1).lowercased() + summary.title.dropFirst())",
                        summary.detail)
            }
            switch model.paneAttention[pane.id] {
            case .question: return ("Asked you a question", preview)
            case .dialog: return ("Waiting on a dialog", "Answer it in the terminal.")
            case .permission: return ("Waiting for permission", preview)
            case nil: return ("Needs you", preview)
            }
        case .working: return ("Working", preview)
        case .error: return ("Stopped with an error", preview)
        case .done: return ("Finished", preview)
        case .idle: return ("Waiting for a prompt", preview)
        }
    }

    @ViewBuilder
    private func footer(snapshot: ChangesSnapshot?) -> some View {
        let additions = snapshot?.additions ?? 0
        let deletions = snapshot?.deletions ?? 0
        let started = model.turnStartedAt[pane.id]
        let queued = model.queuedCounts[pane.id] ?? 0
        let pr = model.pullRequest(forPath: model.worktreePath(forPane: pane.id) ?? project.path)
        if additions > 0 || deletions > 0 || started != nil || queued > 0 || pr != nil {
            HStack(spacing: 10) {
                if let pr {
                    PullRequestBadge(status: pr)
                }
                if additions > 0 {
                    Text("+\(additions.formatted())").foregroundStyle(theme.green)
                }
                if deletions > 0 {
                    Text("−\(deletions.formatted())").foregroundStyle(theme.red)
                }
                Spacer(minLength: 0)
                if queued > 0 {
                    Label("\(queued) queued", systemImage: "tray.full")
                        .foregroundStyle(theme.secondaryText)
                }
                if let started {
                    Label {
                        Text(started, style: .timer)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .foregroundStyle(theme.secondaryText)
                    .help("Time since this turn started")
                }
            }
            .font(.callout.monospacedDigit())
            .padding(.top, 4)
        }
    }
}

/// A project with no Claude tab: clicking starts one.
private struct EmptyProjectCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("useProjectIcons") private var useProjectIcons = true
    let project: Project
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MiniAvatar(name: project.name, icon: useProjectIcons ? model.projectIcons[project.id] : nil)
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.branchLabel(for: project))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            Text("No Claude tab")
                .font(.title3.weight(.medium))
                .foregroundStyle(theme.secondaryText)
            Text("Click to start one.")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? theme.hover : theme.window, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { Task { await model.openClaudePane(project: project) } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The project's icon or letter tile, sized for a card header.
private struct MiniAvatar: View {
    @Environment(\.theme) private var theme
    let name: String
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.avatarText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.avatar(for: name))
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
