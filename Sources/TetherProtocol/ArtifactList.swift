import Foundation

/// A page Claude published with its `Artifact` tool, found in a transcript.
public struct PublishedArtifact: Hashable, Sendable, Identifiable {
    public var url: URL
    /// The page's file name without extension, as words.
    public var title: String
    /// How many times this conversation published to the same URL.
    public var versions: Int
    /// When it was last published or updated.
    public var at: Date

    public var id: String { url.absoluteString }
}

public enum ArtifactList {
    /// Claude Code prints `https://claude.ai/code/artifact/<uuid>`; the plain
    /// `claude.ai/artifact/<id>` form is accepted too.
    static let pattern = #"https://claude\.ai/(?:code/)?artifact/[0-9A-Za-z-]+"#

    /// The artifact link in a tool result, if it has one.
    public static func url(in text: String?) -> URL? {
        guard let text, let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    /// The artifact steps of a transcript, newest first. A step without a link
    /// (still running, or refused) is skipped.
    public static func published(in items: [TranscriptItem]) -> [PublishedArtifact] {
        var byURL: [URL: PublishedArtifact] = [:]
        for case .steps(_, let steps) in items {
            for step in steps where step.name == "Artifact" && !step.isError {
                guard let url = url(in: step.result) ?? url(in: step.summary) else { continue }
                var entry = byURL[url] ?? PublishedArtifact(url: url, title: title(for: step), versions: 0, at: step.at)
                entry.versions += 1
                if step.at >= entry.at {
                    entry.at = step.at
                    // An update has no file name of its own to improve on.
                    if let file = step.file, !file.isEmpty { entry.title = title(for: step) }
                }
                byURL[url] = entry
            }
        }
        return byURL.values.sorted { $0.at > $1.at }
    }

    static func title(for step: ToolStep) -> String {
        guard let file = step.file else { return "Artifact" }
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return name.isEmpty ? "Artifact" : name
    }
}
