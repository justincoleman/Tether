import SwiftUI
import TetherProtocol

/// Renders Claude's markdown replies: headings, lists, tables, code blocks and
/// quotes, with inline formatting inside each. Compiled into both apps.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ text: String) {
        self.blocks = MarkdownBlocks.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownView.inline(text))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph(let text):
            Text(MarkdownView.inline(text))
        case .listItem(let depth, let ordinal, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal ?? "•").foregroundStyle(.secondary).monospacedDigit()
                Text(MarkdownView.inline(text))
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.callout.monospaced()).padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 3)
                Text(MarkdownView.inline(text)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(MarkdownView.inline(c < header.count ? header[c] : "")).bold()
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow(alignment: .top) {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(MarkdownView.inline(c < row.count ? row[c] : ""))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(8)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
