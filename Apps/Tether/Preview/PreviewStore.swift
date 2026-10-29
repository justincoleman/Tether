import Foundation
import Observation
import TetherCore
import WebKit

/// Dev servers running in each project folder, found with lsof while the
/// Preview panel is open, and the address picked for each folder.
@MainActor
@Observable
final class PreviewStore {
    /// By folder (project or worktree path, as `DevServerFinder` keys it).
    private(set) var servers: [String: [DevServer]] = [:]
    /// Typed or picked addresses, by folder. Not persisted: a relaunch goes
    /// back to whatever is running.
    private(set) var chosen: [String: URL] = [:]
    private(set) var scannedOnce = false

    /// Every project and worktree folder, so a server in a nested worktree
    /// is credited to the worktree rather than its project.
    @ObservationIgnored var folders: () -> [String] = { [] }

    let browser = PreviewBrowser()

    func servers(in folder: String) -> [DevServer] {
        servers[DevServerFinder.key(for: folder)] ?? []
    }

    func target(for folder: String) -> URL? {
        PreviewTarget.url(chosen: chosen[folder], servers: servers(in: folder))
    }

    func choose(_ url: URL?, for folder: String) {
        chosen[folder] = url
    }

    /// Scans every few seconds until the task is cancelled (the panel closed).
    func watch() async {
        while !Task.isCancelled {
            await scan()
            try? await Task.sleep(for: .seconds(4))
        }
    }

    func scan() async {
        let found = await DevServerFinder.scan(folders: folders())
        if found != servers { servers = found }
        scannedOnce = true
    }
}

/// One WKWebView, shared by every folder: the panel loads whichever address
/// the selected folder points at.
@MainActor
@Observable
final class PreviewBrowser: NSObject, WKNavigationDelegate {
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Why the last load failed, e.g. nothing listening on the port.
    private(set) var failure: String?

    @ObservationIgnored let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        // Each launch starts clean, so a dev server's stale service worker
        // or cache from yesterday doesn't hide today's change.
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
    }

    /// Loads `target` unless it is already showing.
    func show(_ target: URL?) {
        guard let target else {
            if url != nil {
                webView.loadHTMLString("", baseURL: nil)
                url = nil
                failure = nil
            }
            return
        }
        guard target != requested else { return }
        load(target)
    }

    @ObservationIgnored private var requested: URL?

    func load(_ target: URL) {
        requested = target
        failure = nil
        webView.load(URLRequest(url: target))
    }

    func reload() {
        failure = nil
        if webView.url == nil, let requested {
            webView.load(URLRequest(url: requested))
        } else {
            webView.reloadFromOrigin()
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    private func sync() {
        url = webView.url ?? requested
        title = webView.title ?? ""
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        fail(error)
    }

    private func fail(_ error: any Error) {
        sync()
        let nsError = error as NSError
        // A new load replacing this one isn't a failure worth showing.
        guard nsError.code != NSURLErrorCancelled else { return }
        failure = nsError.localizedDescription
    }
}
