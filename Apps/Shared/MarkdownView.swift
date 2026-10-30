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
    @State private var width: CGFloat = 0

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        let cells: [(text: String, bold: Bool)] =
            (0..<columns).map { (text: $0 < header.count ? header[$0] : "", bold: true) }
            + rows.flatMap { row in
                (0..<columns).map { (text: $0 < row.count ? row[$0] : "", bold: false) }
            }
        // Short columns keep their natural width, long text wraps inside its
        // column, and the table only scrolls sideways when even the narrowest
        // wrapping doesn't fit.
        ScrollView(.horizontal, showsIndicators: false) {
            TableLayout(available: width - 16, columns: columns) {
                ForEach(cells.indices, id: \.self) { index in
                    Text(MarkdownView.inline(cells[index].text))
                        .fontWeight(cells[index].bold ? .bold : .regular)
                }
            }
            .padding(8)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Lays cells out in `columns` columns, row by row. Each column is as wide as
/// its widest cell, or narrower (down to its longest word) when the table
/// would be wider than `available`; row heights follow the wrapped text.
private struct TableLayout: Layout {
    var available: CGFloat
    var columns: Int
    private let spacing: CGFloat = 14
    private let rowSpacing: CGFloat = 8

    private func columnWidths(_ subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        var natural = [CGFloat](repeating: 0, count: columns)
        var minimum = [CGFloat](repeating: 0, count: columns)
        for (index, view) in subviews.enumerated() {
            let column = index % columns
            natural[column] = max(natural[column], view.sizeThatFits(.unspecified).width)
            minimum[column] = max(minimum[column], view.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
        }
        let room = available - spacing * CGFloat(columns - 1)
        if available <= 0 || natural.reduce(0, +) <= room { return natural }
        let floor = minimum.reduce(0, +)
        if floor >= room { return minimum }
        let wanted = zip(natural, minimum).map { $0 - $1 }
        let total = wanted.reduce(0, +)
        let slack = room - floor
        return (0..<columns).map { minimum[$0] + slack * wanted[$0] / total }
    }

    private func rowHeights(_ subviews: Subviews, _ widths: [CGFloat]) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let rowCount = (subviews.count + columns - 1) / columns
        return (0..<rowCount).map { row in
            (0..<columns).compactMap { column -> CGFloat? in
                let index = row * columns + column
                guard index < subviews.count else { return nil }
                return subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(subviews)
        let heights = rowHeights(subviews, widths)
        return CGSize(
            width: widths.reduce(0, +) + spacing * CGFloat(max(columns - 1, 0)),
            height: heights.reduce(0, +) + rowSpacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(subviews)
        let heights = rowHeights(subviews, widths)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                if index < subviews.count {
                    subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                          proposal: ProposedViewSize(width: widths[column], height: height))
                }
                x += widths[column] + spacing
            }
            y += height + rowSpacing
        }
    }
}
