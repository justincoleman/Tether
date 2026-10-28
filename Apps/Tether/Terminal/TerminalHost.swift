import AppKit
import Foundation
import GhosttyTerminal
import OSLog
import TetherCore

/// Process-wide libghostty controller. Loads the user's Ghostty config so
/// fonts, themes and keybinds match their standalone Ghostty.
@MainActor
enum TerminalHost {
    private static let log = Logger(subsystem: "app.tether", category: "ghostty-config")

    /// Config lines Tether inlined or dropped, for display in settings.
    private(set) static var configWarnings: [String] = []

    /// Ghostty's own lookup order on macOS: XDG path first, then the
    /// Application Support path its macOS app writes.
    static var ghosttyConfigPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".config/ghostty/config").path,
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static let controller: TerminalController = {
        guard let path = ghosttyConfigPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return TerminalController() }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        let dirs = GhosttyConfig.themeDirectories(
            home: home, resourcesDir: ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"])
        var prepared = GhosttyConfig.inlineThemes(in: text, isDark: isDark, themeDirs: dirs)

        // An empty theme keeps the wrapper's built-in default from painting over the user's colors.
        let controller = TerminalController(
            configSource: .generated(prepared.contents), theme: TerminalTheme())
        var warnings = prepared.warnings

        if controller.lastConfigurationIssue != nil {
            // The library rejects the whole file on any diagnostic; find the offending lines.
            let dropped = GhosttyConfig.dropRejected(from: prepared.contents) {
                controller.updateConfigSource(.generated($0))
            }
            prepared.contents = dropped.contents
            warnings += dropped.warnings
            controller.updateConfigSource(.generated(prepared.contents))
        }

        configWarnings = warnings
        for w in warnings { log.warning("\(w, privacy: .public)") }
        return controller
    }()
}
