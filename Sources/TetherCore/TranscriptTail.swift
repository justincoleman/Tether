import Foundation

/// Splits appended bytes into complete JSONL lines, holding a partial last line
/// until its newline arrives.
public struct JSONLLineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let i = pending.firstIndex(of: newline) {
            let lineData = pending[pending.startIndex..<i]
            pending = Data(pending[pending.index(after: i)...])
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        return lines
    }
}

/// Reads lines appended to a session transcript since the last read.
/// Phase 2 uses it only to spot interrupts; phase 3 builds the chat mirror on it.
public struct TranscriptTail: Sendable {
    public let path: String
    private var offset: UInt64
    private var buffer = JSONLLineBuffer()
    /// The first read began mid-file, so everything up to its first newline is
    /// the end of a line that started before it.
    private var skipsPartialFirstLine = false
    /// Older records were left out by `init(path:lastBytes:)`.
    public private(set) var skippedEarlier = false

    /// Starts at the current end of the file unless `fromStart` is set.
    public init(path: String, fromStart: Bool = false) {
        self.path = path
        self.offset = fromStart ? 0 : Self.fileSize(path) ?? 0
    }

    /// Starts at most `lastBytes` before the end of the file, so a transcript of
    /// hundreds of megabytes opens with its recent records only.
    public init(path: String, lastBytes: UInt64) {
        self.path = path
        let size = Self.fileSize(path) ?? 0
        if size > lastBytes {
            offset = size - lastBytes
            skipsPartialFirstLine = true
            skippedEarlier = true
        } else {
            offset = 0
        }
    }

    public mutating func readNewLines() -> [String] {
        guard let size = Self.fileSize(path) else { return [] }
        if size < offset { // rewritten or truncated
            offset = 0
            buffer = JSONLLineBuffer()
        }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            var data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            if skipsPartialFirstLine {
                guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
                data = Data(data[data.index(after: newline)...])
                skipsPartialFirstLine = false
            }
            return buffer.append(data)
        } catch {
            return []
        }
    }

    static func fileSize(_ path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        switch attrs[.size] {
        case let n as NSNumber: return n.uint64Value
        case let n as UInt64: return n
        case let n as Int: return UInt64(max(0, n))
        default: return nil
        }
    }
}

/// Facts read from individual transcript records.
public enum TranscriptSignals {
    static let interruptPrefix = "[Request interrupted by user"

    /// The permission mode a transcript record announces, if it is a mode record.
    /// Claude Code writes `{"type":"mode","mode":...}` (older builds
    /// `{"type":"permission-mode","permissionMode":...}`) when the mode changes.
    public static func permissionMode(_ line: String) -> String? {
        guard line.contains("mode"),
              let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let type = record["type"]?.stringValue else { return nil }
        let value: String?
        switch type {
        case "mode": value = record["mode"]?.stringValue
        case "permission-mode": value = record["permissionMode"]?.stringValue
        default: return nil
        }
        guard let value, !value.isEmpty else { return nil }
        return value == "normal" ? "default" : value
    }

    /// True for the user-role record Claude Code writes when the user presses
    /// Esc. Only user records count, so Claude quoting the marker does not.
    public static func isUserInterrupt(_ line: String) -> Bool {
        guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              record["type"]?.stringValue == "user",
              let content = record["message"]?["content"] else { return false }
        switch content {
        case .string(let text):
            return text.hasPrefix(interruptPrefix)
        case .array(let items):
            return items.contains { item in
                item["type"]?.stringValue == "text"
                    && (item["text"]?.stringValue?.hasPrefix(interruptPrefix) ?? false)
            }
        default:
            return false
        }
    }
}
