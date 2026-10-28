import AppKit
import SwiftUI
import TetherCore

/// Where the app's colors come from. Stored under `appearance` in defaults.
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// The whole window follows the Ghostty theme, like the terminal.
    case terminal
    /// Standard macOS light/dark chrome; only the terminal is themed.
    case system

    var id: Self { self }

    var label: String {
        switch self {
        case .terminal: "Match terminal theme"
        case .system: "Follow system appearance"
        }
    }
}

/// Colors every view draws with. Read it from the environment, never use
/// fixed system colors for chrome, so both appearance modes stay coherent.
struct Theme {
    /// Forced dark (true) or light (false) chrome; nil follows the system.
    var forcedDark: Bool?
    var window: Color
    var surface: Color
    var elevated: Color
    var hover: Color
    var border: Color
    var text: Color
    var secondaryText: Color
    var accent: Color
    var red: Color
    var green: Color
    var blue: Color
    /// Claude's orange, for working sparkles and the user's chat bubbles.
    var claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    var avatars: [Color]
    var avatarText: Color

    static func terminal(_ p: ChromePalette) -> Theme {
        Theme(forcedDark: p.isDark,
              window: Color(p.window), surface: Color(p.surface), elevated: Color(p.elevated),
              hover: Color(p.hover), border: Color(p.border), text: Color(p.text),
              secondaryText: Color(p.secondaryText), accent: Color(p.accent),
              red: Color(p.red), green: Color(p.green), blue: Color(p.blue),
              avatars: p.avatars.map(Color.init), avatarText: Color(p.surface))
    }

    static let system = Theme(
        forcedDark: nil,
        window: Color(nsColor: .windowBackgroundColor),
        surface: Color(nsColor: .textBackgroundColor),
        elevated: Color.primary.opacity(0.10),
        hover: Color.primary.opacity(0.05),
        border: Color(nsColor: .separatorColor),
        text: .primary,
        secondaryText: .secondary,
        accent: .accentColor,
        red: .red, green: .green, blue: .blue,
        avatars: [.red, .orange, .green, .blue, .purple, .teal],
        avatarText: .white)

    @MainActor
    static func current(_ mode: AppearanceMode) -> Theme {
        mode == .terminal ? .terminal(TerminalHost.palette) : .system
    }

    /// Applied to NSApp so menus, alerts and the Settings window match.
    var nsAppearance: NSAppearance? {
        guard let forcedDark else { return nil }
        return NSAppearance(named: forcedDark ? .darkAqua : .aqua)
    }

    func avatar(for name: String) -> Color {
        avatars[ChromePalette.avatarIndex(for: name, count: avatars.count)]
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .system
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

/// A row of pill buttons, used for the inspector switcher.
struct PillPicker<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? theme.text : theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(selected ? theme.elevated : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.hover, in: Capsule())
    }
}

/// A borderless icon button for the window's header rows.
struct ChromeButton: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    var active = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? theme.accent : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(hovering || active ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Invisible drag handle between columns. `sign` is +1 when dragging right
/// grows the column (a left column), -1 for a right column.
struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let sign: Double
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = start ?? width
                        start = origin
                        width = min(max(origin + sign * value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}
