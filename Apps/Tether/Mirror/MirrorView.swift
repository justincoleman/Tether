import SwiftUI
import TetherCore
import TetherProtocol

/// Native chat view of the selected tab's Claude session, built from the
/// transcript. The phone (phase 5) renders the same TranscriptModel.
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
                Spacer()
                if let usage = transcript?.usage { ContextMeter(usage: usage) }
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
                            if state == .working {
                                ProgressView().controlSize(.small).id("working")
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: transcript.items.count, initial: true) {
                        if let last = transcript.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            } else {
                ContentUnavailableView(sessionId == nil ? "No Claude session" : "Nothing yet",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(sessionId == nil
                                           ? "Select a Claude tab to see its conversation."
                                           : "Messages appear here as Claude works."))
                    .frame(maxHeight: .infinity)
            }

            if let paneId, sessionId != nil {
                Divider()
                ComposeBar(paneId: paneId, state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ComposeBar: View {
    @Environment(AppModel.self) private var model
    let paneId: PaneID
    let state: SessionState
    @State private var text = ""

    private var canSend: Bool {
        state != .working && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Claude", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            if state == .working {
                Text("Claude is working. Send once it finishes, or type in the terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func send() {
        guard canSend else { return }
        if model.sendPrompt(text, toPane: paneId) { text = "" }
    }
}

private struct TranscriptItemView: View {
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
                    .background(Color(red: 0.85, green: 0.47, blue: 0.34), in: RoundedRectangle(cornerRadius: 14))
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
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: Self.icon(step.name))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.name).font(.caption.weight(.semibold))
                            Text(step.summary)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .textSelection(.enabled)
                            if let result = step.result, !result.isEmpty {
                                Text(result)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(step.isError ? Color.red : Color.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        if step.isRunning { ProgressView().controlSize(.mini) }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hammer").font(.caption)
                Text(label).font(.callout)
                if steps.contains(where: \.isError) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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

/// "174k of 200k" with a ring, like the phone header.
struct ContextMeter: View {
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
                Circle().stroke(.quaternary, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fraction > 0.85 ? Color.red : Color.orange,
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
