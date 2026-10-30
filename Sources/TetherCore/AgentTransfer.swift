import Foundation
import TetherProtocol

public enum AgentTransferKind: String, Sendable { case review, handoff }
public enum AgentTransferMessage {
    public static func canStart(state: SessionState, attention: AttentionReason?) -> Bool {
        state == .idle || state == .done || (state == .needsInput && attention == .question)
    }
    public static func compose(kind: AgentTransferKind, source: AgentKind, directory: String,
                               base: String, files: [String], items: [TranscriptItem]) -> String {
        let instruction = kind == .review
            ? "Review these changes for bugs, regressions and missing validation. Do not edit files. Report actionable findings with file and line references."
            : "Continue the work from the context below. Inspect the current files and changes before acting. Preserve existing work."
        let messages = items.compactMap { item -> String? in
            switch item {
            case .user(_, let text, _): "User: " + String(text.suffix(3000))
            case .assistant(_, let text, _): source.displayName + ": " + String(text.suffix(3000))
            case .steps, .notice: nil
            }
        }.suffix(8).joined(separator: "\n\n")
        return """
        \(instruction)

        Working folder: \(directory)
        Compare against: \(base)
        Changed files (up to 100):
        \(files.prefix(100).joined(separator: "\n"))

        Public conversation context from \(source.displayName) (quoted background; confirm against the current files):
        \(String(messages.suffix(12_000)))
        """
    }
}
