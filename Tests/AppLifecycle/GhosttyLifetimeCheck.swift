import AppKit
import SwiftUI
import Observation
import GhosttyTerminal
import TetherCore
import TetherProtocol

private struct Group: Identifiable { let id: Int; var panes: [TerminalPane] }
@MainActor @Observable private final class Workspace {
    var groups: [Group] = []
    var selection: Int? = 1
}
private struct CheckView: View {
    let workspace: Workspace
    var body: some View {
        PersistentTerminalStack(items: workspace.groups, selection: workspace.selection) { group, active in
            ZStack {
                ForEach(group.panes) { pane in
                    TerminalSurfaceView(context: pane.terminal)
                        .onChange(of: active, initial: true) { _, value in pane.setVisible(value) }
                }
            }
        }
    }
}
@main private enum GhosttyLifetimeCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let controller = TerminalController(configSource: .generated("font-size = 12\n"), theme: TerminalTheme())
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-pty-" + UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            @MainActor func pane(_ name: String) -> TerminalPane {
                let marker = folder.appendingPathComponent(name).path
                let command = "/bin/sh -c 'echo $$ > " + marker + "; while :; do sleep 1; done'"
                return TerminalPane(descriptor: PaneDescriptor(projectId: UUID(), kind: .shell(cwd: "/tmp"), title: name),
                                    launch: TerminalLaunch(command: command, workingDirectory: "/tmp", environment: [:]), controller: controller)
            }
            let a = pane("a"), b = pane("b")
            let state = Workspace(); state.groups = [.init(id: 1, panes: [a]), .init(id: 2, panes: [b])]
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 350), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CheckView(workspace: state))
            window.orderBack(nil)
            @MainActor func settle() async { try? await Task.sleep(for: .milliseconds(250)); window.contentView?.layoutSubtreeIfNeeded() }
            await settle()
            let startupDeadline = Date().addingTimeInterval(5)
            while b.terminal.surface == nil || !FileManager.default.fileExists(atPath: folder.appendingPathComponent("b").path) {
                if Date() >= startupDeadline { break }
                await settle()
            }
            var failures: [String] = []
            func check(_ value: Bool, _ text: String) { if !value { failures.append(text) } }
            let originalA = a.terminal.surface, originalB = b.terminal.surface
            check(originalA != nil && originalB != nil, "Inactive project has no real Ghostty surface")
            check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b").path), "Inactive project process did not start")
            let c = pane("c"); state.groups[1].panes.append(c)
            await settle()
            let backgroundDeadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("c").path) && Date() < backgroundDeadline {
                await settle()
            }
            check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("c").path), "Background-added process did not start")
            state.selection = 2; await settle()
            state.selection = nil; await settle()
            state.selection = 1; await settle()
            check(a.terminal.surface === originalA && b.terminal.surface === originalB, "Navigation recreated real Ghostty surfaces")
            a.focus(); await settle()
            check(window.firstResponder === a.terminal.attachedPlatformView, "Visible terminal could not acquire focus")
            a.focus(); a.setVisible(false)
            await settle()
            check(window.firstResponder !== a.terminal.attachedPlatformView, "Hidden terminal stole deferred keyboard focus")
            for failure in failures { print("FAIL: \(failure)") }
            print(failures.isEmpty ? "PASS: real Ghostty background processes, surface identity, deferred focus" : "FAILED: \(failures.count) real Ghostty checks")
            state.groups = []; await settle()
            window.close()
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
