import Foundation

/// Prepares the user's Ghostty config for the embedded libghostty.
///
/// The embedded library rejects a whole config file when any line produces a
/// diagnostic, then silently falls back to defaults. One unresolvable
/// `theme` (the embedded build ships no theme directory) or one key the
/// library does not know would otherwise drop the user's font and colors.
public enum GhosttyConfig {
    public struct Prepared: Sendable, Equatable {
        public var contents: String
        /// Human-readable notes about lines that were inlined or dropped.
        public var warnings: [String]
    }

    /// Shortcuts Tether's menus own. Ghostty binds several by default (tabs,
    /// splits), and a focused surface that matches a binding takes the key
    /// before the menu bar sees it, so these are unbound for the embedded
    /// terminal. Appended last, so they win over the user's own config.
    public static let tetherKeys = [
        "super+t", "super+shift+t", "super+w", "super+d", "super+shift+d", "super+shift+e",
        "super+shift+m", "super+shift+n", "super+[", "super+]", "super+shift+[", "super+shift+]",
        "ctrl+super+s",
    ] + (1...9).map { "super+\($0)" }

    /// `contents` with `tetherKeys` unbound at the end.
    public static func reservingTetherKeys(in contents: String) -> String {
        let lines = tetherKeys.map { "keybind = \($0)=unbind" }.joined(separator: "\n")
        return contents.isEmpty ? lines : contents + "\n" + lines
    }

    /// Directories Ghostty searches for theme files, in priority order.
    public static func themeDirectories(home: String, resourcesDir: String? = nil) -> [String] {
        var dirs = [
            "\(home)/.config/ghostty/themes",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/themes",
        ]
        if let resourcesDir { dirs.append("\(resourcesDir)/themes") }
        for app in ["/Applications", "\(home)/Applications"] {
            dirs.append("\(app)/Ghostty.app/Contents/Resources/ghostty/themes")
        }
        return dirs
    }

    /// Replaces each `theme = ...` line with the theme file's contents. The
    /// theme goes where the line was, so later user lines still override it.
    /// An unresolvable theme is removed and reported.
    public static func inlineThemes(
        in text: String, isDark: Bool, themeDirs: [String]
    ) -> Prepared {
        var out: [String] = []
        var warnings: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let value = themeValue(of: line) else { out.append(line); continue }
            let name = pick(value, isDark: isDark)
            if let body = loadTheme(named: name, themeDirs: themeDirs) {
                out.append(body)
            } else {
                warnings.append("theme \"\(name)\" not found; ignored")
            }
        }
        return Prepared(contents: out.joined(separator: "\n"), warnings: warnings)
    }

    /// Removes only the lines `accepts` rejects when tried on their own.
    public static func dropRejected(
        from text: String, accepts: (String) -> Bool
    ) -> Prepared {
        var kept: [String] = []
        var warnings: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || accepts(line) {
                kept.append(line)
            } else {
                warnings.append("ignored unsupported setting: \(trimmed)")
            }
        }
        return Prepared(contents: kept.joined(separator: "\n"), warnings: warnings)
    }

    // MARK: - Helpers

    static func themeValue(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        guard key == "theme" else { return nil }
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// `light:X,dark:Y` picks by appearance; a plain name is used as is.
    static func pick(_ value: String, isDark: Bool) -> String {
        guard value.contains("light:") || value.contains("dark:") else { return value }
        var light: String?, dark: String?
        for part in value.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("light:") { light = String(p.dropFirst(6)) }
            if p.hasPrefix("dark:") { dark = String(p.dropFirst(5)) }
        }
        return (isDark ? dark ?? light : light ?? dark) ?? value
    }

    static func loadTheme(named name: String, themeDirs: [String]) -> String? {
        let paths = name.hasPrefix("/") ? [name] : themeDirs.map { "\($0)/\(name)" }
        for path in paths {
            if let body = try? String(contentsOfFile: path, encoding: .utf8) { return body }
        }
        return nil
    }
}
