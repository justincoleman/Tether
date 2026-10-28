import Testing
@testable import TetherCore

@Suite struct ChromePaletteTests {
    @Test func parsesHex() {
        #expect(RGB(hex: "#ff0000") == RGB(1, 0, 0))
        #expect(RGB(hex: "00ff00") == RGB(0, 1, 0))
        #expect(RGB(hex: "red") == nil)
        #expect(RGB(hex: "#fff") == nil)
    }

    @Test func readsColorsLastWins() {
        let c = TerminalColors.parse("""
        # background = 000000
        background = 303446
        foreground = c6d0f5
        palette = 4=#8caaee
        palette=1 = e78284
        background = 232634
        palette = 300=#ffffff
        """)
        #expect(c.background == RGB(hex: "232634"))
        #expect(c.foreground == RGB(hex: "c6d0f5"))
        #expect(c.palette[4] == RGB(hex: "8caaee"))
        #expect(c.palette[1] == RGB(hex: "e78284"))
        #expect(c.palette.count == 2)
    }

    @Test func defaultsMatchGhostty() {
        let c = TerminalColors.parse("font-size = 13")
        #expect(c.background == RGB(hex: "282c34"))
        #expect(c.foreground == RGB(hex: "ffffff"))
        #expect(c.ansi(4) == RGB(hex: "61afef"))
    }

    @Test func darkThemeLightensChrome() {
        let p = ChromePalette(terminal: TerminalColors.parse("background = 303446\nforeground = c6d0f5\npalette = 4=#8caaee"))
        #expect(p.isDark)
        #expect(p.surface == RGB(hex: "303446"))
        #expect(p.window.luminance > p.surface.luminance)
        #expect(p.accent == RGB(hex: "8caaee"))
        #expect(p.avatars.count == 6)
    }

    @Test func lightThemeDarkensChrome() {
        let p = ChromePalette(terminal: TerminalColors.parse("background = eff1f5\nforeground = 4c4f69"))
        #expect(!p.isDark)
        #expect(p.window.luminance < p.surface.luminance)
    }

    @Test func avatarIndexIsStable() {
        let a = ChromePalette.avatarIndex(for: "Tether", count: 6)
        #expect(a == ChromePalette.avatarIndex(for: "Tether", count: 6))
        #expect((0..<6).contains(a))
        #expect(ChromePalette.avatarIndex(for: "x", count: 0) == 0)
    }
}
