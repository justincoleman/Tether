import SwiftUI
import TetherCore
import TetherProtocol
import UniformTypeIdentifiers

/// Native chat view of the selected tab's Claude session, built from the
/// transcript. It replaces the terminal in the main card when the top bar's
/// toggle is on chat. The phone renders the same TranscriptModel.
struct MirrorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID?
    /// Where the conversation is scrolled to, so Send and the jump button can go to the end.
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        let sessionId = paneId.flatMap { model.sessionId(forPane: $0) }
        let transcript = model.mirror.model(for: sessionId)
        let state = paneId.flatMap { model.paneStates[$0] } ?? .idle
        let queued = paneId.flatMap { model.queuedMessages[$0] } ?? []

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

            if transcript?.items.isEmpty == false || !queued.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(transcript?.items ?? []) { item in
                            TranscriptItemView(item: item).id(item.id)
                        }
                        // Held for Claude, shown now; it becomes a normal message once Claude reads it.
                        ForEach(Array(queued.enumerated()), id: \.offset) { index, text in
                            if let paneId { QueuedBubble(paneId: paneId, index: index, text: text) }
                        }
                    }
                    .padding(16)
                    // A readable column in a wide window.
                    .frame(maxWidth: Self.columnWidth)
                    .frame(maxWidth: .infinity)
                }
                .followsLatest($position)
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
                    if let agents = transcript?.runningAgents, !agents.isEmpty {
                        RunningAgentsRow(agents: agents)
                    }
                    ChatFooter(paneId: paneId, state: state, transcript: transcript)
                    // Cards sit right above the message box, where the eye already is.
                    if let request = model.pendingPermission(forPane: paneId) {
                        PermissionPromptView(request: request)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    ComposeBar(paneId: paneId, state: state) {
                        // Sending always brings you back to the end.
                        position.scrollTo(edge: .bottom)
                    }
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

/// A chat's scrolling: it follows the conversation while you're at the end,
/// stays put once you scroll up, and offers Jump to latest until you're back.
/// Shared by this chat and a paired Mac's (RemoteSessionView).
private struct FollowsLatest: ViewModifier {
    @Environment(\.theme) private var theme
    @Binding var position: ScrollPosition
    @State private var atBottom = true

    func body(content: Content) -> some View {
        content
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 32
            } action: { _, isAtBottom in
                atBottom = isAtBottom
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button { withAnimation { position.scrollTo(edge: .bottom) } } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(theme.elevated, in: Capsule())
                            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: atBottom)
    }
}

extension View {
    /// See FollowsLatest. `position` lets Send bring the chat back to the end.
    func followsLatest(_ position: Binding<ScrollPosition>) -> some View {
        modifier(FollowsLatest(position: position))
    }
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
        // Shift-Tab before Claude starts would move the answer of a terminal question.
        .disabled(switching || !model.claudeHasStarted(paneId))
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
        .disabled(!model.claudeHasStarted(paneId))
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

/// A message waiting for Claude, in the same place it will take once sent,
/// with Edit, Remove and Send Now under it.
private struct QueuedBubble: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    let index: Int
    let text: String
    @State private var editing = false
    @State private var edited = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                Group {
                    if editing {
                        TextField("Message", text: $edited, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...10)
                            .focused($focused)
                            .onAppear { focused = true }
                            .onSubmit(save)
                            .onExitCommand { editing = false }
                    } else {
                        Text(text).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(theme.text)
                .background(theme.claude.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(theme.claude.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                HStack(spacing: 12) {
                    Label("Queued", systemImage: "clock").foregroundStyle(theme.secondaryText)
                    if editing {
                        Button("Cancel") { editing = false }
                        Button("Save", action: save)
                    } else {
                        Button("Edit") {
                            edited = text
                            editing = true
                        }
                        Button("Remove") { model.removeQueued(at: index, expected: text, forPane: paneId) }
                        Button("Send Now") { _ = model.sendQueuedNow(at: index, expected: text, forPane: paneId) }
                            .help("Stop what Claude is doing and send this now (⌃↩ in the message box)")
                    }
                }
                .font(.caption2)
                .buttonStyle(.link)
            }
        }
    }

    private func save() {
        editing = false
        model.editQueued(at: index, expected: text, to: edited, forPane: paneId)
    }
}

/// An image attached to the message box, waiting to be sent with it.
struct PastedImage: Identifiable {
    let id = UUID()
    let data: Data
    let thumbnail: NSImage
}

/// A tab's unsent message. Lives in AppModel so it survives switching tabs,
/// projects, or to the terminal and back.
struct ComposeDraft {
    var text = ""
    var images: [PastedImage] = []

    var isEmpty: Bool { text.isEmpty && images.isEmpty }
}

private struct ComposeBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    let state: SessionState
    /// Called after a message is sent or queued.
    var didSend: () -> Void = {}
    @State private var pasteNote: String?
    @State private var choosingImages = false
    @FocusState private var focused: Bool

    /// The tab's draft, kept in the model so it stays with the tab.
    private var draft: Binding<ComposeDraft> {
        Binding(get: { model.drafts[paneId] ?? ComposeDraft() },
                set: { model.drafts[paneId] = $0.isEmpty ? nil : $0 })
    }
    private var text: String { draft.wrappedValue.text }
    private var images: [PastedImage] { draft.wrappedValue.images }

    private var canSend: Bool {
        state != .detached
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
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
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in
                            Image(nsImage: image.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    Button { draft.wrappedValue.images.removeAll { $0.id == image.id } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(2)
                                }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { choosingImages = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .help("Attach pictures")
                    .padding(.bottom, 2)
                SlashMenu(paneId: paneId)
                    .disabled(state == .detached || !model.claudeHasStarted(paneId))
                    .padding(.bottom, 1)
                TextField(answersPermission ? "Return allows, Esc denies" : "Message Claude", text: draft.text, axis: .vertical)
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
                    // Command-V with an image or image files on the clipboard attaches them;
                    // text still pastes as text.
                    .onPasteCommand(of: [.image, .fileURL]) { providers in
                        attach(providers)
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
            // Key equivalents run before the text field sees Return. Option-Return
            // already starts a line natively; Shift-Return adds one at the end.
            .background {
                Group {
                    // Only while the box has focus, so a terminal beside the chat keeps its keys.
                    Button("New Line") { draft.wrappedValue.text += "\n" }
                        .keyboardShortcut(.return, modifiers: [.shift])
                        .disabled(!focused)
                    Button("Send Now", action: sendNow)
                        .keyboardShortcut(.return, modifiers: [.control])
                        .disabled(!focused || !canSend)
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if let pasteNote {
                Text(pasteNote).font(.caption).foregroundStyle(theme.red)
            }
            if state == .detached {
                Text("Claude isn't running in this tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if queued > 0 {
                Text("\(queued) message\(queued == 1 ? "" : "s") queued. Sent when Claude is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state == .working {
                Text("Claude is working. Return queues your message; ⌃Return stops Claude and sends it now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state == .needsInput, model.paneAttention[paneId] != .question {
                Text("Claude is waiting on a prompt. Your message will be sent after you answer it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .fileImporter(isPresented: $choosingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let png = NSImage(contentsOf: url).flatMap(Self.pngData) { add(png) }
            }
        }
        // Typing goes here once the chat replaces the terminal.
        .onAppear { focused = true }
        .onChange(of: paneId) { focused = true }
    }

    private func send() {
        guard canSend else { return }
        let outcome = images.isEmpty
            ? model.sendOrQueue(text, toPane: paneId)
            : model.sendWithImages(text, images: images.map(\.data), toPane: paneId)
        sent(outcome)
    }

    /// Control-Return: stop Claude's current step and send this instead.
    /// Pictures can't jump the queue, so a message with them sends normally.
    private func sendNow() {
        guard canSend else { return }
        guard images.isEmpty else { return send() }
        sent(model.sendNow(text, toPane: paneId))
    }

    private func sent(_ outcome: AppModel.SendOutcome) {
        guard outcome != .failed else { return }
        model.drafts[paneId] = nil
        pasteNote = nil
        didSend()
    }

    /// Takes images from a paste: a screenshot or copied picture, or image files copied in Finder.
    private func attach(_ providers: [NSItemProvider]) {
        for provider in providers {
            if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data, let png = NSImage(data: data).flatMap(Self.pngData) else { return }
                    Task { @MainActor in add(png) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL,
                          ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp"].contains(url.pathExtension.lowercased()),
                          let png = NSImage(contentsOf: url).flatMap(Self.pngData) else { return }
                    Task { @MainActor in add(png) }
                }
            }
        }
    }

    private nonisolated static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor private func add(_ png: Data) {
        do {
            _ = try ImageUpload.fileExtension(for: png)
        } catch {
            pasteNote = "\(error)"
            return
        }
        guard let thumbnail = NSImage(data: png) else { return }
        pasteNote = nil
        draft.wrappedValue.images.append(PastedImage(data: png, thumbnail: thumbnail))
    }
}

/// The "/" button beside the paperclip: Claude Code commands that need no typing.
/// They queue like any message, so they never land mid-turn.
private struct SlashMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID

    var body: some View {
        Menu {
            Button("Compact Conversation") { _ = model.sendOrQueue("/compact", toPane: paneId) }
            Button("Clear Conversation") { _ = model.sendOrQueue("/clear", toPane: paneId) }
        } label: {
            Text("/").font(.body.monospaced().weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(theme.secondaryText)
        .help("Compact or clear the conversation")
    }
}

/// A copy button that shows while the pointer is over a message: beside a
/// bubble (it keeps its space, so moving onto it doesn't hide it), or in the
/// top corner of Claude's full-width text.
private struct HoverCopy: ViewModifier {
    @Environment(\.theme) private var theme
    let text: String
    let beside: Bool
    @State private var hovering = false
    @State private var copied = false

    func body(content: Content) -> some View {
        Group {
            if beside {
                HStack(alignment: .bottom, spacing: 6) {
                    button.opacity(hovering || copied ? 1 : 0)
                    content
                }
            } else {
                content.overlay(alignment: .topTrailing) {
                    if hovering || copied { button.transition(.opacity) }
                }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var button: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? theme.green : theme.secondaryText)
                .padding(5)
                .background(theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Copy message")
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
                    .modifier(HoverCopy(text: text, beside: true))
            }
        case .assistant(_, let text, _):
            MarkdownView(text)
                .modifier(HoverCopy(text: text, beside: false))
        case .steps(_, let steps):
            // Subagents get a card each, outside the folded steps, so they don't hide.
            let agents = steps.filter(\.isAgent)
            let rest = steps.filter { !$0.isAgent }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(agents) { AgentCard(step: $0) }
                if !rest.isEmpty { StepsView(steps: rest) }
            }
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

/// A subagent Claude sent out: what it's for, and whether it's still going.
/// Background agents run until their task notification arrives.
private struct AgentCard: View {
    @Environment(\.theme) private var theme
    let step: ToolStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.callout)
                .foregroundStyle(theme.claude)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.summary.isEmpty ? "Subagent" : step.summary)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let result = step.result {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(step.isError && !step.isStopped ? theme.red : theme.secondaryText)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    Text("Working")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            if step.isRunning {
                ProgressView().controlSize(.small)
            } else if step.isStopped {
                Image(systemName: "stop.circle").foregroundStyle(theme.secondaryText)
            } else {
                Image(systemName: step.isError ? "xmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(step.isError ? theme.red : theme.green)
            }
        }
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 0.5))
    }
}

/// Subagents still working, pinned above the message box so they don't
/// scroll away. They can outlive the turn that started them.
private struct RunningAgentsRow: View {
    @Environment(\.theme) private var theme
    let agents: [ToolStep]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill").font(.caption).foregroundStyle(theme.claude)
            Text(agents.count == 1 ? "1 agent running:" : "\(agents.count) agents running:")
                .font(.callout.weight(.medium))
            Text(agents.map(\.summary).joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            ProgressView().controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
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
        if !model.claudeHasStarted(paneId) {
            if model.pendingPermission(forPane: paneId) == nil { StartingRow(paneId: paneId) }
        } else if state == .working || state == .needsInput {
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

/// Shown until Claude reports in. A tab that stays here is usually sitting
/// at a question in the terminal (folder trust, a login), which chat can't show.
private struct StartingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let paneId: PaneID
    @State private var slow = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(slow ? "Claude hasn't started. It may be asking something in the terminal." : "Starting Claude")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
            if slow {
                Button { model.setChat(false, forPane: paneId) } label: {
                    Label("Show Terminal", systemImage: "apple.terminal").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .task {
            try? await Task.sleep(for: .seconds(5))
            slow = true
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

    /// Quiet until it matters: orange from 70%, red from 85%.
    private var tint: Color? {
        fraction >= 0.85 ? theme.red : fraction >= 0.7 ? theme.claude : nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(Self.short(usage.inputTokens)) of \(Self.short(usage.contextWindow))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint ?? theme.secondaryText)
            ZStack {
                Circle().stroke(theme.border, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint ?? theme.secondaryText,
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
