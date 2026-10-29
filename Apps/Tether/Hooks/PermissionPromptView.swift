import SwiftUI
import TetherCore
import TetherProtocol

/// Native replacement for Claude Code's permission prompt while Tether is
/// running. "Ask in terminal" hands the decision back to the TUI.
struct PermissionPromptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let request: PendingPermission

    var body: some View {
        if request.toolName == AskUserQuestion.toolName,
           let prompt = AskUserQuestion.prompt(from: request.toolInput) {
            questionCard(prompt)
        } else {
            permissionCard
        }
    }

    /// Claude's own multiple-choice question: the choice goes back to it as the answer.
    private func questionCard(_ prompt: QuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            QuestionOptionsView(question: prompt) { answer in
                model.answerQuestion(request.id, answer: answer)
            }
            Button("Ask in Terminal") { model.resolvePermission(request.id, .askInTerminal) }
                .buttonStyle(.link)
        }
        .padding(14)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .background(theme.window, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.blue.opacity(0.6)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(12)
    }

    @ViewBuilder private var permissionCard: some View {
        let summary = PermissionSummary.describe(toolName: request.toolName, input: request.toolInput)
        let isTrust = request.toolName == TrustFolder.toolName
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(theme.blue).frame(width: 8, height: 8)
                Text(isTrust ? "Do you trust the files in this folder?" : "Claude wants to \(summary.title.lowercased())")
                    .font(.headline)
                Spacer()
                if !isTrust {
                    Text(request.toolName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if !summary.detail.isEmpty {
                ScrollView(.vertical) {
                    Text(summary.detail)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
            }
            if isTrust {
                Text("Claude can read and run code in a folder you trust. Tether only passes your answer to Claude Code; it never trusts a folder for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Ask in Terminal") { model.resolvePermission(request.id, .askInTerminal) }
                    .buttonStyle(.link)
                Spacer()
                Button(isTrust ? "Don't Trust" : "Deny", role: .destructive) { model.resolvePermission(request.id, .deny(message: nil)) }
                    .keyboardShortcut(.escape, modifiers: [.command])
                if request.canAllowAlways {
                    Button("Always Allow") { model.resolvePermission(request.id, .allowAlways) }
                }
                Button(isTrust ? "Trust Folder" : "Allow") { model.resolvePermission(request.id, .allow) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .background(theme.window, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.blue.opacity(0.6)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(12)
    }
}
