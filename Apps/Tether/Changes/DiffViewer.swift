import AppKit
import SwiftUI
import TetherCore
import TetherProtocol

private enum DiffMetrics {
    /// Rows are a fixed height with no wrapping, so a pointer position maps
    /// to a row by division. That is what makes drag-to-select exact.
    static let rowHeight: CGFloat = 18
    static let numberWidth: CGFloat = 44
    static let markerWidth: CGFloat = 16
    static let fontSize: CGFloat = 12
    static let charWidth: CGFloat = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).maximumAdvancement.width
    static let maxDisplayChars = 2000
}

private struct DiffRow: Identifiable {
    enum Content {
        case hunk(String)
        case line(DiffLine)
    }

    let id: Int
    let content: Content

    var line: DiffLine? {
        if case .line(let l) = content { return l }
        return nil
    }
}

private func makeRows(_ diff: FileDiff) -> [DiffRow] {
    var rows: [DiffRow] = []
    for hunk in diff.hunks {
        rows.append(DiffRow(id: rows.count, content: .hunk(hunk.header)))
        for line in hunk.lines {
            rows.append(DiffRow(id: rows.count, content: .line(line)))
        }
    }
    return rows
}

private func displayText(_ text: String) -> String {
    String(text.replacingOccurrences(of: "\t", with: "    ").prefix(DiffMetrics.maxDisplayChars))
}

/// Characters a line takes on screen: tabs show as four spaces, and very long
/// lines are cut.
private func visualLength(_ text: String) -> Int {
    let tabs = text.reduce(0) { $1 == "\t" ? $0 + 1 : $0 }
    return min(DiffMetrics.maxDisplayChars, text.count + 3 * tabs)
}

private struct LoadKey: Hashable {
    var revision: Int
    var path: String
}

/// A file's diff, with line selection and review comments for Claude. It
/// covers the terminal area while open.
struct DiffViewer: View {
    @Environment(AppModel.self) private var model
    let target: OpenDiff

    @State private var diff: FileDiff?
    @State private var rows: [DiffRow] = []
    @State private var maxChars = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selection: ClosedRange<Int>?
    @State private var anchorRow: Int?
    @State private var dragging = false
    @State private var instruction = ""
    @State private var sendError: String?
    @FocusState private var instructionFocused: Bool

    private var file: ChangedFile {
        model.changes.snapshots[target.worktreePath]?.files.first { $0.path == target.file.path } ?? target.file
    }

    private var pending: [ReviewComment] { model.reviewComments[target.projectId] ?? [] }

    private var trimmedInstruction: String {
        instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var contentWidth: CGFloat {
        DiffMetrics.numberWidth * 2 + DiffMetrics.markerWidth
            + CGFloat(maxChars) * DiffMetrics.charWidth + 32
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if selection != nil || !pending.isEmpty {
                Divider()
                composer
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: LoadKey(revision: model.changes.revisions[target.worktreePath] ?? 0,
                          path: target.file.path)) {
            await load()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            KindBadge(kind: file.kind)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.fileName).font(.headline)
                Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if let diff, !diff.isBinary, !diff.hunks.isEmpty {
                HStack(spacing: 6) {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.callout.monospacedDigit())
            }
            Button(action: escape) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    /// Esc clears a selection first, then closes the diff.
    private func escape() {
        if selection != nil {
            selection = nil
            anchorRow = nil
        } else {
            model.closeDiff()
        }
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if isLoading && diff == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView("Couldn't load the diff", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
        } else if let diff {
            if diff.kind == .conflicted {
                notice("Merge conflict", "Resolve it in the terminal, then reopen this file.")
            } else if diff.isBinary {
                notice("Binary file", "There is no text to show or comment on.")
            } else if diff.hunks.isEmpty {
                notice(diff.truncated ? "File too large to preview" : "No changes in this file",
                       diff.truncated ? "Open it in your editor instead." : "It may have been reverted.")
            } else {
                diffScroll
            }
        }
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc.text", description: Text(detail))
    }

    private var diffScroll: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, contentWidth)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffRowView(row: row, selected: selection?.contains(row.id) ?? false, width: width)
                    }
                    if diff?.truncated == true {
                        Text("Diff truncated: showing the first lines only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(selectionGesture)
            }
        }
    }

    // MARK: Selection

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = rowIndex(at: value.location.y)
                if !dragging {
                    dragging = true
                    // Shift-click extends the existing selection.
                    if !(NSEvent.modifierFlags.contains(.shift) && anchorRow != nil) {
                        anchorRow = rowIndex(at: value.startLocation.y)
                    }
                }
                select(from: anchorRow ?? current, to: current)
            }
            .onEnded { _ in
                dragging = false
                // The comment field appears with the selection; focus it on the
                // next turn so it exists by then.
                if selection != nil { Task { @MainActor in instructionFocused = true } }
            }
    }

    private func rowIndex(at y: CGFloat) -> Int {
        guard !rows.isEmpty else { return 0 }
        return max(0, min(rows.count - 1, Int(y / DiffMetrics.rowHeight)))
    }

    /// Selects the lines between two rows, ignoring hunk headers at the edges.
    private func select(from a: Int, to b: Int) {
        guard !rows.isEmpty else { return }
        var lo = min(a, b)
        var hi = max(a, b)
        while lo <= hi, rows[lo].line == nil { lo += 1 }
        while hi >= lo, rows[hi].line == nil { hi -= 1 }
        selection = lo <= hi ? lo...hi : nil
    }

    private var draftComment: ReviewComment? {
        guard let selection else { return nil }
        let lines = selection.compactMap { rows.indices.contains($0) ? rows[$0].line : nil }
        guard !lines.isEmpty else { return nil }
        return ReviewComment(path: file.path, lines: lines, instruction: trimmedInstruction)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft = draftComment {
                HStack {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundStyle(.secondary)
                    Text(draft.shortLabel).font(.callout.weight(.semibold))
                    Spacer()
                    Button("Clear") { selection = nil; anchorRow = nil }.buttonStyle(.link)
                }
                TextField("What should Claude change here?", text: $instruction, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($instructionFocused)
                    .onSubmit(addComment)
            }
            if !pending.isEmpty {
                pendingList
            }
            HStack {
                if draftComment != nil {
                    Button("Add Comment", action: addComment)
                        .disabled(trimmedInstruction.isEmpty)
                        .help("Keep reviewing, then send everything at once")
                }
                Spacer()
                Button(sendLabel, action: send)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend)
            }
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
    }

    private var pendingList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pending) { comment in
                HStack(spacing: 6) {
                    Text(comment.shortLabel).font(.caption.weight(.semibold))
                    Text(comment.instruction).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { model.removeReviewComment(comment.id, project: target.projectId) } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Remove comment")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var canSend: Bool {
        !pending.isEmpty || (draftComment != nil && !trimmedInstruction.isEmpty)
    }

    private var sendLabel: String {
        let count = pending.count + (draftComment != nil && !trimmedInstruction.isEmpty ? 1 : 0)
        return count > 1 ? "Send \(count) Comments to Claude" : "Send to Claude"
    }

    private func addComment() {
        guard let draft = draftComment, !trimmedInstruction.isEmpty else { return }
        model.addReviewComment(draft, project: target.projectId)
        instruction = ""
        selection = nil
        anchorRow = nil
        sendError = nil
    }

    private func send() {
        var extra: ReviewComment?
        if let draft = draftComment, !trimmedInstruction.isEmpty { extra = draft }
        if model.sendReview(project: target.projectId, extra: extra) == .noSession {
            sendError = "This project has no Claude tab. Open one with + and try again."
        }
    }

    // MARK: Loading

    private func load() async {
        do {
            let fresh = try await model.changes.loadDiff(path: target.worktreePath, file: file)
            isLoading = false
            loadError = nil
            if fresh != diff {
                diff = fresh
                rows = makeRows(fresh)
                maxChars = rows.compactMap(\.line).map { visualLength($0.text) }.max() ?? 0
                selection = nil
                anchorRow = nil
            }
        } catch {
            isLoading = false
            loadError = ChangesStore.describe(error)
        }
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    let selected: Bool
    let width: CGFloat

    var body: some View {
        Group {
            switch row.content {
            case .hunk(let header):
                Text(verbatim: header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .frame(width: width, height: DiffMetrics.rowHeight, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
            case .line(let line):
                HStack(spacing: 0) {
                    number(line.oldNumber)
                    number(line.newNumber)
                    Text(verbatim: marker(line.kind))
                        .frame(width: DiffMetrics.markerWidth)
                        .foregroundStyle(.secondary)
                    Text(verbatim: displayText(line.text) + (line.noNewlineAtEnd ? "  ⏎̸" : ""))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .font(.system(size: DiffMetrics.fontSize, design: .monospaced))
                .frame(width: width, height: DiffMetrics.rowHeight, alignment: .leading)
                .background(background(line.kind))
            }
        }
        .overlay(selected ? Color.accentColor.opacity(0.28) : Color.clear)
    }

    private func number(_ n: Int?) -> some View {
        Text(verbatim: n.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .padding(.trailing, 6)
            .frame(width: DiffMetrics.numberWidth, alignment: .trailing)
    }

    private func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .add: "+"
        case .delete: "−"
        case .context: " "
        }
    }

    private func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .add: Color.green.opacity(0.16)
        case .delete: Color.red.opacity(0.16)
        case .context: Color.clear
        }
    }
}
