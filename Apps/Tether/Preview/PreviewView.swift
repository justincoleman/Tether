import AppKit
import SwiftUI
import TetherCore
import WebKit

/// The Preview panel: the dev server running in the selected folder, in a
/// browser, found by port without any setup.
struct PreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var address = ""
    @FocusState private var editingAddress: Bool

    var body: some View {
        let preview = model.preview
        let browser = preview.browser
        let folder = model.selectedWorktreePath
        let servers = folder.map(preview.servers(in:)) ?? []
        let target = folder.flatMap(preview.target(for:))
        VStack(spacing: 0) {
            toolbar(folder: folder, servers: servers)
            Divider()
            ZStack {
                PreviewWebView(webView: browser.webView)
                    .opacity(target == nil || browser.failure != nil ? 0 : 1)
                if folder == nil {
                    ContentUnavailableView("No project selected", systemImage: "folder")
                } else if target == nil {
                    if preview.scannedOnce {
                        ContentUnavailableView {
                            Label("No dev server running", systemImage: "globe")
                        } description: {
                            Text("Start one in a terminal or shortcut tab in this folder and it shows up here. You can also type an address or port above.")
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if let failure = browser.failure {
                    ContentUnavailableView {
                        Label("Can't load \(target?.host(percentEncoded: false) ?? "")\(target?.port.map { ":\($0)" } ?? "")",
                              systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try Again") { browser.reload() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await preview.watch() }
        .onAppear { browser.show(target) }
        .onChange(of: target) { browser.show(target) }
        .onChange(of: servers) {
            // The server came back (or started): retry a failed load.
            if browser.failure != nil, !servers.isEmpty { browser.reload() }
        }
        .onChange(of: browser.url, initial: true) {
            if !editingAddress { address = browser.url?.absoluteString ?? target?.absoluteString ?? "" }
        }
    }

    private func toolbar(folder: String?, servers: [DevServer]) -> some View {
        let browser = model.preview.browser
        return HStack(spacing: 2) {
            ChromeButton(systemImage: "chevron.left", help: "Back") { browser.goBack() }
                .disabled(!browser.canGoBack)
            ChromeButton(systemImage: "chevron.right", help: "Forward") { browser.goForward() }
                .disabled(!browser.canGoForward)
            ChromeButton(systemImage: browser.isLoading ? "xmark" : "arrow.clockwise",
                         help: browser.isLoading ? "Stop" : "Reload") {
                if browser.isLoading { browser.webView.stopLoading() } else { browser.reload() }
            }
            TextField("Address or port", text: $address)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.hover, in: RoundedRectangle(cornerRadius: 6))
                .focused($editingAddress)
                .onSubmit { go(folder: folder) }
                .disabled(folder == nil)
            serverMenu(folder: folder, servers: servers)
            ChromeButton(systemImage: "safari", help: "Open in Browser") {
                if let url = browser.url ?? folder.flatMap(model.preview.target(for:)) {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(folder.flatMap(model.preview.target(for:)) == nil)
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
    }

    private func serverMenu(folder: String?, servers: [DevServer]) -> some View {
        Menu {
            if servers.isEmpty {
                Text("No servers found in this folder")
            }
            ForEach(servers) { server in
                Button("localhost:\(server.port) · \(server.command)") {
                    guard let folder else { return }
                    model.preview.choose(server.url, for: folder)
                }
            }
            if let folder, model.preview.chosen[folder] != nil {
                Divider()
                Button("Pick Automatically") { model.preview.choose(nil, for: folder) }
            }
        } label: {
            Image(systemName: "network")
                .foregroundStyle(servers.isEmpty ? theme.secondaryText : theme.green)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help(servers.isEmpty ? "No dev servers running" : "\(servers.count) dev server\(servers.count == 1 ? "" : "s") running")
        .disabled(folder == nil)
    }

    private func go(folder: String?) {
        editingAddress = false
        guard let folder, let url = PreviewTarget.parse(address) else {
            address = model.preview.browser.url?.absoluteString ?? ""
            return
        }
        model.preview.choose(url, for: folder)
        // Same address again: load it anyway, like pressing Return in a browser.
        model.preview.browser.load(url)
    }
}

private struct PreviewWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
