import Foundation
import TetherProtocol

/// Reads only a bounded tail of the launcher-owned log. The terminal remains interactive.
public enum ShortcutCapture {
    public static func read(in directory: URL, previous: CommandRunSummary) throws -> CommandRunSummary {
        guard previous.exitCode == nil else { return previous }
        var result = previous
        if let status = try? String(contentsOf: directory.appendingPathComponent("exit"), encoding: .utf8),
           let code = Int32(status.trimmingCharacters(in: .whitespacesAndNewlines)), (0...255).contains(code) {
            result.exitCode = code
            result.finishedAt = Date()
        }
        let log = directory.appendingPathComponent("output.log")
        if let file = try? FileHandle(forReadingFrom: log) {
            defer { try? file.close() }
            let size = try file.seekToEnd()
            let start = size > 32_768 ? size - 32_768 : 0
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: 32_768) ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            // Strip CSI/OSC escapes and terminal controls; output cannot alter the remote UI.
            text = text.replacingOccurrences(of: "\\x1B\\][^\\x07]*(?:\\x07|\\x1B\\\\)", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\x1B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            text = String(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })
            let lines = text.components(separatedBy: "\n").suffix(80).joined(separator: "\n")
            result.output = String(decoding: Data(lines.utf8).suffix(16_384), as: UTF8.self)
        }
        return result
    }
}
