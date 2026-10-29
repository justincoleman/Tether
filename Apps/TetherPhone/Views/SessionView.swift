import PhotosUI
import SwiftUI
import TetherProtocol

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
                    Label(permission.heading, systemImage: "hand.raised.fill")
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
                            if let mode = session.permissionMode {
                                Text("· \(PermissionModeName.label(mode))")
                            }
                            if let model = session.status?.modelName {
                                Text("· \(model)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Image(systemName: "ellipsis.circle")
                    }
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
        VStack(alignment: .leading, spacing: 4) {
            if let note = composeNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
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
                    Image(systemName: "photo.badge.plus").font(.title2)
                }
                .disabled(connection.status != .online || session?.state == .detached)
                .padding(.bottom, 6)
                .accessibilityLabel("Attach a photo")
                TextField(photo == nil ? "Message Claude" : "Add a note (optional)", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    if let photo {
                        connection.sendImage(photo.jpeg, text: text, to: paneId)
                    } else {
                        connection.send(text, to: paneId)
                    }
                    text = ""
                    photo = nil
                    photoItem = nil
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

/// Claude Code's model aliases. Anything else goes through "Other…".
private struct ModelPreset: Identifiable {
    let label: String
    let alias: String
    var id: String { alias }

    static let all = [
        ModelPreset(label: "Default", alias: "default"),
        ModelPreset(label: "Opus", alias: "opus"),
        ModelPreset(label: "Sonnet", alias: "sonnet"),
        ModelPreset(label: "Haiku", alias: "haiku"),
        ModelPreset(label: "Opus Plan, Sonnet Code", alias: "opusplan"),
    ]

    /// The family alias in a model id like "claude-opus-5-5". Default and
    /// opusplan can't be told apart from the id, so they never show checked.
    static func matching(_ modelId: String?) -> String? {
        guard let modelId else { return nil }
        return ["opus", "sonnet", "haiku"].first { modelId.contains($0) }
    }
}

/// "148k of 1M context · $1.24" with a ring, like the Mac's ContextMeter.
/// Either half may be missing until the transcript or status line reports it.
private struct PhoneContextMeter: View {
    let usage: ContextUsage?
    let costUSD: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let usage {
                let fraction = Self.fraction(usage)
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(fraction > 0.85 ? Color.red : Color(red: 0.85, green: 0.47, blue: 0.34),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
                Text("\(Self.short(usage.inputTokens)) of \(Self.short(usage.contextWindow))")
                    .foregroundStyle(.primary)
                    .accessibilityLabel("\(Int(fraction * 100)) percent of context used")
                Text("context").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if let costUSD {
                if usage != nil { Text("·").foregroundStyle(.secondary).accessibilityHidden(true) }
                Text(costUSD.formatted(.currency(code: "USD")))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cost \(costUSD.formatted(.currency(code: "USD")))")
            }
        }
        .font(.footnote.monospacedDigit())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
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
                            let isCommand = step.name == "Bash"
                            Text(isCommand ? result : (step.resultFirstLine ?? result))
                                .font(.caption2.monospaced())
                                .foregroundStyle(step.isError && !step.isStopped ? Color.red : Color.secondary)
                                .lineLimit(isCommand ? 6 : 2)
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
            Label(request.heading, systemImage: "hand.raised.fill")
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
                Button(request.isFolderTrust ? "Don't Trust" : "Deny", role: .destructive) {
                    connection.decide(request.id, allow: false)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                Button(request.isFolderTrust ? "Trust Folder" : "Allow") {
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
