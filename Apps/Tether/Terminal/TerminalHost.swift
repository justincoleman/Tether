import Foundation
import GhosttyTerminal

/// Process-wide libghostty controller. Loads the user's Ghostty config so
/// fonts, themes and keybinds match their standalone Ghostty.
@MainActor
enum TerminalHost {
    static let controller: TerminalController = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config").path
        if FileManager.default.fileExists(atPath: path) {
            return TerminalController(configFilePath: path)
        }
        return TerminalController()
    }()
}
