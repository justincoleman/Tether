import Foundation

/// Claude Code's model aliases. Anything else goes through "Other…".
struct ModelPreset: Identifiable {
    let label: String
    let alias: String
    var id: String { alias }

    static let all = [
        ModelPreset(label: "Default", alias: "default"),
        ModelPreset(label: "Fable", alias: "fable"),
        ModelPreset(label: "Opus", alias: "opus"),
        ModelPreset(label: "Sonnet", alias: "sonnet"),
        ModelPreset(label: "Haiku", alias: "haiku"),
        ModelPreset(label: "Opus Plan, Sonnet Code", alias: "opusplan"),
    ]

    /// The family alias in a model id like "claude-opus-5-5". Default and
    /// opusplan can't be told apart from the id, so they never show checked.
    static func matching(_ modelId: String?) -> String? {
        guard let modelId else { return nil }
        return ["fable", "opus", "sonnet", "haiku"].first { modelId.contains($0) }
    }
}
