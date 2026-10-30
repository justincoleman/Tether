import AppKit
import SwiftUI
import TetherCore
import TetherProtocol

/// Files the user picked for `claude` or `codex` with Locate…, by tool name.
/// `ToolLocator` tries these first and skips one that has gone away.
enum ToolOverrides {
    private static let key = "toolOverrides"

    static var all: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func set(_ path: String, for tool: String) {
        var current = all
        current[tool] = path
        UserDefaults.standard.set(current, forKey: key)
    }
}

/// Shown over a Claude or Codex tab when Tether couldn't find the tool, in
/// place of the shell's "command not found".
struct MissingToolView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    let agent: AgentKind
    @State private var retrying = false
    @State private var copied = false

    private var toolName: String { agent == .claude ? "Claude Code" : "Codex" }
    private var tint: Color { agent == .claude ? theme.claude : theme.codex }

    private var installCommand: String {
        switch agent {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        }
    }

    private var guide: URL {
        switch agent {
        case .claude: URL(string: "https://code.claude.com/docs/en/overview")!
        case .codex: URL(string: "https://github.com/openai/codex")!
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tether can't find \(toolName)", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.text)
            Text("""
                It isn't on the PATH your shell sets up, or in the usual install folders. \
                If it's installed, choose the `\(agent.rawValue)` file with Locate. \
                Otherwise install it in a terminal, then try again.
                """)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(installCommand)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                    copied = true
                }
            }
            HStack(spacing: 10) {
                Button {
                    retrying = true
                    Task {
                        await model.retryMissingTool(paneId)
                        retrying = false
                    }
                } label: {
                    if retrying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Try Again")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(retrying)
                Button("Locate…", action: locate)
                Button("Install Guide") { NSWorkspace.shared.open(guide) }
                    .buttonStyle(.link)
            }
        }
        .padding(28)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.title = "Locate \(toolName)"
        panel.message = "Choose the \(agent.rawValue) program, for example ~/.local/bin/\(agent.rawValue)."
        panel.prompt = "Use"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        retrying = true
        Task {
            await model.locateTool(agent, at: url.path, pane: paneId)
            retrying = false
        }
    }
}
