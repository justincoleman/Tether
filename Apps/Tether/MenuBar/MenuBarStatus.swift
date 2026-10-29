import AppKit
import SwiftUI
import TetherCore
import TetherProtocol

/// The menu bar icon, with the number of Claude tabs waiting on you.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.claudeTabs.filter { model.paneStates[$0.pane.id] == .needsInput && !$0.pane.hasExited }.count
        HStack(spacing: 3) {
            Image("TetherMenuBar")
            if waiting > 0 {
                Text("\(waiting)").monospacedDigit()
            }
        }
        .accessibilityLabel(waiting > 0 ? "Tether, \(waiting) waiting on you" : "Tether")
    }
}

/// Every Claude tab and what it's doing. Picking one brings the window
/// forward on that tab.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tabs = model.claudeTabs
        if tabs.isEmpty {
            Text("No Claude tabs")
        }
        ForEach(tabs, id: \.pane.id) { tab in
            Button {
                bringForward()
                model.select(pane: tab.pane)
            } label: {
                Label(title(tab), systemImage: symbol(tab.pane))
            }
        }
        Divider()
        Button("Overview") {
            bringForward()
            model.closeOverlays()
            model.showOverview = true
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Tether") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func title(_ tab: AppModel.ClaudeTab) -> String {
        let name = tab.showTitle ? "\(tab.project.name) · \(tab.pane.title)" : tab.project.name
        return "\(name) — \(status(tab.pane))"
    }

    private func status(_ pane: TerminalPane) -> String {
        if pane.hasExited { return "Not running" }
        switch model.paneStates[pane.id] ?? .idle {
        case .needsInput:
            switch model.paneAttention[pane.id] {
            case .permission: return "Wants permission"
            case .question: return "Asked a question"
            case .dialog: return "Waiting on a dialog"
            case nil: return "Needs you"
            }
        case .working:
            guard let started = model.turnStartedAt[pane.id] else { return "Working" }
            return "Working, \(ElapsedTime.short(since: started))"
        case .done: return "Finished"
        case .error: return "Stopped with an error"
        case .idle, .detached: return "Idle"
        }
    }

    private func symbol(_ pane: TerminalPane) -> String {
        if pane.hasExited { return "moon.zzz" }
        switch model.paneStates[pane.id] ?? .idle {
        case .needsInput: return "exclamationmark.bubble.fill"
        case .working: return "sparkles"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .idle, .detached: return "circle.dotted"
        }
    }

    /// The menu bar item works while another app is frontmost, so the
    /// window has to come forward with the selection.
    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { window in
            let id = window.identifier?.rawValue ?? ""
            return window.canBecomeMain && !id.contains("whats-new") && !id.contains("remote-macs") && !id.contains("Settings")
        }
        if let main {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        }
    }
}
