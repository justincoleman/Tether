import PhotosUI
import SwiftUI
import TetherProtocol
import UIKit

/// One Claude tab: its conversation, a compose box, and any permission it
/// is waiting on.
struct SessionView: View {
    @Environment(PhoneStore.self) private var store
    let connection: MacConnection
    let paneId: PaneID
    @State private var text = ""
    @State private var answering: PermissionRequested?
    @State private var confirmClose = false
    @State private var askingModel = false
    @State private var customModel = ""
    @State private var showingChanges = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: PhotoReply?
    @State private var loadingPhoto = false
    @Environment(\.dismiss) private var dismiss
    /// A tab started from the phone shows up in the next snapshot, a moment later.
    @State private var waitedForTab = false
    @AppStorage("useMacColors") private var useMacColors = true

    /// What `.macColors` puts in the environment, for this view's own controls.
    private var theme: PhoneTheme {
        (useMacColors ? connection.snapshot?.theme.flatMap(PhoneTheme.init(mac:)) : nil) ?? .system
    }

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
        sessionBody.macColors(connection.snapshot?.theme)
    }

    @ViewBuilder private var sessionBody: some View {
        let sessionId = session?.sessionId
        let transcript = sessionId.flatMap { connection.transcripts[$0] }
        VStack(spacing: 0) {
            if session == nil, !waitedForTab {
                ProgressView("Opening on \(connection.mac.name)…")
                    .frame(maxHeight: .infinity)
            } else if let transcript, !transcript.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(transcript.items) { item in
                                PhoneTranscriptItem(item: item).id(item.id)
                            }
                            if session?.state == .working {
                                WorkingRow { connection.interrupt(paneId) }.id("working")
                            }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
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
                NeedsYouCard(connection: connection, request: permission) { answering = permission }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
                            PhoneStatusBadge(state: session.state, size: 14)
                            Text(session.statusNote ?? session.title)
                            if let mode = session.permissionMode {
                                Text("· \(PermissionModeName.label(mode))")
                            }
                            if let model = session.status?.modelName {
                                Text("· \(model)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    }
                }
            }
            if session != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Changes", systemImage: "plusminus") { showingChanges = true }
                            .disabled(connection.status != .online)
                        modelMenu
                        Button("Close Thread", systemImage: "xmark.circle", role: .destructive) { confirmClose = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        // Its own row under the header, not a toolbar item: iOS groups trailing
        // items into one glass capsule, which squeezed this against the menu.
        .safeAreaInset(edge: .top, spacing: 0) {
            if transcript?.usage != nil || session?.status?.costUSD != nil {
                PhoneContextMeter(usage: transcript?.usage?.reported(window: session?.status?.contextWindow),
                                  costUSD: session?.status?.costUSD)
            }
        }
        .task(id: sessionId) { connection.subscribe(sessionId) }
        .task {
            try? await Task.sleep(for: .seconds(5))
            waitedForTab = true
        }
        .onAppear { store.visiblePaneId = paneId }
        .onDisappear {
            connection.subscribe(nil)
            if store.visiblePaneId == paneId { store.visiblePaneId = nil }
        }
        .confirmationDialog("Close this thread on \(connection.mac.name)?", isPresented: $confirmClose,
                            titleVisibility: .visible) {
            Button("Close Thread", role: .destructive) {
                connection.closeSession(paneId: paneId)
                dismiss()
            }
        } message: {
            Text(session?.state == .working
                 ? "Claude is working right now. Closing stops it."
                 : "The tab closes on the Mac. The conversation stays in Claude's history.")
        }
        .sheet(isPresented: $showingChanges) {
            ChangesSheet(connection: connection, paneId: paneId)
        }
        .onChange(of: photoItem) { loadPhoto() }
        .sheet(item: $answering) { request in
            PermissionSheet(connection: connection, request: request)
                .presentationDetents([.medium, .large])
        }
        .alert("Switch Model", isPresented: $askingModel) {
            TextField("Alias or model id", text: $customModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Switch") {
                connection.setModel(customModel, for: paneId)
                customModel = ""
            }
            Button("Cancel", role: .cancel) { customModel = "" }
        } message: {
            Text("Tether types /model and this name into the tab on \(connection.mac.name).")
        }
    }

    /// The tab's model, switched with `/model` on the Mac. The checkmark
    /// follows the status line, so it moves once Claude Code has switched.
    private var modelMenu: some View {
        let current = ModelPreset.matching(session?.status?.modelId)
        return Menu {
            Picker("Model", selection: Binding(get: { current },
                                               set: { if let alias = $0 { connection.setModel(alias, for: paneId) } })) {
                ForEach(ModelPreset.all) { preset in
                    Text(preset.label).tag(Optional(preset.alias))
                }
            }
            Button("Other…") { askingModel = true }
        } label: {
            Label(session?.status?.modelName.map { "Model: \($0)" } ?? "Model", systemImage: "cpu")
        }
        .disabled(connection.status != .online || session?.state == .detached)
    }

    private var compose: some View {
        // A local copy: the photo picker's label is a Sendable closure.
        let theme = self.theme
        return VStack(alignment: .leading, spacing: 4) {
            if let note = composeNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 4)
            }
            if let photo {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: photo.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        self.photo = nil
                        photoItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .offset(x: 6, y: -6)
                    .accessibilityLabel("Remove photo")
                }
                .padding(.top, 6)
            } else if loadingPhoto {
                ProgressView().frame(width: 64, height: 64)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 36, height: 36)
                        .background(theme.card, in: Circle())
                        .overlay(Circle().strokeBorder(theme.border.opacity(0.7)))
                }
                .disabled(connection.status != .online || session?.state == .detached)
                .accessibilityLabel("Attach a photo")
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(photo == nil ? "Message Claude" : "Add a note (optional)", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .foregroundStyle(theme.text)
                        .padding(.leading, 14)
                        .padding(.vertical, 9)
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : theme.tertiaryText)
                            .frame(width: 30, height: 30)
                            .background(canSend ? theme.claude : theme.elevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .padding(3)
                    .accessibilityLabel("Send")
                    .animation(.easeOut(duration: 0.15), value: canSend)
                }
                .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.border.opacity(0.7)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func send() {
        if let photo {
            connection.sendImage(photo.jpeg, text: text, to: paneId)
        } else {
            connection.send(text, to: paneId)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        text = ""
        photo = nil
        photoItem = nil
    }

    private var canSend: Bool {
        connection.status == .online && session?.state != .detached
            && (photo != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func loadPhoto() {
        guard let item = photoItem else { return }
        loadingPhoto = true
        photo = nil
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            let reply = await Task.detached { data.flatMap(PhotoReply.init(data:)) }.value
            // Another pick replaced this one while it loaded.
            guard photoItem == item else { return }
            loadingPhoto = false
            photo = reply
            if reply == nil { photoItem = nil }
        }
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

/// A picked photo, shrunk for the trip to the Mac: Claude reads images up
/// to about 2000 px on the long side, so anything bigger only costs time.
private struct PhotoReply: Sendable {
    let jpeg: Data
    let thumbnail: UIImage

    static let maxSide: CGFloat = 2048

    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, Self.maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Drawing also applies the EXIF orientation, so the Mac gets it upright.
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        self.jpeg = jpeg
        self.thumbnail = resized.preparingThumbnail(of: CGSize(width: 128, height: 128 * target.height / max(target.width, 1))) ?? resized
    }
}

/// "148k of 1M context · $1.24" with a ring, like the Mac's ContextMeter.
/// Either half may be missing until the transcript or status line reports it.
private struct PhoneContextMeter: View {
    @Environment(\.phoneTheme) private var theme
    let usage: ContextUsage?
    let costUSD: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let usage {
                let fraction = Self.fraction(usage)
                ZStack {
                    Circle().stroke(theme.elevated, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(fraction > 0.85 ? theme.red : theme.claude,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
                Text("\(Self.short(usage.inputTokens)) of \(Self.short(usage.contextWindow))")
                    .foregroundStyle(theme.text)
                    .accessibilityLabel("\(Int(fraction * 100)) percent of context used")
                Text("context").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
            }
            if let costUSD {
                if usage != nil { Text("·").foregroundStyle(theme.secondaryText).accessibilityHidden(true) }
                Text(costUSD.formatted(.currency(code: "USD")))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("Cost \(costUSD.formatted(.currency(code: "USD")))")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.card, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    static func fraction(_ usage: ContextUsage) -> Double {
        min(1, Double(usage.inputTokens) / Double(max(usage.contextWindow, 1)))
    }

    static func short(_ n: Int) -> String {
        n >= 1_000_000 ? "\(n / 1_000_000)M" : "\(n / 1000)k"
    }
}

private struct PhoneTranscriptItem: View {
    @Environment(\.phoneTheme) private var theme
    let item: TranscriptItem

    var body: some View {
        switch item {
        case .user(_, let text, _):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(theme.claude, in: UnevenRoundedRectangle(
                        topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6,
                        topTrailingRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant(_, let text, _):
            MarkdownView(text)
        case .steps(_, let steps):
            PhoneSteps(steps: steps)
        case .notice(_, let text, _):
            Text(text)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(theme.card, in: Capsule())
                .frame(maxWidth: .infinity)
        }
    }
}

private struct PhoneSteps: View {
    @Environment(\.phoneTheme) private var theme
    let steps: [ToolStep]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps) { step in
                    PhoneStepRow(step: step)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hammer").font(.caption.weight(.semibold))
                Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                if steps.contains(where: { $0.isError && !$0.isStopped }) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.red)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.secondaryText)
        }
        .tint(theme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One tool call: the file it touched, the lines an edit changed, and for a
/// command whether it worked, was stopped or failed, and its last lines.
private struct PhoneStepRow: View {
    let step: ToolStep

    private var isCommand: Bool { step.name == "Bash" }
    private var quietResult: Bool { step.file != nil && !step.isError }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(step.name).font(.caption.weight(.semibold))
                if isCommand, step.result != nil { outcome }
                if step.isRunning { ProgressView().controlSize(.mini) }
            }
            Text(step.file.map { ($0 as NSString).lastPathComponent } ?? step.summary)
                .font(.caption.monospaced())
                .lineLimit(3)
            if !step.removed.isEmpty || !step.added.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(step.removed.enumerated()), id: \.offset) { _, line in
                        Text("- " + line).foregroundStyle(.red)
                    }
                    ForEach(Array(step.added.enumerated()), id: \.offset) { _, line in
                        Text("+ " + line).foregroundStyle(.green)
                    }
                }
                .font(.caption2.monospaced())
                .lineLimit(1)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if let result = step.result, !result.isEmpty, !quietResult {
                Text(isCommand ? result : (step.resultFirstLine ?? result))
                    .font(.caption2.monospaced())
                    .foregroundStyle(step.isError && !step.isStopped ? Color.red : Color.secondary)
                    .lineLimit(isCommand ? 6 : 2)
            }
        }
    }

    @ViewBuilder private var outcome: some View {
        if step.isStopped {
            Label("Stopped", systemImage: "stop.circle").font(.caption2).foregroundStyle(.secondary)
        } else if step.isError {
            Label("Failed", systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
        } else {
            Label("Worked", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(.green)
        }
    }
}

/// Allow or deny a permission from the phone. First answer wins: if the Mac
/// already answered, the request just disappears from the next snapshot.
struct PermissionSheet: View {
    let connection: MacConnection
    let request: PermissionRequested

    var body: some View {
        PermissionSheetBody(connection: connection, request: request)
            .macColors(connection.snapshot?.theme)
    }
}

private struct PermissionSheetBody: View {
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let connection: MacConnection
    let request: PermissionRequested

    var body: some View {
        if let question = request.question {
            ScrollView {
                PhoneQuestionView(question: question) { answer in
                    connection.answer(request.id, answer: answer)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                } skip: {
                    decide(false)
                }
                .padding(20)
            }
        } else {
            permissionBody
        }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.isFolderTrust ? "folder.badge.questionmark" : "hand.raised.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(theme.blue, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.heading)
                        .font(.headline)
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(request.toolName)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.elevated, in: Capsule())
                }
            }
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.border.opacity(0.6)))
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(request.isFolderTrust ? "Don't Trust" : "Deny") { decide(false) }
                    .buttonStyle(PillButtonStyle(tint: theme.red))
                Button(request.isFolderTrust ? "Trust Folder" : "Allow") { decide(true) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
            .controlSize(.large)
            .disabled(connection.status != .online)
        }
        .padding(20)
    }

    private func decide(_ allow: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(allow ? .success : .warning)
        connection.decide(request.id, allow: allow)
        dismiss()
    }
}
