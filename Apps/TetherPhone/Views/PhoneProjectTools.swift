import SwiftUI
import TetherProtocol
import UIKit

struct PhoneHistorySheet: View {
    let connection: MacConnection
    let project: ProjectSummary
    let open: (PaneID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var result: Result<[PastSessionInfo], MacConnection.ReplyError>?
    @State private var query = ""
    @State private var resuming: SessionID?
    @State private var failure: String?

    var body: some View {
        PhoneToolSheet(title: "History", connection: connection) {
            switch result {
            case nil: ProgressView("Loading history…")
            case .failure(let error)?: PhoneToolError(title: "Can't load history", message: error.message)
            case .success(let sessions)?:
                List {
                    if let failure { Text(failure).foregroundStyle(.red) }
                    if sessions.isEmpty { Text("No past sessions in this project.").foregroundStyle(.secondary) }
                    ForEach(sessions.filter { $0.matches(query) }) { session in
                        Button {
                            resuming = session.id
                            Task {
                                switch await connection.resumeSession(session.id, projectId: project.id) {
                                case .started(let pane): dismiss(); open(pane)
                                case .failed(let message): failure = message
                                }
                                resuming = nil
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.displayTitle).lineLimit(2)
                                    Text(session.lastActivity, style: .relative).font(.caption).foregroundStyle(.secondary)
                                    if let branch = session.branch { Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if resuming == session.id { ProgressView() }
                            }
                        }
                        .disabled(resuming != nil || connection.status != .online)
                    }
                }
                .searchable(text: $query, prompt: "Search history")
                .refreshable { await load() }
            }
        }
        .task { await load() }
    }
    private func load() async { result = await connection.history(for: project.id) }
}

struct PhoneFilesSheet: View {
    let connection: MacConnection
    let paneId: PaneID
    @State private var result: Result<[String], MacConnection.ReplyError>?
    @State private var query = ""

    var body: some View {
        PhoneToolSheet(title: "Files", connection: connection) {
            switch result {
            case nil: ProgressView("Loading files…")
            case .failure(let error)?: PhoneToolError(title: "Can't load files", message: error.message)
            case .success(let paths)?:
                List {
                    if paths.isEmpty { Text("No files in this folder.").foregroundStyle(.secondary) }
                    ForEach(paths.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { path in
                        NavigationLink { PhoneFileScreen(connection: connection, paneId: paneId, path: path) } label: {
                            Label(path, systemImage: "doc").font(.callout.monospaced())
                        }
                    }
                }
                .searchable(text: $query, prompt: "Find a file")
                .refreshable { result = await connection.fileList(for: paneId) }
            }
        }
        .task { result = await connection.fileList(for: paneId) }
    }
}

private struct PhoneFileScreen: View {
    let connection: MacConnection
    let paneId: PaneID
    let path: String
    @State private var result: Result<RemoteFile, MacConnection.ReplyError>?

    var body: some View {
        Group {
            switch result {
            case nil: ProgressView()
            case .failure(let error)?: PhoneToolError(title: "Can't read file", message: error.message)
            case .success(let file)?:
                VStack(spacing: 0) {
                    if file.truncated { Text("Only the start of this file is shown.").font(.caption).padding(8) }
                    switch file.kind {
                    case .text:
                        ScrollView([.horizontal, .vertical]) {
                            Text(file.text ?? "").font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading).padding()
                        }
                    case .image:
                        if let bytes = file.image, let image = UIImage(data: bytes) {
                            ScrollView { Image(uiImage: image).resizable().scaledToFit().padding() }
                        } else { PhoneToolError(title: "Can't display image", message: "The image data could not be decoded.") }
                    case .binary: ContentUnavailableView("Binary file", systemImage: "doc", description: Text("Open this file on the Mac."))
                    case .unreadable: PhoneToolError(title: "Can't read file", message: file.note ?? "This file is unavailable.")
                    }
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { result = await connection.file(path, in: paneId) }
    }
}

struct PhoneDevServersSheet: View {
    let connection: MacConnection
    let paneId: PaneID
    @State private var result: Result<[DevServerInfo], MacConnection.ReplyError>?

    var body: some View {
        PhoneToolSheet(title: "Dev Servers", connection: connection) {
            switch result {
            case nil: ProgressView("Looking for servers…")
            case .failure(let error)?: PhoneToolError(title: "Can't load servers", message: error.message)
            case .success(let servers)?:
                if servers.isEmpty {
                    ContentUnavailableView("No dev server running", systemImage: "network", description: Text("Start a server in this folder on the Mac, then refresh."))
                        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } } }
                } else {
                    List {
                        Section {
                        ForEach(servers) { server in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(server.command).font(.callout.monospaced()).textSelection(.enabled)
                                if let url = serverURL(host: connection.mac.host, port: server.port) {
                                    Link("Open \(connection.mac.host):\(server.port)", destination: url)
                                } else { Text("Invalid Tailscale address or port.").foregroundStyle(.red) }
                            }
                        }
                        } footer: {
                        Text("The server must listen on the network, for example with --host. Your phone must be on the same Tailscale network.")
                        }
                    }
                    .refreshable { await load() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async { result = await connection.devServers(for: paneId) }

    private func serverURL(host: String, port: Int) -> URL? {
        guard (1...65535).contains(port) else { return nil }
        let address = host.lowercased()
        let parts = address.split(separator: ".").compactMap { Int($0) }
        let ipv4 = address.split(separator: ".", omittingEmptySubsequences: false).count == 4 && parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1]) && parts.allSatisfy { (0...255).contains($0) }
        let ipv6 = address.hasPrefix("fd7a:115c:a1e0:") && address.allSatisfy { $0.isHexDigit || $0 == ":" }
        let dns = address.hasSuffix(".ts.net") && address.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
        guard ipv4 || ipv6 || dns else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ipv6 ? "[\(address)]" : address
        components.port = port
        components.path = "/"
        guard let url = components.url, url.scheme == "http", url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct PhonePullRequestSheet: View {
    let connection: MacConnection
    let paneId: PaneID
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var preview = false
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        PhoneToolSheet(title: preview ? "Review Pull Request" : "Create Pull Request", connection: connection) {
            Form {
                if preview {
                    Section("Title") { Text(title).textSelection(.enabled) }
                    Section("Description") { Text(details.isEmpty ? "No description" : details).textSelection(.enabled) }
                    Section { Text("Creates a pull request from this tab's branch on the Mac.") }
                } else {
                    TextField("Title", text: $title)
                    Section("Description") { TextEditor(text: $details).frame(minHeight: 160) }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                Button(preview ? "Create Pull Request" : "Preview") {
                    if !preview { preview = true; return }
                    sending = true
                    Task {
                        switch await connection.performPullRequest(.create(title: title, body: details), paneId: paneId) {
                        case .success: dismiss()
                        case .failure(let error): failure = error.message
                        }
                        sending = false
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || connection.status != .online)
                if preview { Button("Edit") { preview = false }.disabled(sending) }
                if sending { ProgressView("Creating…") }
            }
        }
    }
}

private struct PhoneToolSheet<Content: View>: View {
    let title: String
    let connection: MacConnection
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .macColors(connection.snapshot?.theme)
        }
    }
}

private struct PhoneToolError: View {
    let title: String
    let message: String
    var body: some View { ContentUnavailableView(title, systemImage: "exclamationmark.triangle", description: Text(message)) }
}
