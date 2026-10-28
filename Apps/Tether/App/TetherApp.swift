import SwiftUI
import TetherCore
import TetherProtocol

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance: AppearanceMode = .terminal
    @AppStorage("showSidebar") private var showSidebar = true

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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { model.addProjectRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .sidebar) {
                Button(showSidebar ? "Hide Sidebar" : "Show Sidebar") { showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button("Chat") { model.toggleInspector(.chat) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Changes") { model.toggleInspector(.changes) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
