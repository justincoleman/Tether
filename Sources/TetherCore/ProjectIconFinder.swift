import Foundation

/// Looks in a project folder for an image that can stand in for its icon.
///
/// Order: an explicit `.tether/icon.png`, then an Xcode app icon (the
/// largest default-appearance image of an `AppIcon.appiconset`), then the
/// usual web icon locations. Nil means "use the letter tile".
public enum ProjectIconFinder {
    /// Folders never worth walking into.
    static let skipped: Set<String> = [
        ".git", "node_modules", "Pods", "build", ".build", "DerivedData", "Carthage", "vendor",
        "dist", "target", ".venv", "venv", "__pycache__", ".next", ".gradle", ".swiftpm",
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "icns", "ico"]
    static let maxDepth = 6
    static let maxEntries = 20_000

    static let explicit = [".tether/icon.png", ".tether/icon.jpg", ".tether/icon.jpeg"]
    static let web = [
        "icon.png", "logo.png", "favicon.png", "favicon.ico",
        "public/icon.png", "public/logo.png", "public/apple-touch-icon.png", "public/favicon.png", "public/favicon.ico",
        "static/icon.png", "static/logo.png", "static/favicon.png",
        "assets/icon.png", "assets/logo.png", "images/icon.png", "images/logo.png",
        "app/icon.png", "src/app/icon.png", "docs/icon.png", "docs/logo.png",
    ]

    public static func find(in root: String, fileManager fm: FileManager = .default) -> String? {
        for rel in explicit where fm.fileExists(atPath: root + "/" + rel) { return root + "/" + rel }
        if let xcode = xcodeIcon(in: root, fileManager: fm) { return xcode }
        for rel in web where fm.fileExists(atPath: root + "/" + rel) { return root + "/" + rel }
        return nil
    }

    // MARK: Xcode

    static func xcodeIcon(in root: String, fileManager fm: FileManager) -> String? {
        for set in appIconSets(in: root, fileManager: fm) {
            if let image = largestImage(inAppIconSet: set, fileManager: fm) { return image }
        }
        return nil
    }

    /// `.appiconset` folders, shallowest and best-named first.
    static func appIconSets(in root: String, fileManager fm: FileManager) -> [String] {
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: root),
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > maxEntries { break }
            if walker.level > maxDepth || skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if url.pathExtension == "appiconset" {
                found.append(url.path)
                walker.skipDescendants()
            }
        }
        func rank(_ path: String) -> (Int, Int, String) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let namePenalty = name == "AppIcon" ? 0 : name.hasPrefix("AppIcon") ? 1 : 2
            return (namePenalty, path.split(separator: "/").count, path)
        }
        return found.sorted { rank($0) < rank($1) }
    }

    /// The biggest default-appearance image listed in the set's Contents.json.
    static func largestImage(inAppIconSet set: String, fileManager fm: FileManager) -> String? {
        guard let data = fm.contents(atPath: set + "/Contents.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]] else { return nil }
        var best: (pixels: Double, path: String)?
        for image in images {
            // Dark and tinted variants would look wrong as a plain tile.
            guard image["appearances"] == nil,
                  let file = image["filename"] as? String,
                  imageExtensions.contains((file as NSString).pathExtension.lowercased()),
                  fm.fileExists(atPath: set + "/" + file) else { continue }
            let px = pixels(size: image["size"] as? String, scale: image["scale"] as? String)
            if best == nil || px > best!.pixels { best = (px, set + "/" + file) }
        }
        return best?.path
    }

    /// "60x60" at "3x" is 180 px; a missing scale counts as 1x.
    static func pixels(size: String?, scale: String?) -> Double {
        let side = size?.split(separator: "x").first.flatMap { Double($0) } ?? 0
        let factor = scale.flatMap { Double($0.replacingOccurrences(of: "x", with: "")) } ?? 1
        return side * factor
    }
}
