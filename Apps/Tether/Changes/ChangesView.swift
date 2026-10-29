import SwiftUI
import TetherCore
import TetherProtocol

/// Right-hand panel: Changes, Files and Preview behind one tab switcher.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var model = model
        let changeCount = model.selectedWorktreePath.flatMap { model.changes.snapshots[$0]?.files.count } ?? 0
        VStack(spacing: 0) {
            PillPicker(selection: $model.inspectorTab, options: [.changes, .files, .preview]) { tab in
                switch tab {
                case .changes: changeCount > 0 ? "Changes \(changeCount)" : "Changes"
                case .files: "Files"
                case .preview: "Preview"
                }
            }
            .frame(height: ChromeMetrics.headerHeight)
            Group {
                switch model.inspectorTab {
                case .changes: ChangesView()
                case .files: FilesView()
                case .preview: PreviewView()
                }
            }
            .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
            .padding(.bottom, 8)
            .padding(.trailing, 8)
        }
    }
}

struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let path = model.selectedWorktreePath
        let snapshot = path.flatMap { model.changes.snapshots[$0] }
        let error = path.flatMap { model.changes.errors[$0] }
        Group {
            if let snapshot, let path {
                SnapshotView(snapshot: snapshot, path: path)
            } else if let error {
                ContentUnavailableView("Can't read changes", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if path == nil {
                ContentUnavailableView("No project selected", systemImage: "folder")
            } else {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SnapshotView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let snapshot: ChangesSnapshot
    let path: String
    @State private var commitsExpanded = true

    private var summary: String {
        let base = snapshot.baseRef.map { "Against \($0)" } ?? "Uncommitted changes"
        if snapshot.files.isEmpty { return snapshot.commits.isEmpty ? "\(base) · no changes" : base }
        let n = snapshot.files.count
        return "\(base) · \(n) file\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if snapshot.files.isEmpty && snapshot.commits.isEmpty {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                       description: Text(snapshot.baseRef.map { "This branch matches \($0)." }
                                                         ?? "The working tree is clean."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.files) { file in
                            FileRow(file: file, worktreePath: path,
                                    staging: model.changes.staging[path]?[file.path],
                                    selected: model.openDiffTarget?.file.path == file.path
                                    && model.openDiffTarget?.worktreePath == path)
                        }
                        if !snapshot.commits.isEmpty {
                            commits
                        }
                    }
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(snapshot.branchLabel).font(.headline).lineLimit(1)
                if snapshot.ahead > 0 { Text("↑\(snapshot.ahead)").font(.caption).foregroundStyle(.secondary) }
                if snapshot.behind > 0 { Text("↓\(snapshot.behind)").font(.caption).foregroundStyle(theme.claude) }
                Spacer()
                if model.changes.refreshing.contains(path) { ProgressView().controlSize(.mini) }
                Button { model.changes.refresh(path); model.changes.fetchNow(path, force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh and fetch")
            }
            HStack(spacing: 6) {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                stageAllButton
                if !snapshot.files.isEmpty {
                    Text("+\(snapshot.additions)").foregroundStyle(theme.green)
                    Text("−\(snapshot.deletions)").foregroundStyle(theme.red)
                }
            }
            .font(.caption.monospacedDigit())
        }
        .padding(10)
    }

    /// Stage All while anything is unstaged, then Unstage All.
    @ViewBuilder
    private var stageAllButton: some View {
        let states = model.changes.staging[path] ?? [:]
        let stageable = snapshot.files.filter { states[$0.path] != nil }
        if !stageable.isEmpty {
            let allStaged = stageable.allSatisfy { states[$0.path] == .staged }
            Button(allStaged ? "Unstage All" : "Stage All") {
                if allStaged {
                    model.changes.unstage(stageable, in: path)
                } else {
                    model.changes.stage(stageable.filter { states[$0.path] != .staged }, in: path)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(allStaged ? "Take every file out of the index" : "git add every uncommitted file")
        }
    }

    private var commits: some View {
        DisclosureGroup(isExpanded: $commitsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.commits) { commit in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.subject).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(commit.shortHash).font(.caption.monospaced())
                            Text(RelativeTime.string(commit.date))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Commits (\(snapshot.commits.count))").font(.subheadline.weight(.semibold))
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            if let info = model.changes.fetchInfo[path] {
                if let error = info.error {
                    Label("Fetch failed", systemImage: "exclamationmark.triangle")
                        .help(error)
                        .foregroundStyle(theme.claude)
                } else {
                    Text("Fetched \(RelativeTime.string(info.at))")
                }
            } else {
                Text("Not fetched yet")
            }
            Spacer()
            if let error = model.changes.stagingErrors[path] {
                Label("Staging failed", systemImage: "exclamationmark.triangle")
                    .help(error)
                    .foregroundStyle(theme.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let file: ChangedFile
    let worktreePath: String
    /// Nil when there's nothing to stage: the file only differs by commits,
    /// or it's a conflict.
    let staging: StagingState?
    let selected: Bool

    var body: some View {
        Button { model.openDiff(file) } label: {
            HStack(spacing: 8) {
                KindBadge(kind: file.kind)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.fileName).lineLimit(1)
                    if !file.directory.isEmpty {
                        Text(file.directory)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if file.isBinary {
                    Text("binary").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        if let a = file.additions { Text("+\(a)").foregroundStyle(theme.green) }
                        if let d = file.deletions { Text("−\(d)").foregroundStyle(theme.red) }
                    }
                    .font(.caption.monospacedDigit())
                }
                if let staging {
                    StageToggle(state: staging) { toggleStaging() }
                } else if file.hasUncommittedChanges {
                    Circle().fill(theme.claude).frame(width: 6, height: 6).help("Has uncommitted changes")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let staging {
                if staging != .staged {
                    Button("Stage") { model.changes.stage([file], in: worktreePath) }
                }
                if staging != .unstaged {
                    Button("Unstage") { model.changes.unstage([file], in: worktreePath) }
                }
            }
        }
    }

    private func toggleStaging() {
        if staging == .staged {
            model.changes.unstage([file], in: worktreePath)
        } else {
            model.changes.stage([file], in: worktreePath)
        }
    }
}

/// Empty circle: unstaged. Half: partly staged. Check: staged. Click to flip.
private struct StageToggle: View {
    @Environment(\.theme) private var theme
    let state: StagingState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .unstaged ? theme.secondaryText : theme.green)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var symbol: String {
        switch state {
        case .unstaged: "circle"
        case .partlyStaged: "circle.lefthalf.filled"
        case .staged: "checkmark.circle.fill"
        }
    }

    private var help: String {
        switch state {
        case .unstaged: "Not staged. Click to stage."
        case .partlyStaged: "Partly staged. Click to stage the rest."
        case .staged: "Staged. Click to unstage."
        }
    }
}

struct KindBadge: View {
    @Environment(\.theme) private var theme
    let kind: FileChangeKind

    private var color: Color {
        switch kind {
        case .added: theme.green
        case .modified: theme.claude
        case .deleted: theme.red
        case .renamed, .copied: theme.blue
        case .untracked: theme.secondaryText
        case .conflicted: theme.red
        }
    }

    var body: some View {
        Text(kind.letter)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(kind.rawValue)
    }
}

@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func string(_ date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}
