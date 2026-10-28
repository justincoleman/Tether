import Foundation
import Testing
@testable import TetherCore

@Suite struct GhosttyConfigTests {
    func themeDir(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "tether-themes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func inlinesNamedThemeWithSpaces() throws {
        let dir = try themeDir(["Catppuccin Frappe": "background = 303446\npalette = 0=#51576d"])
        let r = GhosttyConfig.inlineThemes(
            in: "font-size = 14\ntheme = Catppuccin Frappe\nbackground = 000000",
            isDark: true, themeDirs: [dir])
        #expect(r.warnings.isEmpty)
        #expect(r.contents == "font-size = 14\nbackground = 303446\npalette = 0=#51576d\nbackground = 000000")
    }

    @Test func picksLightOrDarkVariant() throws {
        let dir = try themeDir(["L": "background = ffffff", "D": "background = 000000"])
        let cfg = "theme = light:L,dark:D"
        #expect(GhosttyConfig.inlineThemes(in: cfg, isDark: true, themeDirs: [dir]).contents == "background = 000000")
        #expect(GhosttyConfig.inlineThemes(in: cfg, isDark: false, themeDirs: [dir]).contents == "background = ffffff")
    }

    @Test func missingThemeIsDroppedAndReported() {
        let r = GhosttyConfig.inlineThemes(in: "font-size = 14\ntheme = Nope", isDark: true, themeDirs: [])
        #expect(r.contents == "font-size = 14")
        #expect(r.warnings.count == 1)
    }

    @Test func ignoresCommentedThemeAndQuotedValue() throws {
        let dir = try themeDir(["X": "foreground = fff"])
        let r = GhosttyConfig.inlineThemes(in: "# theme = X\ntheme = \"X\"", isDark: false, themeDirs: [dir])
        #expect(r.contents == "# theme = X\nforeground = fff")
    }

    @Test func dropsOnlyRejectedLines() {
        let r = GhosttyConfig.dropRejected(from: "font-size = 14\nbogus-key = 1\n# note\n\nbackground = 000000") {
            !$0.contains("bogus")
        }
        #expect(r.contents == "font-size = 14\n# note\n\nbackground = 000000")
        #expect(r.warnings == ["ignored unsupported setting: bogus-key = 1"])
    }

    @Test func themeDirectoriesIncludeGhosttyApp() {
        let dirs = GhosttyConfig.themeDirectories(home: "/Users/j")
        #expect(dirs.contains("/Applications/Ghostty.app/Contents/Resources/ghostty/themes"))
        #expect(dirs.first == "/Users/j/.config/ghostty/themes")
    }
}
