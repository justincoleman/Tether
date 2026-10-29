import SwiftUI
import TetherCore
import TetherProtocol

/// Native chat view of the selected tab's Claude session, built from the
/// transcript. It replaces the terminal in the main card when the top bar's
/// toggle is on chat. The phone renders the same TranscriptModel.
struct MirrorView: View {
    @Environment(AppModel.self) private var model
    let paneId: PaneID?

    var body: some View {
        let sessionId = paneId.flatMap { model.sessionId(forPane: $0) }
        let transcript = model.mirror.model(for: sessionId)
        let state = paneId.flatMap { model.paneStates[$0] } ?? .idle

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Chat").font(.headline)
                StatusBadge(state: state)
                if let paneId, sessionId != nil, state != .detached {
                    ChatModeMenu(paneId: paneId)
                    ChatModelMenu(paneId: paneId)
                }
                Spacer()
                if let limits = model.usageLimits.flatMap({ SavedLimits.current($0, now: Date()) }) {
                    PlanUsageMeters(limits: limits)
                }
                if let usage = transcript?.usage {
                    ContextMeter(usage: usage.reported(window: paneId.flatMap { model.paneStatus[$0]?.contextWindow }))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()

            if let transcript, !transcript.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(transcript.items) { item in
                                TranscriptItemView(item: item).id(item.id)
                            }
                        }
                        .padding(16)
                        // A readable column in a wide window.
                        .frame(maxWidth: Self.columnWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: transcript.items.count, initial: true) {
                        if let last = transcript.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            } else {
                ContentUnavailableView(sessionId == nil ? "No Claude session" : "Nothing yet",
                                       systemImage: sessionId == nil ? "bubble.left.and.bubble.right" : "sparkle",
                                       description: Text(sessionId == nil
                                           ? "Select a Claude tab to see its conversation."
                                           : "Send Claude its first message below."))
                    .frame(maxHeight: .infinity)
            }

            if let paneId, sessionId != nil {
                VStack(spacing: 0) {
                    ChatFooter(paneId: paneId, state: state, transcript: transcript)
                    // Cards sit right above the message box, where the eye already is.
                    if let request = model.pendingPermission(forPane: paneId) {
                        PermissionPromptView(request: request)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    ComposeBar(paneId: paneId, state: state)
                }
                .animation(.snappy, value: model.pendingPermissions.map(\.id))
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static let columnWidth: CGFloat = 820
}

/// The tab's permission mode, switched the way the keyboard does: Shift-Tab
/// until Claude Code lands on the choice.
private struct ChatModeMenu: View {
    @Environment(AppModel.self) private var model
    let paneId: PaneID
    @State private var switching = false
    @State private var failed = false

    var body: some View {
        let current = model.paneModes[paneId]
        Menu {
            ForEach(PermissionModeName.launchable, id: \.self) { mode in
                Button { switchTo(mode) } label: {
                    if mode == current {
                        Label(PermissionModeName.label(mode), systemImage: "checkmark")
                    } else {
                        Text(PermissionModeName.label(mode))
                    }
                }
            }
        } label: {
            Label(current.map(PermissionModeName.label) ?? "Mode", systemImage: current.map(PermissionModeName.symbol) ?? "shield")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(switching)
        .help("Permission mode. Presses ⇧⇥ in Claude until it lands on your choice.")
        .alert("Couldn't switch mode", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Claude Code didn't confirm the change. That mode may not be enabled for this tab; press ⇧⇥ in the terminal to see which are.")
        }
    }

    private func switchTo(_ mode: String) {
        switching = true
        Task {
            let ok = await model.setPermissionMode(mode, forPane: paneId)
            switching = false
            failed = !ok
        }
    }
}

/// The tab's model, switched with `/model`, queued behind a turn in progress.
private struct ChatModelMenu: View {
    @Environment(AppModel.self) private var model
    let paneId: PaneID
    @State private var askingOther = false
    @State private var custom = ""

    var body: some View {
        let status = model.paneStatus[paneId]
        Menu {
            Picker("Model", selection: Binding(get: { ModelPreset.matching(status?.modelId) },
                                               set: { if let alias = $0 { model.setModel(alias, forPane: paneId) } })) {
                ForEach(ModelPreset.all) { preset in
                    Text(preset.label).tag(Optional(preset.alias))
                }
            }
            Button("Other…") { askingOther = true }
        } label: {
            Label(status?.modelName ?? "Model", systemImage: "cpu").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model. Sent as /model, after the current turn if Claude is working.")
        .alert("Switch model", isPresented: $askingOther) {
            TextField("Alias or model id", text: $custom)
            Button("Switch") {
                model.setModel(custom, forPane: paneId)
                custom = ""
            }
            Button("Cancel", role: .cancel) { custom = "" }
        } message: {
            Text("An alias like opus, or a full model id.")
        }
    }
}

private struct ComposeBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    let state: SessionState
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        state != .detached && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var queued: Int { model.queuedCounts[paneId] ?? 0 }
    private var permission: PendingPermission? { model.pendingPermission(forPane: paneId) }
    /// Return and Escape answer the permission only while nothing is typed.
    /// Never a folder-trust or multiple-choice question: those take a deliberate click.
    private var answersPermission: Bool {
        permission != nil && permission?.toolName != TrustFolder.toolName
            && permission?.toolName != AskUserQuestion.toolName && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(answersPermission ? "Return allows, Esc denies" : "Message Claude", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit {
                        if answersPermission, let permission {
                            model.resolvePermission(permission.id, .allow)
                        } else {
                            send()
                        }
                    }
                    .onExitCommand {
                        if answersPermission, let permission {
                            model.resolvePermission(permission.id, .deny(message: nil))
                        }
                    }
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? theme.accent : theme.secondaryText)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 0.5))
            if state == .detached {
                Text("Claude isn't running in this tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if queued > 0 {
                Text("\(queued) message\(queued == 1 ? "" : "s") queued. Sent when Claude is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state == .working {
                Text("Claude is working. Your message will be sent when it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state == .needsInput, model.paneAttention[paneId] != .question {
                Text("Claude is waiting on a prompt. Your message will be sent after you answer it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        // Typing goes here once the chat replaces the terminal.
        .onAppear { focused = true }
        .onChange(of: paneId) { focused = true }
    }

    private func send() {
        guard canSend else { return }
        if model.sendOrQueue(text, toPane: paneId) != .failed { text = "" }
    }
}

struct TranscriptItemView: View {
    @Environment(\.theme) private var theme
    let item: TranscriptItem

    var body: some View {
        switch item {
        case .user(_, let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(theme.claude, in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant(_, let text, _):
            MarkdownView(text)
        case .steps(_, let steps):
            StepsView(steps: steps)
        case .notice(_, let text, _):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

}

private struct StepsView: View {
    @Environment(\.theme) private var theme
    let steps: [ToolStep]
    @State private var expanded = false

    private var label: String {
        let ran = steps.filter { $0.name == "Bash" }.count
        let used = steps.count - ran
        var parts: [String] = []
        if used > 0 { parts.append("used \(used)") }
        if ran > 0 { parts.append("ran \(ran)") }
        let noun = steps.count == 1 ? "step" : "steps"
        return "\(steps.count) \(noun)" + (parts.isEmpty ? "" : " · " + parts.joined(separator: ", "))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in
                    StepRow(step: step)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hammer").font(.caption)
                Text(label).font(.callout)
                if steps.contains(where: { $0.isError && !$0.isStopped }) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(theme.red)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(theme.hover, in: RoundedRectangle(cornerRadius: 8))
    }

    static func icon(_ tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

/// One tool call: a file opens on click, an edit shows the lines it changed,
/// and a command shows how it ended and the last lines it printed.
private struct StepRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let step: ToolStep

    private var isCommand: Bool { step.name == "Bash" }
    /// A file tool's result ("File updated…", the file's text) is noise unless it went wrong.
    private var quietResult: Bool { step.file != nil && !step.isError }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: StepsView.icon(step.name))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.name).font(.caption.weight(.semibold))
                    if isCommand, step.result != nil { outcome }
                }
                summary
                if !step.removed.isEmpty || !step.added.isEmpty { changedLines }
                if let result = step.result, !result.isEmpty, !quietResult {
                    Text(isCommand ? result : (step.resultFirstLine ?? result))
                        .font(.caption.monospaced())
                        .foregroundStyle(step.isError && !step.isStopped ? theme.red : theme.secondaryText)
                        .lineLimit(isCommand ? 6 : 2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if step.isRunning { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder private var summary: some View {
        if let file = step.file, let relative = model.relativePath(ofAbsolute: file) {
            Button { model.openFile(relative) } label: {
                Text(relative)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Open \(relative)")
        } else {
            Text(step.summary)
                .font(.caption.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var outcome: some View {
        if step.isStopped {
            Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(theme.secondaryText)
        } else if step.isError {
            Label("Failed", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(theme.red)
        } else {
            Label("Worked", systemImage: "checkmark.circle").font(.caption).foregroundStyle(theme.green)
        }
    }

    private var changedLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(step.removed.enumerated()), id: \.offset) { _, line in
                Text("- " + line).foregroundStyle(theme.red)
            }
            ForEach(Array(step.added.enumerated()), id: \.offset) { _, line in
                Text("+ " + line).foregroundStyle(theme.green)
            }
        }
        .font(.caption.monospaced())
        .lineLimit(1)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// What Claude is doing right now, how long this turn has run, and Stop.
private struct ChatFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    let state: SessionState
    let transcript: TranscriptModel?

    var body: some View {
        if state == .working || state == .needsInput {
            HStack(spacing: 8) {
                if state == .working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(theme.blue)
                }
                Text(activity)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let start = model.turnStartedAt[paneId] { RunningTime(start: start) }
                Spacer(minLength: 0)
                if state == .working {
                    Button { model.interrupt(pane: paneId) } label: {
                        Label("Stop", systemImage: "stop.fill").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Stop Claude (same as Esc in the terminal)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var activity: String {
        if state == .needsInput {
            switch model.paneAttention[paneId] {
            case .permission?: return "Waiting for you to allow or deny"
            case .question?: return "Waiting for your answer"
            default: return "Waiting on you"
            }
        }
        guard case .steps(_, let steps)? = transcript?.items.last,
              let running = steps.last(where: \.isRunning) else { return "Thinking" }
        let target = running.file.map { ($0 as NSString).lastPathComponent }
        switch running.name {
        case "Bash": return "Running " + String(running.summary.prefix(80))
        case "Read": return "Reading " + (target ?? "a file")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing " + (target ?? "a file")
        case "Grep", "Glob": return "Searching " + String(running.summary.prefix(60))
        default: return "Using " + running.name
        }
    }
}

/// The plan's 5-hour and 7-day usage as two small bars, from the status
/// line's report. Nothing shows until Claude Code has reported them.
struct PlanUsageMeters: View {
    @Environment(\.theme) private var theme
    let limits: UsageLimits

    var body: some View {
        HStack(spacing: 10) {
            if let limit = limits.fiveHour { meter("5h", name: "5-hour", limit) }
            if let limit = limits.sevenDay { meter("7d", name: "7-day", limit) }
        }
    }

    private func meter(_ label: String, name: String, _ limit: UsageLimit) -> some View {
        let used = min(max(limit.usedPercent, 0), 100)
        let width: CGFloat = 34
        return HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Capsule()
                .fill(theme.border)
                .frame(width: width, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(used >= 90 ? theme.red : theme.claude)
                        .frame(width: width * used / 100, height: 4)
                }
            Text("\(Int(used.rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(name) plan usage: \(Int(used.rounded()))%"
              + (limit.resetsAt.map { ". Resets \($0.formatted(.relative(presentation: .named)))." } ?? "."))
    }
}

/// "174k of 200k" with a ring, like the phone header.
struct ContextMeter: View {
    @Environment(\.theme) private var theme
    let usage: ContextUsage

    private var fraction: Double {
        min(1, Double(usage.inputTokens) / Double(max(usage.contextWindow, 1)))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(Self.short(usage.inputTokens)) of \(Self.short(usage.contextWindow))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(theme.border, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fraction > 0.85 ? theme.red : theme.claude,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        }
        .help("Context used by this session")
    }

    static func short(_ n: Int) -> String {
        n >= 1_000_000 ? "\(n / 1_000_000)M" : "\(n / 1000)k"
    }
}
