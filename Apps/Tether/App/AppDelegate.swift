import AppKit

/// Activates the app at launch. Without this, running the binary from a
/// terminal (or launching on a Mac with no one at the keyboard) leaves the
/// window behind whatever is frontmost.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
