import SwiftUI
import TetherProtocol

/// Mutations stay explicit and are checked again against the current branch
/// and revision by AppModel/GitHubCLI before reaching GitHub.
struct PullRequestActionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    @State private var creating = false
    @State private var title = ""
    @State private var description = ""
    @State private var pendingAction: PullRequestAction?
    @State private var confirming = false
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        let status = model.worktreePath(forPane: paneId).flatMap { model.pullRequest(forPath: $0) }
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) }
            Menu {
                Button("Create pull request…") {
                    message = nil
                    creating = true
                }
                .disabled(status?.state == .open)
                if let status, status.state == .open {
                    Button("Merge pull request…") {
                        pendingAction = .merge(expectedHead: status.headRevision)
                        confirming = true
                    }
                    .disabled(status.isDraft || status.headRevision.isEmpty)
                    Button("Rerun failed checks…") {
                        pendingAction = .rerunChecks(expectedHead: status.headRevision)
                        confirming = true
                    }
                    .disabled(status.failed == 0 || status.headRevision.isEmpty)
                }
            } label: {
                Label("Pull request actions", systemImage: "arrow.triangle.pull")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            .help("Create, merge or rerun failed GitHub Actions checks")
            if let message {
                Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(failed ? theme.red : theme.green)
                    .help(message)
                    .accessibilityLabel(message)
            }
        }
        .sheet(isPresented: $creating) { createSheet }
        .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(confirmationButton) {
                if let pendingAction { perform(pendingAction) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("This changes the pull request on GitHub. Tether verifies that its branch and revision still match what you reviewed.")
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create pull request").font(.headline)
            Text("Publish the branch with your git workflow first. Creating a pull request sends this title and description to GitHub.")
                .font(.callout).foregroundStyle(theme.secondaryText)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("Description").font(.caption).foregroundStyle(theme.secondaryText)
            TextEditor(text: $description)
                .frame(minHeight: 150)
                .border(theme.secondaryText.opacity(0.25))
                .accessibilityLabel("Pull request description")
            if let message, failed {
                Text(message).foregroundStyle(theme.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { creating = false }.disabled(busy)
                Button("Create on GitHub") { perform(.create(title: title, body: description)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(theme.surface)
        .interactiveDismissDisabled(busy)
    }

    private var confirmationTitle: String {
        if case .merge = pendingAction { return "Squash and merge this pull request?" }
        return "Rerun failed GitHub Actions checks?"
    }

    private var confirmationButton: String {
        if case .merge = pendingAction { return "Merge on GitHub" }
        return "Rerun failed checks"
    }

    private func perform(_ action: PullRequestAction) {
        busy = true
        message = nil
        Task { @MainActor in
            do {
                message = try await model.performPullRequest(action, paneId: paneId)
                failed = false
                if case .create = action { creating = false }
            } catch {
                message = String(describing: error)
                failed = true
            }
            busy = false
            pendingAction = nil
        }
    }
}
