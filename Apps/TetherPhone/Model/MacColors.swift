import SwiftUI
import TetherProtocol

extension Color {
    /// `#rrggbb`.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    /// Rough WCAG luminance, to pick light or dark.
    fileprivate var isDarkColor: Bool {
        let c = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ x: CGFloat) -> CGFloat { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) < 0.4
    }
}

/// Dresses a screen in the Mac terminal's background and text colors, light or
/// dark, when the user hasn't turned that off. The same modifiers apply either
/// way, so a screen keeps its state when the colors arrive or go.
private struct MacColors: ViewModifier {
    @AppStorage("useMacColors") private var enabled = true
    let theme: MacTheme?

    func body(content: Content) -> some View {
        let background = theme.flatMap { Color(hex: $0.background) }
        let foreground = theme.flatMap { Color(hex: $0.foreground) }
        let applied = enabled && background != nil && foreground != nil
        content
            .scrollContentBackground(applied ? .hidden : .automatic)
            .background {
                if applied, let background { background.ignoresSafeArea() }
            }
            .foregroundStyle(applied ? AnyShapeStyle(foreground ?? .primary) : AnyShapeStyle(.primary))
            .toolbarBackground(applied ? AnyShapeStyle(background ?? .clear) : AnyShapeStyle(.bar), for: .navigationBar)
            .toolbarBackground(applied ? Visibility.visible : Visibility.automatic, for: .navigationBar)
            .preferredColorScheme(applied ? ((background?.isDarkColor ?? true) ? .dark : .light) : nil)
    }
}

extension View {
    func macColors(_ theme: MacTheme?) -> some View { modifier(MacColors(theme: theme)) }
}
