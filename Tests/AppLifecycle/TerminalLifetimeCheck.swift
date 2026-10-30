import AppKit
import Observation
import SwiftUI

private struct Project: Identifiable {
    let id: Int
    var panes: [Int]
}

@MainActor @Observable private final class Workspace {
    var projects = [Project(id: 1, panes: [11]), Project(id: 2, panes: [21])]
    var selected: Int? = 1
    var showOverview = false
    var showRemote = false
    var active: Int? { showOverview || showRemote ? nil : selected }
}

@MainActor private final class Recorder {
    var created: [Int: Int] = [:]
    var removed: [Int: Int] = [:]
    var views: [Int: NSView] = [:]
}

private final class FocusableProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct SurfaceProbe: NSViewRepresentable {
    let pane: Int
    let recorder: Recorder

    final class Coordinator {
        let pane: Int
        let recorder: Recorder
        init(pane: Int, recorder: Recorder) { self.pane = pane; self.recorder = recorder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pane: pane, recorder: recorder) }
    func makeNSView(context: Context) -> NSView {
        let view = FocusableProbeView()
        recorder.created[pane, default: 0] += 1
        recorder.views[pane] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.recorder.removed[coordinator.pane, default: 0] += 1
    }
}

private struct WorkspaceView: View {
    let workspace: Workspace
    let recorder: Recorder

    var body: some View {
        ZStack {
            PersistentTerminalStack(items: workspace.projects, selection: workspace.active) { project, _ in
                ZStack {
                    ForEach(project.panes, id: \.self) { pane in
                        SurfaceProbe(pane: pane, recorder: recorder)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if workspace.showOverview { Text("Overview") }
            if workspace.showRemote { Text("Remote") }
        }
    }
}

@main private enum TerminalLifetimeCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let workspace = Workspace()
            let recorder = Recorder()
            let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 480, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace, recorder: recorder))
            // A real attached, nonzero-size window exercises NSViewRepresentable lifetime.
            window.orderBack(nil)
            var failures: [String] = []
            func check(_ condition: Bool, _ message: String) {
                if !condition { failures.append(message) }
            }
            @MainActor func settle() async {
                try? await Task.sleep(for: .milliseconds(150))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            await settle()
            check(recorder.created[11] == 1 && recorder.created[21] == 1,
                  "Both selected and inactive project surfaces must mount at startup")
            check(recorder.views[21]?.window != nil && (recorder.views[21]?.bounds.width ?? 0) > 0,
                  "Inactive project surface must be attached with nonzero dimensions")
            if let first = recorder.views[11], let other = recorder.views[21] {
                window.makeFirstResponder(first)
                TerminalFocus.resignIfOwned(by: other)
                check(window.firstResponder === first, "Hiding another pane must not steal focus")
                TerminalFocus.resignIfOwned(by: first)
                check(window.firstResponder !== first, "Hidden terminal must release keyboard focus")
            }
            workspace.projects[1].panes.append(22)
            await settle()
            check(recorder.created[22] == 1, "Phone-created pane in inactive project must mount")
            workspace.selected = 2
            await settle()
            workspace.showOverview = true
            await settle()
            workspace.showOverview = false
            workspace.showRemote = true
            await settle()
            workspace.showRemote = false
            workspace.selected = 1
            await settle()
            check([11, 21, 22].allSatisfy { recorder.created[$0] == 1 },
                  "Navigation must not recreate terminal surfaces")
            check(recorder.removed.values.allSatisfy { $0 == 0 },
                  "Navigation must not dismantle terminal surfaces")
            workspace.projects[1].panes.removeAll { $0 == 22 }
            await settle()
            check(recorder.removed[22] == 1, "Closing a pane must dismantle its surface once")
            check(recorder.removed[11, default: 0] == 0 && recorder.removed[21, default: 0] == 0,
                  "Closing one pane must preserve the others")
            for failure in failures { print("FAIL: \(failure)") }
            print(failures.isEmpty ? "PASS: terminal lifetime across project, overview, remote, and pane changes" : "FAILED: \(failures.count) lifecycle checks")
            window.close()
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
