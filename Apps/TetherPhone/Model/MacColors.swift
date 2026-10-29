import SwiftUI
import TetherProtocol

/// An sRGB color the phone can blend, like `RGB` in TetherCore (which the
/// phone doesn't link).
private struct HexColor {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init?(_ hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    func mixed(with other: HexColor, _ t: Double) -> HexColor {
        HexColor(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

/// Colors every phone screen draws with, like `Theme` on the Mac: from the
/// Mac's terminal colors while Use Mac's Colors is on, otherwise from the
/// system. Read it from the environment rather than using fixed colors.
struct PhoneTheme {
    /// Forced dark (true) or light (false); nil follows the system.
    var forcedDark: Bool?
    /// Behind everything.
    var background: Color
    /// Cards and list rows.
    var card: Color
    /// Chips, fields and code blocks sitting on a card.
    var elevated: Color
    var border: Color
    var text: Color
    var secondaryText: Color
    var tertiaryText: Color
    var blue: Color = .blue
    var green: Color = .green
    var red: Color = .red
    /// Claude's orange, as on the Mac: working sparkles, your messages, Send.
    var claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    static let system = PhoneTheme(
        forcedDark: nil,
        background: Color(uiColor: .systemGroupedBackground),
        card: Color(uiColor: .secondarySystemGroupedBackground),
        elevated: Color(uiColor: .tertiarySystemFill),
        border: Color(uiColor: .separator),
        text: .primary,
        secondaryText: .secondary,
        tertiaryText: Color(uiColor: .tertiaryLabel))

    /// The same steps as ChromePalette on the Mac: cards sit a step away from
    /// the terminal background, lighter on dark themes and darker on light.
    init?(mac: MacTheme) {
        guard let bg = HexColor(mac.background), let fg = HexColor(mac.foreground) else { return nil }
        let dark = bg.luminance < 0.4
        forcedDark = dark
        let page = dark ? bg : bg.mixed(with: HexColor(0, 0, 0), 0.04)
        let card = dark ? bg.mixed(with: fg, 0.07) : bg
        background = page.color
        self.card = card.color
        elevated = card.mixed(with: fg, 0.09).color
        border = card.mixed(with: fg, 0.14).color
        text = fg.color
        secondaryText = fg.mixed(with: bg, 0.4).color
        tertiaryText = fg.mixed(with: bg, 0.62).color
    }

    init(forcedDark: Bool?, background: Color, card: Color, elevated: Color, border: Color,
         text: Color, secondaryText: Color, tertiaryText: Color) {
        self.forcedDark = forcedDark
        self.background = background
        self.card = card
        self.elevated = elevated
        self.border = border
        self.text = text
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
    }
}

extension EnvironmentValues {
    @Entry var phoneTheme: PhoneTheme = .system
}

/// Dresses a screen in the phone theme: the Mac terminal's colors, light or
/// dark, unless the user turned that off. The same modifiers apply either
/// way, so a screen keeps its state when the colors arrive or go.
private struct MacColors: ViewModifier {
    @AppStorage("useMacColors") private var enabled = true
    let theme: MacTheme?

    func body(content: Content) -> some View {
        let mac = enabled ? theme.flatMap(PhoneTheme.init(mac:)) : nil
        let resolved = mac ?? .system
        content
            .environment(\.phoneTheme, resolved)
            .scrollContentBackground(.hidden)
            .background { resolved.background.ignoresSafeArea() }
            .foregroundStyle(resolved.text)
            .toolbarBackground(mac != nil ? AnyShapeStyle(resolved.background) : AnyShapeStyle(.bar), for: .navigationBar)
            .toolbarBackground(mac != nil ? Visibility.visible : Visibility.automatic, for: .navigationBar)
            .preferredColorScheme(resolved.forcedDark.map { $0 ? ColorScheme.dark : ColorScheme.light })
    }
}

extension View {
    func macColors(_ theme: MacTheme?) -> some View { modifier(MacColors(theme: theme)) }
}
