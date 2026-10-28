import SwiftUI
import TetherCore

/// Native replacement for Claude Code's permission prompt while Tether is
/// running. "Ask in terminal" hands the decision back to the TUI.
struct PermissionPromptView: View {
    @Environment(AppModel.self) private var model
    let request: PendingPermission

    var body: some View {
        let summary = PermissionSummary.describe(toolName: request.toolName, input: request.toolInput)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.blue).frame(width: 8, height: 8)
                Text("Claude wants to \(summary.title.lowercased())")
                    .font(.headline)
                Spacer()
                Text(request.toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Ask in Terminal") { model.resolvePermission(request.id, .askInTerminal) }
                    .buttonStyle(.link)
                Spacer()
                Button("Deny", role: .destructive) { model.resolvePermission(request.id, .deny(message: nil)) }
                    .keyboardShortcut(.escape, modifiers: [.command])
                if request.canAllowAlways {
                    Button("Always Allow") { model.resolvePermission(request.id, .allowAlways) }
                }
                Button("Allow") { model.resolvePermission(request.id, .allow) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.blue.opacity(0.5)))
        .shadow(radius: 8, y: 2)
        .padding(12)
    }
}
