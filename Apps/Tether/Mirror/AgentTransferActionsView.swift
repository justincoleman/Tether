import SwiftUI
import TetherCore
import TetherProtocol

struct AgentTransferDraft: Identifiable {
    let id = UUID()
    let paneId: PaneID
    let kind: AgentTransferKind
    let target: AgentKind
    let directory: String
    let revision: String
    let branch: String
    var message: String
}

struct AgentTransferActionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    @State private var draft: AgentTransferDraft?
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Menu {
            let target = model.agent(for: paneId) == .codex ? "Claude" : "Codex"
            Button("Review with \(target)…") { prepare(.review) }
            Button("Hand off to \(target)…") { prepare(.handoff) }
            if let error { Text(error) }
        } label: { Image(systemName: "arrow.left.arrow.right") }
        .menuStyle(.borderlessButton).fixedSize().disabled(busy)
        .help(error ?? "Review or hand off to the other agent")
        .sheet(item: $draft) { transfer in
            VStack(alignment: .leading, spacing: 12) {
                Text(transfer.kind == .review ? "Review with \(transfer.target.displayName)" : "Hand off to \(transfer.target.displayName)")
                    .font(.headline)
                Text("A new tab will open in \(transfer.directory). The source conversation stays open.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                if transfer.kind == .review {
                    Text("Review uses read-only access in Codex or plan mode in Claude.").font(.caption)
                }
                TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 260)
                if let error { Text(error).foregroundStyle(theme.red).textSelection(.enabled) }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { draft = nil }.disabled(busy)
                    Button(transfer.kind == .review ? "Start Review" : "Start Handoff") {
                        busy = true
                        Task {
                            do { try await model.startTransfer(transfer, message: text); draft = nil; error = nil }
                            catch { self.error = String(describing: error) }
                            busy = false
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(22).frame(width: 620).background(theme.surface).interactiveDismissDisabled(busy)
        }
    }

    private func prepare(_ kind: AgentTransferKind) {
        busy = true; error = nil
        Task {
            do { let value = try await model.transferDraft(for: paneId, kind: kind); text = value.message; draft = value }
            catch { self.error = String(describing: error) }
            busy = false
        }
    }
}
