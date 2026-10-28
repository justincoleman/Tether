import Foundation
import TetherProtocol

/// A Claude Code session found on disk, for the History popover.
public struct PastSession: Hashable, Sendable, Identifiable {
    public var id: SessionID
    /// `/rename` title, else Claude Code's generated title.
    public var title: String?
    /// The first thing you typed.
    public var firstPrompt: String?
    /// Folder the session ran in; `claude --resume` must run there too.
    public var cwd: String?
    public var branch: String?
    public var lastActivity: Date

    public init(id: SessionID, title: String?, firstPrompt: String?, cwd: String?,
                branch: String?, lastActivity: Date) {
        self.id = id
        self.title = title
        self.firstPrompt = firstPrompt
        self.cwd = cwd
        self.branch = branch
        self.lastActivity = lastActivity
    }

    /// The bold line in the list.
    public var displayTitle: String { title ?? firstPrompt ?? id }

    /// Every word of `query` appears in the title or the first prompt.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [title, firstPrompt].compactMap { $0 }.joined(separator: "\n").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// Lists past sessions from `~/.claude/projects`. Reads only the head and
/// tail of each transcript, so long sessions stay cheap. See TRANSCRIPT.md
/// ("Session history") for the records used.
public enum SessionHistory {
    static let headBytes = 128 * 1024
    static let tailBytes = 64 * 1024

    /// Claude Code's folder name for a working directory: every character
    /// other than a letter or digit becomes `-`.
    public static func encodedDirectoryName(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Sessions that ran in any of `folders`, newest first.
    public static func list(folders: [String],
                            projectsDirectory: URL = TranscriptLocator.defaultProjectsDirectory,
                            limit: Int = 100) -> [PastSession] {
        let fm = FileManager.default
        var files: [(url: URL, modified: Date)] = []
        for dir in directories(for: folders, in: projectsDirectory) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") && !name.hasPrefix("agent-") {
                let url = dir.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                files.append((url, modified))
            }
        }
        files.sort { $0.modified > $1.modified }
        var sessions: [PastSession] = []
        for file in files where sessions.count < limit {
            let id = String(file.url.deletingPathExtension().lastPathComponent)
            guard let (head, tail) = readEnds(of: file.url),
                  let session = summarize(head: head, tail: tail, sessionId: id, modified: file.modified)
            else { continue }
            sessions.append(session)
        }
        return sessions
    }

    /// The encoded folder for each path when it exists. Claude Code shortens
    /// very long names, so otherwise each folder's first transcript is
    /// checked for a matching `cwd`.
    static func directories(for folders: [String], in projects: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        var missing: Set<String> = []
        for folder in Set(folders) {
            let dir = projects.appendingPathComponent(encodedDirectoryName(folder))
            if fm.fileExists(atPath: dir.path) { found.append(dir) } else { missing.insert(folder) }
        }
        guard !missing.isEmpty, let dirs = try? fm.contentsOfDirectory(atPath: projects.path) else { return found }
        for name in dirs {
            let dir = projects.appendingPathComponent(name)
            guard !found.contains(dir),
                  let first = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix(".jsonl") }),
                  let (head, _) = readEnds(of: dir.appendingPathComponent(first)),
                  let cwd = firstCwd(in: head), missing.contains(cwd) else { continue }
            found.append(dir)
        }
        return found
    }

    /// The first `headBytes` and, for a longer file, the last `tailBytes`.
    static func readEnds(of url: URL) -> (head: Data, tail: Data)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headBytes) else { return nil }
        guard let size = try? handle.seekToEnd(), size > UInt64(headBytes) else { return (head, Data()) }
        let start = max(UInt64(headBytes), size - UInt64(tailBytes))
        guard (try? handle.seek(toOffset: start)) != nil,
              let tail = try? handle.read(upToCount: tailBytes) else { return (head, Data()) }
        return (head, tail)
    }

    /// Title, first prompt, branch and folder from a transcript's ends. Nil
    /// for a session with nothing typed in it. Cut-off lines at the edges of
    /// a chunk don't parse and are skipped.
    public static func summarize(head: Data, tail: Data, sessionId: SessionID, modified: Date) -> PastSession? {
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String?
        var cwd: String?
        var branch: String?
        for chunk in [head, tail] {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
                guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                switch record["type"] as? String ?? "" {
                case "custom-title":
                    customTitle = nonEmpty(record["customTitle"] as? String) ?? customTitle
                case "ai-title":
                    aiTitle = nonEmpty(record["aiTitle"] as? String) ?? aiTitle
                case "summary":
                    summary = nonEmpty(record["summary"] as? String) ?? summary
                case "user":
                    if record["isSidechain"] as? Bool == true { continue }
                    if let value = nonEmpty(record["cwd"] as? String), cwd == nil { cwd = value }
                    if let value = nonEmpty(record["gitBranch"] as? String) { branch = value }
                    if firstPrompt == nil, record["isMeta"] as? Bool != true,
                       let message = record["message"] as? [String: Any] {
                        firstPrompt = promptText(message["content"])
                    }
                default:
                    continue
                }
            }
        }
        guard let firstPrompt else { return nil }
        return PastSession(id: sessionId, title: customTitle ?? aiTitle ?? summary, firstPrompt: firstPrompt,
                           cwd: cwd, branch: branch, lastActivity: modified)
    }

    static func firstCwd(in data: Data) -> String? {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               let cwd = nonEmpty(record["cwd"] as? String) {
                return cwd
            }
        }
        return nil
    }

    /// What you typed, on one line. Slash commands read as `/name args`;
    /// tool results and injected text (`<local-command-stdout>`, reminders)
    /// are not prompts.
    static func promptText(_ content: Any?) -> String? {
        var raw: String?
        if let string = content as? String {
            raw = string
        } else if let blocks = content as? [[String: Any]] {
            raw = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("<") {
            guard let name = between(text, "<command-name>", "</command-name>") else { return nil }
            let args = between(text, "<command-args>", "</command-args>") ?? ""
            text = args.isEmpty ? name : "\(name) \(args)"
        }
        if text.hasPrefix("[Request interrupted") { return nil }
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(oneLine.prefix(300))
    }

    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
