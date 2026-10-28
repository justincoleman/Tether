import Foundation
import GhosttyTerminal

/// Process-wide libghostty controller. Loads the user's Ghostty config so
/// fonts, themes and keybinds match their standalone Ghostty.
@MainActor
enum TerminalHost {
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
        if let path = ghosttyConfigPath {
            return TerminalController(configFilePath: path)
        }
        return TerminalController()
    }()
}
