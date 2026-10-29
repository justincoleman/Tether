import Foundation

/// Photos sent from the phone for Claude: checked, saved on the Mac, and
/// referenced by path in the message, since a pty can only carry text.
public enum ImageUpload {
    /// The phone sends JPEGs of at most 2048 px; this leaves room.
    public static let maxBytes = 12 * 1024 * 1024

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case tooLarge
        case notAnImage

        public var description: String {
            switch self {
            case .tooLarge: return "The image is too large."
            case .notAnImage: return "That isn't a JPEG or PNG image."
            }
        }
    }

    /// The file extension for JPEG or PNG data; anything else is refused.
    public static func fileExtension(for data: Data) throws -> String {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        throw Failure.notAnImage
    }

    /// `~/Library/Application Support/Tether/Uploads`.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tether/Uploads", isDirectory: true)
    }

    /// Writes the image under a fresh name and returns its path.
    public static func save(_ data: Data, in directory: URL, now: Date = Date(),
                            prefix: String = "iphone") throws -> String {
        let ext = try fileExtension(for: data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970)
        let url = directory.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString.prefix(8)).\(ext)")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// The same for images pasted into the Mac's chat: one line per image.
    public static func prompt(text: String, imagePaths: [String]) -> String {
        let lines = imagePaths.map { "Image: \($0)" }.joined(separator: "\n")
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if lines.isEmpty { return clean }
        return clean.isEmpty ? lines : "\(clean)\n\n\(lines)"
    }

    /// What gets typed into Claude: the user's text, then the image's path,
    /// which Claude reads with its Read tool.
    public static func prompt(text: String, imagePath: String) -> String {
        let line = "Image from my iPhone: \(imagePath)"
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? line : "\(clean)\n\n\(line)"
    }
}
