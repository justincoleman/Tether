import SwiftUI
import TetherProtocol

/// One Claude tab: its conversation, a compose box, and any permission it
/// is waiting on.
struct SessionView: View {
    let connection: MacConnection
    let paneId: PaneID
    @State private var text = ""
    @State private var answering: PermissionRequested?

    private var session: SessionSummary? {
        connection.snapshot?.sessions.first { $0.id == paneId }
    }

    private var project: ProjectSummary? {
        session.flatMap { s in connection.snapshot?.projects.first { $0.id == s.projectId } }
    }

    private var permission: PermissionRequested? {
        connection.snapshot?.permissions.first { $0.paneId == paneId }
    }

    var body: some View {
        let sessionId = session?.sessionId
        let transcript = sessionId.flatMap { connection.transcripts[$0] }
        VStack(spacing: 0) {
            if let transcript, !transcript.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(transcript.items) { item in
                                PhoneTranscriptItem(item: item).id(item.id)
                            }
                            if session?.state == .working {
                                ProgressView().id("working")
                            }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: transcript.items.count) {
                        if let last = transcript.items.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            } else {
                ContentUnavailableView(session == nil ? "Tab closed" : "Nothing yet",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(session == nil
                                           ? "This Claude tab is no longer open on the Mac."
                                           : "Messages appear here as Claude works."))
                    .frame(maxHeight: .infinity)
            }
            if let permission {
                Button { answering = permission } label: {
                    Label("Claude wants to \(permission.title.lowercased())", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            if session != nil {
                compose
            }
        }
        .navigationTitle(project?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(project?.name ?? "Session").font(.headline)
                    if let session {
                        HStack(spacing: 4) {
                            PhoneStatusBadge(state: session.state).frame(width: 14)
                            Text(session.statusNote ?? session.title)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let usage = transcript?.usage {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(usage.inputTokens / 1000)k of \(usage.contextWindow / 1000)k")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: sessionId) { connection.subscribe(sessionId) }
        .onDisappear { connection.subscribe(nil) }
        .sheet(item: $answering) { request in
            PermissionSheet(connection: connection, request: request)
                .presentationDetents([.medium, .large])
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = composeNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Claude", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    connection.send(text, to: paneId)
                    text = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(!canSend)
            }
        }
        .padding()
    }

    private var canSend: Bool {
        connection.status == .online && session?.state != .detached
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composeNote: String? {
        switch connection.sendResults[paneId] {
        case "queued"?: return "Queued. The Mac sends it when Claude is ready."
        case "failed"?: return "The Mac couldn't send that."
        default: break
        }
        guard let session else { return nil }
        if session.state == .working { return "Claude is working. Your message waits for this turn to finish." }
        if session.state == .needsInput, session.attention == .dialog {
            return "Claude is waiting on a prompt only the Mac can answer."
        }
        return nil
    }
}

private struct PhoneTranscriptItem: View {
    let item: TranscriptItem

    var body: some View {
        switch item {
        case .user(_, let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color(red: 0.85, green: 0.47, blue: 0.34), in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant(_, let text, _):
            MarkdownView(text)
        case .steps(_, let steps):
            PhoneSteps(steps: steps)
        case .notice(_, let text, _):
            Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}

private struct PhoneSteps: View {
    let steps: [ToolStep]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(step.name).font(.caption.weight(.semibold))
                            if step.isRunning { ProgressView().controlSize(.mini) }
                        }
                        Text(step.summary).font(.caption.monospaced()).lineLimit(3)
                        if let result = step.result, !result.isEmpty {
                            Text(result)
                                .font(.caption2.monospaced())
                                .foregroundStyle(step.isError ? Color.red : Color.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("\(steps.count) step\(steps.count == 1 ? "" : "s")", systemImage: "hammer")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Allow or deny a permission from the phone. First answer wins: if the Mac
/// already answered, the request just disappears from the next snapshot.
struct PermissionSheet: View {
    let connection: MacConnection
    let request: PermissionRequested
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Claude wants to \(request.title.lowercased())", systemImage: "hand.raised.fill")
                .font(.headline)
            Text(request.toolName).font(.caption.monospaced()).foregroundStyle(.secondary)
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer(minLength: 0)
            HStack {
                Button("Deny", role: .destructive) {
                    connection.decide(request.id, allow: false)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                Button("Allow") {
                    connection.decide(request.id, allow: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding()
    }
}
