import AppKit
import SwiftUI
import TetherCore
import TetherProtocol

private struct FilesKey: Hashable {
    var path: String
    var revision: Int
    var reload: Int
}

/// The selected tab's worktree as a tree. Ignored files stay out (see
/// `FileTree`). Clicking a file shows it over the terminal.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var tree: [FileTreeNode] = []
    @State private var loadedPath: String?
    @State private var error: String?
    @State private var query = ""
    /// Open folders, per worktree, so switching tabs keeps each tree's shape.
    @State private var expanded: [String: Set<String>] = [:]
    @State private var reloadCount = 0

    var body: some View {
        let path = model.selectedWorktreePath
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                }
                Button { reloadCount += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            content(path: path)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: path.map { FilesKey(path: $0, revision: model.changes.revisions[$0] ?? 0, reload: reloadCount) }) {
            await load(path)
        }
    }

    @ViewBuilder
    private func content(path: String?) -> some View {
        if path == nil {
            ContentUnavailableView("No project selected", systemImage: "folder")
        } else if let error, tree.isEmpty {
            ContentUnavailableView("Can't list files", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if loadedPath != path {
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        } else if let path {
            let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
            let rows = FileTree.rows(FileTree.filter(tree, query: query),
                                     expanded: expanded[path] ?? [], expandAll: filtering)
            if rows.isEmpty {
                ContentUnavailableView(filtering ? "No matches" : "No files", systemImage: "doc")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            FileTreeRowView(row: row, worktreePath: path,
                                            isExpanded: filtering || expanded[path]?.contains(row.id) == true,
                                            selected: model.openFileTarget?.path == row.id
                                                && model.openFileTarget?.worktreePath == path) {
                                if row.node.isDirectory {
                                    toggle(row.id, in: path)
                                } else {
                                    model.openFile(row.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func toggle(_ folder: String, in path: String) {
        var open = expanded[path] ?? []
        if open.contains(folder) { open.remove(folder) } else { open.insert(folder) }
        expanded[path] = open
    }

    private func load(_ path: String?) async {
        guard let path else { return }
        do {
            let paths = try await FileTree.list(in: path)
            let built = await Task.detached(priority: .userInitiated) { FileTree.build(paths: paths) }.value
            guard !Task.isCancelled else { return }
            tree = built
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            tree = []
            self.error = "\(error)"
        }
        loadedPath = path
    }
}

private struct FileTreeRowView: View {
    @Environment(\.theme) private var theme
    let row: FileTreeRow
    let worktreePath: String
    let isExpanded: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var url: URL { URL(fileURLWithPath: worktreePath).appendingPathComponent(row.id) }

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
        .background(selected ? theme.elevated : hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .contextMenu {
            if !row.node.isDirectory {
                Button("Open") { action() }
            }
            Button("Open with Default App") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Copy Path") { copy(url.path) }
            Button("Copy Relative Path") { copy(row.id) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum FileIcon {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "icns": "photo"
        case "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "c", "h", "m", "mm", "cpp",
             "java", "kt", "html", "css", "scss", "sh", "zsh", "sql", "vue", "svelte": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}
