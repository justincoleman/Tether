import SwiftUI
import TetherProtocol

/// Past Claude sessions in a project on a paired Mac. Picking one opens it in
/// a tab there, or shows the tab already running it.
struct RemoteHistoryPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let projectId: ProjectID
    let dismiss: () -> Void
    @State private var result: Result<[PastSessionInfo], MacConnection.ReplyError>?
    @State private var query = ""
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Past Sessions on \(connection.mac.name)")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            TextField("Search titles and prompts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            switch result {
            case nil:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .failure(let failure)?:
                message(failure.message)
            case .success(let sessions)?:
                let shown = sessions.filter { $0.matches(query) }
                if shown.isEmpty {
                    message(query.isEmpty ? "No sessions in this project yet." : "No sessions match.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(shown) { session in
                                HistoryRow(title: session.title, firstPrompt: session.firstPrompt,
                                           displayTitle: session.displayTitle, branch: session.branch,
                                           lastActivity: session.lastActivity,
                                           isOpen: openSessionIds.contains(session.id)) {
                                    resume(session)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(theme.red).padding(12)
            }
        }
        .frame(width: 440)
        .task {
            searchFocused = true
            result = await connection.history(for: projectId)
        }
    }

    private var openSessionIds: Set<SessionID> {
        Set((connection.snapshot?.sessions ?? []).compactMap(\.sessionId))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func resume(_ session: PastSessionInfo) {
        error = nil
        Task {
            switch await connection.resumeSession(session.id, projectId: projectId) {
            case .started(let paneId):
                model.remote.selectedProjectId = projectId
                model.remote.selectedPaneId = paneId
                dismiss()
            case .failed(let message):
                error = message
            }
        }
    }
}

/// The right-hand panel while a paired Mac's tab is open: that tab's changes
/// against its base branch, and each file's diff. Read-only.
struct RemoteInspectorView: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    @State private var result: Result<ChangesSnapshot, MacConnection.ReplyError>?
    @State private var openFile: ChangedFile?

    private var state: SessionState? {
        connection.snapshot?.sessions.first { $0.id == paneId }?.state
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(openFile?.fileName ?? "Changes")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if openFile != nil {
                    Button("Back") { openFile = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent)
                } else {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .help("Refresh")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: ChromeMetrics.headerHeight)
            Group {
                if let openFile {
                    RemoteDiffView(connection: connection, paneId: paneId, file: openFile)
                        .id(openFile)
                } else {
                    changes
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
            .padding(.bottom, 8)
            .padding(.trailing, 8)
        }
        // Reload when the tab changes or Claude finishes a turn.
        .task(id: "\(paneId)-\(String(describing: state))") { await load() }
        .onChange(of: paneId) { openFile = nil }
    }

    private func load() async {
        result = await connection.changes(for: paneId)
    }

    @ViewBuilder
    private var changes: some View {
        switch result {
        case nil:
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        case .failure(let failure)?:
            ContentUnavailableView("Can't load changes", systemImage: "exclamationmark.triangle",
                                   description: Text(failure.message))
        case .success(let snapshot)?:
            if snapshot.isClean {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                       description: Text(snapshot.baseRef.map { "\(snapshot.branchLabel) matches \($0)." }
                                                         ?? "The working tree is clean."))
            } else {
                List {
                    Section {
                        ForEach(snapshot.files) { file in
                            RemoteFileRow(file: file)
                                .contentShape(Rectangle())
                                .onTapGesture { openFile = file }
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack {
                            Label(snapshot.branchLabel, systemImage: "arrow.triangle.branch")
                            Spacer()
                            Text("+\(snapshot.additions)").foregroundStyle(theme.green)
                            Text("−\(snapshot.deletions)").foregroundStyle(theme.red)
                        }
                        .font(.caption.monospacedDigit())
                    } footer: {
                        if let base = snapshot.baseRef { Text("Against \(base)").font(.caption) }
                    }
                    if !snapshot.commits.isEmpty {
                        Section("Commits (\(snapshot.commits.count))") {
                            ForEach(snapshot.commits) { commit in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(commit.subject).lineLimit(2)
                                    Text(commit.shortHash)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct RemoteFileRow: View {
    @Environment(\.theme) private var theme
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.kind.letter)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 0) {
                Text(file.fileName).lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.isBinary {
                Text("binary").font(.caption).foregroundStyle(theme.secondaryText)
            } else {
                HStack(spacing: 4) {
                    if let a = file.additions { Text("+\(a)").foregroundStyle(theme.green) }
                    if let d = file.deletions { Text("−\(d)").foregroundStyle(theme.red) }
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch file.kind {
        case .added: theme.green
        case .modified: theme.claude
        case .deleted, .conflicted: theme.red
        case .renamed, .copied: theme.blue
        case .untracked: theme.secondaryText
        }
    }
}

/// One file's unified diff from the other Mac. Scrolls sideways so code
/// keeps its shape.
private struct RemoteDiffView: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    let file: ChangedFile
    @State private var result: Result<FileDiff, MacConnection.ReplyError>?

    var body: some View {
        Group {
            switch result {
            case nil:
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            case .failure(let failure)?:
                ContentUnavailableView("Can't load the diff", systemImage: "exclamationmark.triangle",
                                       description: Text(failure.message))
            case .success(let diff)?:
                if diff.isBinary {
                    ContentUnavailableView("Binary file", systemImage: "doc")
                } else if diff.isEmpty {
                    ContentUnavailableView("No changes in this file", systemImage: "doc")
                } else {
                    lines(diff)
                }
            }
        }
        .task { result = await connection.diff(of: file, in: paneId) }
    }

    private func lines(_ diff: FileDiff) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(hunk.header)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.hover)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                if diff.truncated {
                    Text("Diff too long; the rest is on \(connection.mac.name).")
                        .foregroundStyle(theme.secondaryText)
                        .padding(8)
                }
            }
            .font(.caption.monospaced())
        }
    }

    private func row(_ line: DiffLine) -> some View {
        let marker: String
        let fill: Color
        switch line.kind {
        case .add: (marker, fill) = ("+ ", theme.green.opacity(0.15))
        case .delete: (marker, fill) = ("− ", theme.red.opacity(0.15))
        case .context: (marker, fill) = ("  ", .clear)
        }
        return HStack(alignment: .top, spacing: 6) {
            Text(line.newNumber.map(String.init) ?? line.oldNumber.map(String.init) ?? "")
                .foregroundStyle(theme.secondaryText)
                .frame(width: 36, alignment: .trailing)
            Text(marker + line.text)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
    }
}
