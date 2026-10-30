import GhosttyKit
import GhosttyTerminal

/// Reads text off a pane's screen, for `PromptSuggestion` only: Tether
/// otherwise never scrapes the terminal (PLAN.md 3.2).
///
/// libghostty-spm reads text for its own selection code but exposes no read
/// for a live pty surface, so the surface handle comes from `TerminalSurface`'s
/// stored `surface` property by reflection. If a package update renames it,
/// reads return nil and no suggestion shows; nothing else depends on this.
@MainActor
enum TerminalScreen {
    /// The bottom `rows` rows of the viewport, one line each, top to bottom.
    static func bottomText(of state: TerminalViewState, rows wanted: Int = 16) -> String? {
        guard let surface = state.surface,
              let stored = Mirror(reflecting: surface).children.first(where: { $0.label == "surface" }),
              let raw = stored.value as? ghostty_surface_t else { return nil }
        let size = ghostty_surface_size(raw)
        let rows = Int(size.rows), columns = Int(size.columns)
        guard rows > 0, columns > 0 else { return nil }
        var lines: [String] = []
        for row in max(0, rows - wanted) ..< rows {
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: 0, y: UInt32(row)),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                              x: UInt32(columns - 1), y: UInt32(row)),
                rectangle: false)
            var out = ghostty_text_s()
            guard ghostty_surface_read_text(raw, selection, &out) else { return nil }
            defer { ghostty_surface_free_text(raw, &out) }
            guard let text = out.text, out.text_len > 0 else {
                lines.append("")
                continue
            }
            let bytes = UnsafeRawBufferPointer(start: text, count: Int(out.text_len))
            lines.append(String(decoding: bytes, as: UTF8.self))
        }
        return lines.joined(separator: "\n")
    }
}
