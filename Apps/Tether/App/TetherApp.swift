import SwiftUI
import TetherCore
import TetherProtocol

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { model.addProjectRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
