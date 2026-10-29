import AppKit
import SwiftUI
import TetherCore
import TetherProtocol
import WebKit

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

/// The right-hand panel while a paired Mac's tab is open: Changes, Files and
/// Preview for that tab's folder on the other Mac. Read-only.
struct RemoteInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PillPicker(selection: $model.inspectorTab, options: [.changes, .files, .preview]) { tab in
                switch tab {
                case .changes: "Changes"
                case .files: "Files"
                case .preview: "Preview"
                }
            }
            .frame(height: ChromeMetrics.headerHeight)
            Group {
                switch model.inspectorTab {
                case .changes: RemoteChangesTab(connection: connection, paneId: paneId)
                case .files: RemoteFilesTab(connection: connection, paneId: paneId)
                case .preview: RemotePreviewTab(connection: connection, paneId: paneId)
                }
            }
            .id(paneId)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: ChromeMetrics.cardRadius))
            .padding(.bottom, 8)
            .padding(.trailing, 8)
        }
    }
}

/// The tab's changed files against its base branch, and each file's diff.
private struct RemoteChangesTab: View {
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
                if openFile != nil {
                    Button { openFile = nil } label: { Label("Changes", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent)
                    Text(openFile?.fileName ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                } else {
                    Text("Against the base branch").font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if openFile == nil {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .help("Refresh")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            if let openFile {
                RemoteDiffView(connection: connection, paneId: paneId, file: openFile)
                    .id(openFile)
            } else {
                changes
            }
        }
        // Reload when Claude finishes a turn.
        .task(id: String(describing: state)) { await load() }
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

/// The tab's folder on the other Mac as a tree; a file opens in the panel.
private struct RemoteFilesTab: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    @State private var result: Result<[String], MacConnection.ReplyError>?
    @State private var tree: [FileTreeNode] = []
    @State private var expanded: Set<String> = []
    @State private var query = ""
    @State private var openPath: String?

    var body: some View {
        VStack(spacing: 0) {
            if let openPath {
                HStack {
                    Button { self.openPath = nil } label: { Label("Files", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent)
                    Text((openPath as NSString).lastPathComponent)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider()
                RemoteFileView(connection: connection, paneId: paneId, path: openPath)
                    .id(openPath)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    TextField("Filter", text: $query).textFieldStyle(.plain)
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Reload")
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                Divider()
                content
            }
        }
        .task { await load() }
    }

    private func load() async {
        let loaded = await connection.fileList(for: paneId)
        if case .success(let paths) = loaded {
            tree = await Task.detached(priority: .userInitiated) { FileTree.build(paths: paths) }.value
        }
        result = loaded
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case nil:
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        case .failure(let failure)?:
            ContentUnavailableView("Can't list files", systemImage: "exclamationmark.triangle",
                                   description: Text(failure.message))
        case .success?:
            let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
            let rows = FileTree.rows(FileTree.filter(tree, query: query), expanded: expanded, expandAll: filtering)
            if rows.isEmpty {
                ContentUnavailableView(filtering ? "No matches" : "No files", systemImage: "doc")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            RemoteTreeRow(row: row, isExpanded: filtering || expanded.contains(row.id)) {
                                if row.node.isDirectory {
                                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                                } else {
                                    openPath = row.id
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct RemoteTreeRow: View {
    @Environment(\.theme) private var theme
    let row: FileTreeRow
    let isExpanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(row.node.isDirectory ? 1 : 0)
                .frame(width: 10)
            Image(systemName: row.node.isDirectory ? "folder.fill" : FileIcon.symbol(for: row.node.name))
                .font(.system(size: 12))
                .foregroundStyle(row.node.isDirectory ? theme.green : theme.secondaryText)
                .frame(width: 16)
            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

/// One file from the other Mac: text with line numbers, or an image.
private struct RemoteFileView: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    let path: String
    @State private var result: Result<RemoteFile, MacConnection.ReplyError>?

    var body: some View {
        Group {
            switch result {
            case nil:
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            case .failure(let failure)?:
                ContentUnavailableView("Can't open this file", systemImage: "exclamationmark.triangle",
                                       description: Text(failure.message))
            case .success(let file)?:
                switch file.kind {
                case .text: lines(file)
                case .image:
                    if let data = file.image, let image = NSImage(data: data) {
                        ScrollView([.horizontal, .vertical]) { Image(nsImage: image).padding(16) }
                    } else {
                        ContentUnavailableView("Can't show this image", systemImage: "photo")
                    }
                case .binary:
                    ContentUnavailableView("Binary file", systemImage: "doc",
                                           description: Text("Open it on \(connection.mac.name) to see it."))
                case .unreadable:
                    ContentUnavailableView("Can't open this file", systemImage: "exclamationmark.triangle",
                                           description: Text(file.note ?? "It couldn't be read."))
                }
            }
        }
        .task { result = await connection.file(path, in: paneId) }
    }

    private func lines(_ file: RemoteFile) -> some View {
        let all = (file.text ?? "").components(separatedBy: "\n")
        let digits = max(3, String(all.count).count)
        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(index + 1))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: CGFloat(digits) * 8, alignment: .trailing)
                        Text(line.replacingOccurrences(of: "\t", with: "    "))
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 18, alignment: .leading)
                }
                if file.truncated {
                    Text("Only the start of this file is shown.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 8)
                }
            }
            .padding(12)
        }
    }
}

/// A dev server running in the tab's folder on the other Mac, loaded over
/// the network. It only loads when the server listens beyond localhost.
private struct RemotePreviewTab: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    @State private var browser = PreviewBrowser()
    @State private var servers: [DevServerInfo]?
    @State private var failure: String?
    @State private var chosenPort: Int?

    private var port: Int? {
        if let chosenPort, servers?.contains(where: { $0.port == chosenPort }) == true { return chosenPort }
        return servers?.first?.port
    }

    private var target: URL? {
        port.flatMap { URL(string: "http://\(connection.mac.host):\($0)/") }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                RemoteWebView(webView: browser.webView)
                    .opacity(target == nil || browser.failure != nil ? 0 : 1)
                if let failure {
                    ContentUnavailableView("Can't ask \(connection.mac.name)", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else if servers == nil {
                    ProgressView().controlSize(.small)
                } else if target == nil {
                    ContentUnavailableView("No dev server running", systemImage: "globe",
                                           description: Text("Start one in this folder on \(connection.mac.name) and press reload."))
                } else if let problem = browser.failure {
                    ContentUnavailableView {
                        Label("Can't load \(connection.mac.host):\(port ?? 0)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(problem)\nMost dev servers only listen on localhost. Start it listening on the network, for example with --host, so this Mac can reach it.")
                    } actions: {
                        Button("Try Again") { browser.reload() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await scan() }
        .onAppear { browser.show(target) }
        .onChange(of: target) { browser.show(target) }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ChromeButton(systemImage: "arrow.clockwise", help: "Look for servers again and reload") {
                Task { await scan() }
                browser.reload()
            }
            Text(target?.absoluteString ?? "No server")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let servers, servers.count > 1 {
                Menu {
                    ForEach(servers) { server in
                        Button("\(connection.mac.host):\(server.port) · \(server.command)") { chosenPort = server.port }
                    }
                } label: {
                    Image(systemName: "network").foregroundStyle(theme.green)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 6)
            }
            ChromeButton(systemImage: "safari", help: "Open in Browser") {
                if let target { NSWorkspace.shared.open(target) }
            }
            .disabled(target == nil)
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
    }

    private func scan() async {
        switch await connection.devServers(for: paneId) {
        case .success(let found):
            servers = found
            failure = nil
        case .failure(let error):
            failure = error.message
            servers = servers ?? []
        }
    }
}

private struct RemoteWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
