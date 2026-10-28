import SwiftUI
import TetherCore
import TetherProtocol

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance: AppearanceMode = .terminal
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showChat") private var showChat = false
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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("What's New in Tether") { openWindow(id: "whats-new") }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { model.addProjectRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // Replaces File → Close (⌘W) so it closes the tab, not the window.
            CommandGroup(replacing: .saveItem) {
                Button("New Claude Tab") { model.newClaudeTabInSelectedProject() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Shell Tab") { model.newShellTabInSelectedProject() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Close Tab") { model.requestCloseSelectedPane() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Overview") { model.showOverview = true }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Next Tab") { model.selectAdjacentPane(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.selectAdjacentPane(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
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
                Button(showChat ? "Show Terminal" : "Show Chat") { showChat.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Changes") { model.toggleInspector(.changes) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Files") { model.toggleInspector(.files) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
