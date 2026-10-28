import Foundation
import ImageIO
import TetherCore
import UniformTypeIdentifiers

/// Finds a project's icon and shrinks it to a small PNG for the sidebar.
/// Runs off the main actor; only `Data` crosses back.
enum ProjectIconLoader {
    struct Result: Sendable {
        /// Path and modification time of the file used, or nil when there is none.
        var stamp: String?
        var png: Data?
        /// The same file as last time: keep what's already shown.
        var unchanged: Bool
    }

    static let pixels = 128

    static func load(projectPath: String, knownStamp: String?) -> Result {
        guard let path = ProjectIconFinder.find(in: projectPath) else {
            return Result(stamp: nil, png: nil, unchanged: knownStamp == nil)
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 }?.timeIntervalSince1970 ?? 0
        let stamp = "\(path)@\(modified)"
        if stamp == knownStamp { return Result(stamp: stamp, png: nil, unchanged: true) }
        return Result(stamp: stamp, png: thumbnail(path: path), unchanged: false)
    }

    /// ImageIO reads PNG, JPEG, ICNS and ICO alike.
    static func thumbnail(path: String) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}
