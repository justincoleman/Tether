import SwiftUI
import TetherProtocol

/// The same explicit workflow actions in the Remote Macs window and main chat.
struct RemoteWorkflowMenu: View {
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let projectId: ProjectID
    var session: SessionSummary?
    let onOpen: (PaneID) -> Void
    @State private var showingCreate = false
    @State private var confirmation: PullRequestAction?
    @State private var failure: String?
    @State private var running = false

    var body: some View {
        Menu {
            if let session {
                if let pr = session.pullRequest {
                    Text("#\(pr.number) · \(pr.title)")
                    Text(pr.checksSummary)
                    if let url = webURL(pr.url) { Link("Open Pull Request", destination: url) }
                    if pr.state.lowercased() == "open" {
                        Button("Merge Pull Request…") { confirmation = .merge(expectedHead: pr.headRevision) }
                        Button("Re-run Checks…") { confirmation = .rerunChecks(expectedHead: pr.headRevision) }
                    }
                } else if session.command == nil {
                    Button("Create Pull Request…") { showingCreate = true }
                }
            }
            let shortcuts = connection.snapshot?.shortcuts?.filter { $0.projectId == projectId } ?? []
            if !shortcuts.isEmpty {
                Section("Shortcuts on \(connection.mac.name)") {
                    ForEach(shortcuts) { shortcut in
                        Button("Run \(shortcut.label)") {
                            running = true
                            Task {
                                switch await connection.runShortcut(shortcut.id, paneId: session?.id) {
                                case .success(let pane): onOpen(pane)
                                case .failure(let error): failure = error.message
                                }
                                running = false
                            }
                        }
                        .help(shortcut.command)
                    }
                }
            }
            if session == nil, shortcuts.isEmpty { Text("No shortcuts in this project") }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(running || connection.status != .online)
        .help("Project workflows on \(connection.mac.name)")
        .accessibilityLabel("Project workflows")
        .sheet(isPresented: $showingCreate) {
            if let session { RemoteCreatePRSheet(connection: connection, paneId: session.id) }
        }
        .confirmationDialog("Confirm pull request action", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let action = confirmation, let session {
                Button(actionLabel(action)) {
                    confirmation = nil
                    running = true
                    Task {
                        if case .failure(let error) = await connection.performPullRequest(action, paneId: session.id) { failure = error.message }
                        running = false
                    }
                }
            }
        } message: {
            Text("Runs on \(connection.mac.name) for PR #\(session?.pullRequest?.number ?? 0), after checking that its revision has not changed.")
        }
        .alert("Workflow failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func actionLabel(_ action: PullRequestAction) -> String {
        switch action {
        case .create: "Create Pull Request"
        case .merge: "Merge Pull Request"
        case .rerunChecks: "Re-run Checks"
        }
    }
    private func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

private struct RemoteCreatePRSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let connection: MacConnection
    let paneId: PaneID
    @State private var title = ""
    @State private var details = ""
    @State private var preview = false
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview ? "Review Pull Request" : "Create Pull Request").font(.headline)
            if preview {
                Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
                ScrollView { Text(details.isEmpty ? "No description" : details).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text("Creates a pull request from this tab's branch on \(connection.mac.name).")
                    .font(.caption).foregroundStyle(theme.secondaryText)
            } else {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Text("Description").font(.caption).foregroundStyle(theme.secondaryText)
                TextEditor(text: $details).font(.body).frame(minHeight: 180)
            }
            if let failure { Text(failure).foregroundStyle(theme.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(sending)
                Spacer()
                if preview { Button("Edit") { preview = false }.disabled(sending) }
                if sending { ProgressView().controlSize(.small) }
                Button(preview ? "Create Pull Request" : "Preview") {
                    if !preview { preview = true; return }
                    sending = true
                    Task {
                        switch await connection.performPullRequest(.create(title: title, body: details), paneId: paneId) {
                        case .success: dismiss()
                        case .failure(let error): failure = error.message
                        }
                        sending = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || connection.status != .online)
            }
        }
        .padding(20).frame(width: 520, height: 370).background(theme.window)
    }
}
