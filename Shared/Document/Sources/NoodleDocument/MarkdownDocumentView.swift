import SwiftUI

/// A Markdown document laid out to read, scrolling, with its text selectable.
public struct MarkdownDocumentView: View {
    let document: MarkdownDocument

    public init(_ document: MarkdownDocument) { self.document = document }

    public var body: some View {
        ScrollView {
            MarkdownDocumentContent(document)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The document's blocks one after another, at most a comfortable line long; `MarkdownDocumentView` scrolls it.
public struct MarkdownDocumentContent: View {
    let document: MarkdownDocument

    public init(_ document: MarkdownDocument) { self.document = document }

    #if os(macOS)
    static let bodySize: CGFloat = 14
    #else
    static let bodySize: CGFloat = 16
    #endif

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                view(for: block).padding(.top, index == 0 ? 0 : Self.space(before: block, after: document.blocks[index - 1]))
            }
        }
        .font(.system(size: Self.bodySize))
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: 860, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(.system(size: Self.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .listItem(let item):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if let task = item.task {
                        Image(systemName: task == .done ? "checkmark.square" : "square")
                            .accessibilityLabel(task == .done ? "Done" : "To do")
                    } else {
                        Text(item.marker)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
                Text(item.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(item.depth - 1) * 22)
        case .quote(let text):
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Capsule().fill(.secondary.opacity(0.5)).frame(width: 3) }
        case .code(_, let text):
            ScrollView(.horizontal) {
                Text(text).font(.system(size: Self.bodySize - 1.5, design: .monospaced)).lineSpacing(2)
                    .fixedSize().padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// Items of one list sit closer together than the blocks around them, and a heading further from what it follows.
    static func space(before block: MarkdownDocument.Block, after previous: MarkdownDocument.Block) -> CGFloat {
        if case .heading = block { return 22 }
        if case .listItem = block, case .listItem = previous { return 5 }
        return 12
    }

    static func headingSize(_ level: Int, body: CGFloat = bodySize) -> CGFloat {
        switch level {
        case 1: body + 12
        case 2: body + 6
        case 3: body + 3
        default: body + 1
        }
    }
}

/// A table with its header shaded and a line between rows; long cells wrap.
struct MarkdownTableView: View {
    let table: MarkdownDocument.Table

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { cells(table.header).fontWeight(.semibold) }
                .background(.primary.opacity(0.06))
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow { cells(row) }
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15)) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cells(_ cells: [AttributedString]) -> some View {
        ForEach(Array(cells.enumerated()), id: \.offset) { column, text in
            let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
            Text(text)
                .multilineTextAlignment(alignment.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: alignment.frame)
        }
    }
}

private extension MarkdownDocument.Table.Alignment {
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
