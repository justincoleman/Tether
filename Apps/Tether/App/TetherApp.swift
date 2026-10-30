import SwiftUI
import TetherCore
import TetherProtocol

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance: AppearanceMode = .terminal
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let theme = Theme.current(appearance)
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.theme, theme)
                .tint(theme.accent)
                .foregroundStyle(theme.text)
                .frame(minWidth: 900, minHeight: 600)
                .onChange(of: appearance, initial: true) {
                    NSApp.appearance = theme.nsAppearance
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        Window("What's New", id: "whats-new") {
            WhatsNewView()
                .environment(model)
                .environment(\.theme, theme)
                .tint(theme.accent)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 580, height: 680)
        Window("Remote Macs", id: "remote-macs") {
            RemoteMacsView()
                .environment(model)
                .environment(\.theme, theme)
                .tint(theme.accent)
                .foregroundStyle(theme.text)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("What's New in Tether") { openWindow(id: "whats-new") }
                Button("Check for Updates…") { UpdatePrompt.checkFromMenu(model.updater) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { model.addProjectRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // Replaces File → Close (⌘W) so it closes the tab, not the window.
            CommandGroup(replacing: .saveItem) {
                Button("New Claude Tab") { model.newClaudeTabInSelectedProject() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Codex Tab") { model.newCodexTabInSelectedProject() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("New Shell Tab") { model.newShellTabInSelectedProject() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Close Tab") { model.requestCloseSelectedPane() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                // ⇧⌘D is Changes, so Split Down has no shortcut of its own.
                Button("Split Right") { Task { await model.splitSelectedPane(.horizontal) } }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selectedPaneId == nil)
                Button("Split Down") { Task { await model.splitSelectedPane(.vertical) } }
                    .disabled(model.selectedPaneId == nil)
                Button("Unsplit") { model.unsplitSelectedPane() }
                    .disabled(model.split(containing: model.selectedPaneId) == nil)
            }
            CommandMenu("Go") {
                Button("Overview") { model.showOverview = true }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Next Tab") { model.selectAdjacentPane(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.selectAdjacentPane(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                // Both go to the other half: a split has two.
                Button("Next Split") { model.focusOtherSplitHalf() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model.split(containing: model.selectedPaneId) == nil)
                Button("Previous Split") { model.focusOtherSplitHalf() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.split(containing: model.selectedPaneId) == nil)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Project \(n)") { model.selectProject(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                        .disabled(n > model.projects.count)
                }
            }
            CommandGroup(replacing: .sidebar) {
                Button(showSidebar ? "Hide Sidebar" : "Show Sidebar") { showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button(model.selectedPaneId.map { model.showsChat($0) } == true ? "Show as Terminal" : "Show as Chat") {
                    model.toggleChat()
                }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Changes") { model.toggleInspector(.changes) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Files") { model.toggleInspector(.files) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Preview") { model.toggleInspector(.preview) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environment(model)
        }
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarMenu().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.menu)
    }
}
