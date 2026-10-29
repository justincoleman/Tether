import SwiftUI
import TetherProtocol

/// A tab's Changes, as the Mac's panel shows them: files against the base
/// branch with line counts, and each file's diff.
struct ChangesSheet: View {
    let connection: MacConnection
    let paneId: PaneID
    @Environment(\.dismiss) private var dismiss
    @State private var result: Result<ChangesSnapshot, MacConnection.ReplyError>?

    var body: some View {
        NavigationStack {
            Group {
                switch result {
                case nil:
                    ProgressView("Asking \(connection.mac.name)…")
                case .failure(let error)?:
                    ContentUnavailableView("Can't load changes", systemImage: "exclamationmark.triangle",
                                           description: Text(error.message))
                case .success(let snapshot)?:
                    list(snapshot)
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ChangedFile.self) { file in
                DiffScreen(connection: connection, paneId: paneId, file: file)
            }
        }
        .task { await load() }
    }

    private func load() async {
        result = await connection.changes(for: paneId)
    }

    @ViewBuilder
    private func list(_ snapshot: ChangesSnapshot) -> some View {
        if snapshot.files.isEmpty && snapshot.commits.isEmpty {
            ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                   description: Text(snapshot.baseRef.map { "\(snapshot.branchLabel) matches \($0)." }
                                                     ?? "The working tree is clean."))
        } else {
            List {
                Section {
                    ForEach(snapshot.files) { file in
                        NavigationLink(value: file) { FileLine(file: file) }
                    }
                } header: {
                    HStack {
                        Label(snapshot.branchLabel, systemImage: "arrow.triangle.branch")
                        Spacer()
                        Text("+\(snapshot.additions)").foregroundStyle(.green)
                        Text("−\(snapshot.deletions)").foregroundStyle(.red)
                    }
                    .font(.caption.monospacedDigit())
                    .textCase(nil)
                } footer: {
                    if let base = snapshot.baseRef { Text("Against \(base)") }
                }
                if !snapshot.commits.isEmpty {
                    Section("Commits (\(snapshot.commits.count))") {
                        ForEach(snapshot.commits) { commit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject).lineLimit(2)
                                Text(commit.shortHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
    }
}

private struct FileLine: View {
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
                    if let a = file.additions { Text("+\(a)").foregroundStyle(.green) }
                    if let d = file.deletions { Text("−\(d)").foregroundStyle(.red) }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private var color: Color {
        switch file.kind {
        case .added: .green
        case .modified: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .deleted, .conflicted: .red
        case .renamed, .copied: .blue
        case .untracked: .secondary
        }
    }
}

/// One file's unified diff. Scrolls sideways rather than wrapping, so code
/// keeps its shape.
private struct DiffScreen: View {
    let connection: MacConnection
    let paneId: PaneID
    let file: ChangedFile
    @State private var result: Result<FileDiff, MacConnection.ReplyError>?

    var body: some View {
        Group {
            switch result {
            case nil:
                ProgressView()
            case .failure(let error)?:
                ContentUnavailableView("Can't load the diff", systemImage: "exclamationmark.triangle",
                                       description: Text(error.message))
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
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task { result = await connection.diff(of: file, in: paneId) }
    }

    private func lines(_ diff: FileDiff) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(hunk.header)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5))
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
                if diff.truncated {
                    Text("Diff too long; the rest is on the Mac.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .font(.caption.monospaced())
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.newNumber.map(String.init) ?? line.oldNumber.map(String.init) ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(marker + line.text)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .add: "+ "
        case .delete: "− "
        case .context: "  "
        }
    }

    private var background: Color {
        switch line.kind {
        case .add: .green.opacity(0.15)
        case .delete: .red.opacity(0.15)
        case .context: .clear
        }
    }
}
