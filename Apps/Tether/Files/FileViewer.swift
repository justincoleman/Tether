import AppKit
import SwiftUI
import TetherCore

/// A read-only look at a file from the Files panel. It covers the terminal
/// area while open, like the diff viewer. Editing is left to your editor.
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let target: OpenFile

    @State private var content: FileContent?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch content {
                case nil:
                    ProgressView().controlSize(.small)
                case .text(let lines, let truncated):
                    TextLines(lines: lines, truncated: truncated)
                case .image(let data):
                    if let image = NSImage(data: data) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).padding(16)
                        }
                    } else {
                        ContentUnavailableView("Can't show this image", systemImage: "photo")
                    }
                case .binary:
                    ContentUnavailableView("Binary file", systemImage: "doc",
                                           description: Text("Open it with its app to see it."))
                case .unreadable(let reason):
                    ContentUnavailableView("Can't open this file", systemImage: "exclamationmark.triangle",
                                           description: Text(reason))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.surface)
        .task(id: target.url) {
            content = nil
            let url = target.url
            content = await Task.detached(priority: .userInitiated) { FileContent.load(url) }.value
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: FileIcon.symbol(for: target.url.lastPathComponent))
                .foregroundStyle(theme.secondaryText)
            VStack(alignment: .leading, spacing: 0) {
                Text(target.url.lastPathComponent).font(.headline)
                Text(target.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button { NSWorkspace.shared.open(target.url) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Open with Default App")
            Button { NSWorkspace.shared.activateFileViewerSelecting([target.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            Button { model.closeFile() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

/// What the viewer shows, read off the main thread.
enum FileContent: Sendable {
    case text(lines: [String], truncated: Bool)
    case image(Data)
    case binary
    case unreadable(String)

    /// Larger files show their start only.
    static let maxBytes = 2 * 1024 * 1024
    static let maxLines = 20_000

    static func load(_ url: URL) -> FileContent {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unreadable("It may have been moved or deleted.")
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            return .unreadable("It couldn't be read.")
        }
        let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns"]
        if imageTypes.contains(url.pathExtension.lowercased()), data.count <= maxBytes {
            return .image(data)
        }
        if data.prefix(8192).contains(0) { return .binary }
        let truncatedBytes = data.count > maxBytes
        let text = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let truncatedLines = lines.count > maxLines
        return .text(lines: Array(lines.prefix(maxLines)), truncated: truncatedBytes || truncatedLines)
    }
}

private struct TextLines: View {
    @Environment(\.theme) private var theme
    let lines: [String]
    let truncated: Bool

    var body: some View {
        let digits = max(3, String(lines.count).count)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(index + 1))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: CGFloat(digits) * 8, alignment: .trailing)
                        Text(line.replacingOccurrences(of: "\t", with: "    "))
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 18, alignment: .leading)
                }
                if truncated {
                    Text("Only the start of this file is shown. Open it with its app to see the rest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(12)
        }
    }
}
