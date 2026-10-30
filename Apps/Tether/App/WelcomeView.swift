import AppKit
import SwiftUI
import TetherCore

/// The first-launch walkthrough, also under Help → Welcome to Tether: check
/// the Mac's tools, pick terminal or chat, pick the window colors, add
/// projects Claude Code has already been used in, and pair an iPhone.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("welcomeSeen") private var welcomeSeen = false
    @AppStorage("appearance") private var appearance: AppearanceMode = .terminal
    @State private var step = Step.tools
    @State private var tools: [ToolRow.Tool: String?] = [:]
    @State private var checking = false
    @State private var folders: [UsedFolder]?
    @State private var chosen: Set<String> = []
    @State private var choosingFolder = false
    @State private var adding = false
    @State private var justPaired: String?

    enum Step: Int, CaseIterable {
        case tools, view, colors, projects, phone, done

        var title: String {
            switch self {
            case .tools: "Welcome to Tether"
            case .view: "Terminal or chat?"
            case .colors: "Window colors"
            case .projects: "Add your projects"
            case .phone: "Pair your iPhone"
            case .done: "You're set"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 52, height: 52)
                        Text(step.title).font(.largeTitle.weight(.bold))
                    }
                    content
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 560)
        .background(theme.window)
        .foregroundStyle(theme.text)
        .onAppear { welcomeSeen = true }
        .task { await checkTools() }
        .task { folders = await loadFolders() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.addProject(at: url) }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .tools: toolsStep
        case .view: viewStep
        case .colors: colorsStep
        case .projects: projectsStep
        case .phone: phoneStep
        case .done: doneStep
        }
    }

    private var toolsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tether runs your own tools in a terminal, so it first checks they're on this Mac.")
                .foregroundStyle(theme.secondaryText)
            ForEach(ToolRow.Tool.allCases) { tool in
                ToolRow(tool: tool, path: tools[tool] ?? nil, checking: checking && tools[tool] == nil)
            }
            Button("Check Again") { Task { await checkTools() } }
                .disabled(checking)
        }
    }

    private var viewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This is how a new Claude tab opens. You can switch any tab from the tab bar, and Claude keeps running in the terminal either way.")
                .foregroundStyle(theme.secondaryText)
            Picker("New Claude tabs open as", selection: Binding(
                get: { model.chatByDefault }, set: { model.setChatByDefault($0) })) {
                Text("Terminal: the real Claude Code, exactly as you know it").tag(false)
                Text("Chat: messages and steps laid out as a conversation, with a message box").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var colorsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The terminal always uses your Ghostty config. This is about the sidebar, tabs and panels around it.")
                .foregroundStyle(theme.secondaryText)
            Picker("Window colors", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if !TerminalHost.configWarnings.isEmpty {
                ForEach(TerminalHost.configWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
        }
    }

    private var projectsStep: some View {
        let added = Set(model.projects.map(\.path))
        let suggestions = (folders ?? []).filter { !added.contains($0.path) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("These are folders you've already used Claude Code in. Tick the ones to add; you can add others any time with ⇧⌘N.")
                .foregroundStyle(theme.secondaryText)
            if folders == nil {
                ProgressView().controlSize(.small)
            } else if suggestions.isEmpty {
                Text(added.isEmpty ? "No earlier Claude Code folders found." : "Everything Claude Code has been used in is already added.")
                    .foregroundStyle(theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions) { folder in
                        Toggle(isOn: Binding(get: { chosen.contains(folder.path) },
                                             set: { if $0 { chosen.insert(folder.path) } else { chosen.remove(folder.path) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folder.name).font(.body.weight(.medium))
                                Text(Self.abbreviate(folder.path))
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 3)
                    }
                }
            }
            HStack {
                Button("Choose a Folder…") { choosingFolder = true }
                if !model.projects.isEmpty {
                    Text("\(model.projects.count) added").foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private var phoneStep: some View {
        let hub = model.companion
        return VStack(alignment: .leading, spacing: 12) {
            Text("The iPhone app follows your Claude and Codex tabs, answers permission prompts and starts new tasks. It connects directly to this Mac over Tailscale. Skip this if you don't have the app yet; it's under Settings → iPhone later.")
                .foregroundStyle(theme.secondaryText)
            if let problem = hub.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if hub.tailnetAddress == nil {
                Label("Tailscale isn't running on this Mac. Install it on the Mac and the iPhone, sign both into the same tailnet, then press Check Again.",
                      systemImage: "network.slash")
                    .foregroundStyle(.orange)
                Button("Check Again") { hub.refreshAddress() }
            } else if let justPaired {
                Label("\(justPaired) paired.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let pairing = hub.pairing {
                PairingCard(window: pairing) { hub.cancelPairing() }
            } else {
                Button("Pair iPhone…") { Task { await hub.beginPairing() } }
            }
        }
        .onAppear { hub.refreshAddress() }
        .onChange(of: hub.devices.count) { old, new in
            if hub.pairing != nil, new > old { justPaired = hub.devices.last?.name }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A few things worth knowing:")
                .foregroundStyle(theme.secondaryText)
            Label("⌘T opens Claude, ⌥⌘T Codex and ⇧⌘T a shell, in the project you're looking at.", systemImage: "keyboard")
            Label("A project with no tabs, and the + button, show a start page: Claude, Codex, shortcuts and your recent conversations.", systemImage: "plus.square")
            Label("The sidebar sorts projects by recent use. Pin the ones you want kept at the top.", systemImage: "pin")
            Label("See this again any time under Help → Welcome to Tether.", systemImage: "questionmark.circle")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") { move(-1) }
                .disabled(step == .tools)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? theme.accent : theme.border)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step == .done {
                Button("Start Using Tether") { dismissWindow(id: "welcome") }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else {
                Button(continueTitle) { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(adding)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
    }

    private var continueTitle: String {
        switch step {
        case .projects: chosen.isEmpty ? "Continue" : "Add \(chosen.count) and Continue"
        case .phone: justPaired == nil ? "Skip for Now" : "Continue"
        default: "Continue"
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        if step == .projects, delta > 0, !chosen.isEmpty {
            addChosen(then: next)
        } else {
            step = next
        }
    }

    private func addChosen(then next: Step) {
        adding = true
        let paths = (folders ?? []).map(\.path).filter(chosen.contains)
        Task {
            for path in paths { await model.addProject(at: URL(fileURLWithPath: path, isDirectory: true)) }
            chosen = []
            adding = false
            step = next
        }
    }

    // MARK: Loading

    private func checkTools() async {
        checking = true
        tools = [:]
        await withTaskGroup(of: (ToolRow.Tool, String?).self) { group in
            for tool in ToolRow.Tool.allCases {
                group.addTask { (tool, await tool.locate()) }
            }
            for await (tool, path) in group { tools[tool] = .some(path) }
        }
        checking = false
    }

    private func loadFolders() async -> [UsedFolder] {
        await Task.detached(priority: .utility) { SessionHistory.recentFolders() }.value
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// One tool's line in the first step.
private struct ToolRow: View {
    @Environment(\.theme) private var theme
    let tool: Tool
    /// Where the login shell found it; nil when missing.
    let path: String?
    let checking: Bool

    enum Tool: CaseIterable, Identifiable {
        case claude, git, codex, tailscale

        var id: Self { self }

        var name: String {
            switch self {
            case .claude: "Claude Code"
            case .git: "Git"
            case .codex: "Codex"
            case .tailscale: "Tailscale"
            }
        }

        var detail: String {
            switch self {
            case .claude: "Runs in every Claude tab. Required."
            case .git: "Changes, branches and worktrees. Required."
            case .codex: "Optional. Adds Codex tabs beside Claude."
            case .tailscale: "Optional. Connects the iPhone app to this Mac."
            }
        }

        var required: Bool { self == .claude || self == .git }

        var help: URL? {
            switch self {
            case .claude: URL(string: "https://code.claude.com/docs/en/overview")
            case .git: URL(string: "https://git-scm.com/downloads")
            case .codex: URL(string: "https://github.com/openai/codex")
            case .tailscale: URL(string: "https://tailscale.com/download")
            }
        }

        func locate() async -> String? {
            if self == .tailscale {
                // The Mac app usually has no command-line tool on PATH.
                let app = "/Applications/Tailscale.app"
                if FileManager.default.fileExists(atPath: app) { return app }
                return await ToolProbe.resolve("tailscale")
            }
            return await ToolProbe.resolve(rawName)
        }

        private var rawName: String {
            switch self {
            case .claude: "claude"
            case .git: "git"
            case .codex: "codex"
            case .tailscale: "tailscale"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if checking {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                Image(systemName: path != nil ? "checkmark.circle.fill" : tool.required ? "xmark.circle.fill" : "minus.circle")
                    .foregroundStyle(path != nil ? theme.green : tool.required ? theme.red : theme.secondaryText)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.body.weight(.medium))
                Text(path ?? tool.detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if path == nil, !checking, let url = tool.help {
                    Link(tool.required ? "How to install" : "Get \(tool.name)", destination: url)
                        .font(.caption)
                }
            }
        }
    }
}
