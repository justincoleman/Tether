import Foundation

/// An sRGB color with components in 0...1.
public struct RGB: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// `#RRGGBB` or `RRGGBB`. Ghostty's named X11 colors are not supported.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// `#rrggbb`.
    public var hexString: String {
        func byte(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// Linear blend: `t == 0` is self, `t == 1` is `other`.
    public func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// The colors a Ghostty config sets, with Ghostty's defaults for the rest.
public struct TerminalColors: Sendable, Equatable {
    public var background = RGB(hex: "282c34")!
    public var foreground = RGB(hex: "ffffff")!
    /// ANSI palette entries the config sets explicitly, by index.
    public var palette: [Int: RGB] = [:]

    public init() {}

    /// Reads `background`, `foreground` and `palette = N=#rrggbb` lines. Later
    /// lines win, as in Ghostty. Pass the config after themes are inlined.
    public static func parse(_ config: String) -> TerminalColors {
        var colors = TerminalColors()
        for raw in config.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": if let c = RGB(hex: value) { colors.background = c }
            case "foreground": if let c = RGB(hex: value) { colors.foreground = c }
            case "palette":
                guard let peq = value.firstIndex(of: "="),
                      let index = Int(value[..<peq].trimmingCharacters(in: .whitespaces)),
                      (0...255).contains(index),
                      let c = RGB(hex: String(value[value.index(after: peq)...]))
                else { continue }
                colors.palette[index] = c
            default: continue
            }
        }
        return colors
    }

    /// Fallbacks for ANSI 1-6 when a config leaves them unset.
    static let defaultANSI: [Int: RGB] = [
        1: RGB(hex: "e06c75")!, 2: RGB(hex: "98c379")!, 3: RGB(hex: "e5c07b")!,
        4: RGB(hex: "61afef")!, 5: RGB(hex: "c678dd")!, 6: RGB(hex: "56b6c2")!,
    ]

    public func ansi(_ index: Int) -> RGB {
        palette[index] ?? Self.defaultANSI[index] ?? foreground
    }
}

/// App chrome colors derived from the terminal theme, so the window, sidebar
/// and panels read as one surface with the terminal.
public struct ChromePalette: Sendable, Equatable {
    public var isDark: Bool
    /// Window, sidebar and inspector.
    public var window: RGB
    /// Cards: the terminal, diff viewer. Equal to the terminal background.
    public var surface: RGB
    /// Selected tab or row, controls.
    public var elevated: RGB
    /// Hover.
    public var hover: RGB
    public var border: RGB
    public var text: RGB
    public var secondaryText: RGB
    public var accent: RGB
    public var red: RGB
    public var green: RGB
    public var blue: RGB
    /// Fills for project avatars.
    public var avatars: [RGB]

    public init(terminal t: TerminalColors) {
        let bg = t.background, fg = t.foreground
        isDark = bg.luminance < 0.4
        surface = bg
        // The chrome sits a step away from the terminal: lighter on dark themes,
        // darker on light ones.
        window = isDark ? bg.mixed(with: fg, 0.05) : bg.mixed(with: RGB(0, 0, 0), 0.05)
        hover = window.mixed(with: fg, 0.06)
        elevated = window.mixed(with: fg, 0.12)
        border = window.mixed(with: fg, 0.16)
        text = fg
        secondaryText = fg.mixed(with: bg, 0.4)
        red = t.ansi(1)
        green = t.ansi(2)
        blue = t.ansi(4)
        accent = blue
        avatars = [1, 2, 3, 4, 5, 6].map(t.ansi)
    }

    /// Stable across launches (unlike `hashValue`), so a project keeps its color.
    public static func avatarIndex(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(count))
    }
}
