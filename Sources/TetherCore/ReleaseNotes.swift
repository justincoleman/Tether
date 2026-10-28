import Foundation

/// A dotted version such as `0.2.0`, compared numerically.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ string: String) {
        let pieces = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = pieces.map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.map { $0! }
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// One release as the What's New window shows it. Lives in
/// `Apps/Tether/Resources/ReleaseNotes.json`.
public struct ReleaseNote: Codable, Hashable, Sendable, Identifiable {
    public struct Highlight: Codable, Hashable, Sendable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    public var version: String
    /// `yyyy-MM-dd`.
    public var date: String
    /// One sentence under the version heading.
    public var summary: String
    public var highlights: [Highlight]

    public var id: String { version }

    public init(version: String, date: String, summary: String, highlights: [Highlight]) {
        self.version = version
        self.date = date
        self.summary = summary
        self.highlights = highlights
    }
}

public enum ReleaseNotes {
    /// Newest first. Entries with an unreadable version are dropped.
    public static func parse(_ data: Data) throws -> [ReleaseNote] {
        let notes = try JSONDecoder().decode([ReleaseNote].self, from: data)
        return notes
            .compactMap { note in SemanticVersion(note.version).map { (version: $0, note: note) } }
            .sorted { $0.version > $1.version }
            .map(\.note)
    }

    /// The releases to announce: everything newer than `lastSeen` up to the
    /// running `current` version. A first launch (no `lastSeen`) announces
    /// only the current release. Nothing is announced after a downgrade or
    /// when the running version has no notes yet.
    public static func unseen(_ notes: [ReleaseNote], lastSeen: String?, current: String) -> [ReleaseNote] {
        guard let current = SemanticVersion(current) else { return [] }
        let upToCurrent = notes.filter { SemanticVersion($0.version).map { $0 <= current } ?? false }
        guard let seen = lastSeen.flatMap(SemanticVersion.init) else {
            return Array(upToCurrent.prefix(1))
        }
        return upToCurrent.filter { SemanticVersion($0.version).map { $0 > seen } ?? false }
    }
}
