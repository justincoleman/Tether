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

    /// The system appearance at launch; picks the side of `theme = light:X,dark:Y`.
    /// Read from defaults because NSApp may not exist yet when this first runs.
    private static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The user's config with themes inlined; nil when there is no config.
    private static let prepared: GhosttyConfig.Prepared? = {
        guard let path = ghosttyConfigPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = GhosttyConfig.themeDirectories(
            home: home, resourcesDir: ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"])
        return GhosttyConfig.inlineThemes(in: text, isDark: systemIsDark, themeDirs: dirs)
    }()

    /// Chrome colors derived from the same config the terminal renders with.
    static let palette = ChromePalette(terminal: TerminalColors.parse(prepared?.contents ?? ""))

    static let controller: TerminalController = {
        // An empty theme keeps the wrapper's built-in default from painting
        // over the user's colors, and keeps Ghostty's own defaults (which
        // `palette` assumes) when there is no config.
        guard var prepared = Self.prepared else {
            return TerminalController(configSource: .none, theme: TerminalTheme())
        }
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
