#if os(macOS)
import AppKit

/// A Markdown document as one attributed string for an AppKit text view, so a selection runs across its headings,
/// paragraphs, lists, quotes, code and tables alike. Tables, code boxes and quote bars are text blocks, which only
/// TextKit 1 lays out.
public enum MarkdownText {
    public static func attributedString(_ document: MarkdownDocument, size: CGFloat = 14) -> NSAttributedString {
        Builder(size: size).build(document.blocks)
    }

    private struct Builder {
        let size: CGFloat
        let lineSpacing: CGFloat = 3

        func build(_ blocks: [MarkdownDocument.Block]) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for (index, block) in blocks.enumerated() {
                let before = index == 0 ? 0 : MarkdownDocumentContent.space(before: block, after: blocks[index - 1])
                switch block {
                case .heading(let level, let text):
                    let font = NSFont.systemFont(ofSize: MarkdownDocumentContent.headingSize(level, body: size),
                                                 weight: level <= 2 ? .bold : .semibold)
                    result.append(paragraph(inline(text, font: font), style: style(before: before)))
                case .paragraph(let text):
                    result.append(paragraph(inline(text), style: style(before: before)))
                case .listItem(let item):
                    result.append(listItem(item, before: before))
                case .quote(let text):
                    let bar = NSTextBlock()
                    bar.setContentWidth(100, type: .percentageValueType)
                    bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                    bar.setBorderColor(NSColor.secondaryLabelColor.withAlphaComponent(0.5), for: .minX)
                    bar.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                    bar.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
                    result.append(paragraph(inline(text, color: .secondaryLabelColor), style: style(in: bar)))
                case .code(_, let code):
                    let box = NSTextBlock()
                    box.setContentWidth(100, type: .percentageValueType)
                    box.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
                    box.setWidth(12, type: .absoluteValueType, for: .padding)
                    box.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
                    let body = NSAttributedString(string: code, attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular), .foregroundColor: NSColor.labelColor,
                    ])
                    let style = style(in: box, lineSpacing: 2)
                    style.lineBreakMode = .byCharWrapping
                    result.append(paragraph(body, style: style))
                case .table(let table):
                    result.append(self.table(table, before: before))
                case .rule:
                    let line = NSTextBlock()
                    line.setContentWidth(100, type: .percentageValueType)
                    line.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    line.setBorderColor(.separatorColor, for: .maxY)
                    line.setWidth(before + 4, type: .absoluteValueType, for: .margin, edge: .minY)
                    line.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                    let body = NSAttributedString(string: "\u{00A0}", attributes: [.font: NSFont.systemFont(ofSize: 2)])
                    result.append(paragraph(body, style: style(in: line, lineSpacing: 0)))
                }
            }
            // No break after the last paragraph, which would add an empty line under it.
            if result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
            return result
        }

        /// The marker right-aligned in its column and wrapped lines hanging under the text, not the marker; a later
        /// paragraph of the same item lines up with its text.
        private func listItem(_ item: MarkdownDocument.ListItem, before: CGFloat) -> NSAttributedString {
            let lead = CGFloat(item.depth - 1) * 22, marker = size * 1.5, gap = size * 0.45
            let style = style(before: before)
            style.tabStops = [NSTextTab(textAlignment: .right, location: lead + marker),
                              NSTextTab(textAlignment: .left, location: lead + marker + gap)]
            style.headIndent = lead + marker + gap
            let symbol: String
            switch item.task {
            case .done: symbol = "☑"
            case .open: symbol = "☐"
            case nil: symbol = item.marker
            }
            let line = NSMutableAttributedString(string: "\t", attributes: [.font: NSFont.systemFont(ofSize: size)])
            line.append(NSAttributedString(string: symbol, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            line.append(NSAttributedString(string: "\t", attributes: [.font: NSFont.systemFont(ofSize: size)]))
            line.append(inline(item.text))
            return paragraph(line, style: style)
        }

        /// A native text table as wide as the text, its header shaded and a hairline around every cell.
        private func table(_ table: MarkdownDocument.Table, before: CGFloat) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let grid = NSTextTable()
            grid.numberOfColumns = max(1, table.header.count)
            grid.collapsesBorders = true
            grid.hidesEmptyCells = false
            grid.setContentWidth(100, type: .percentageValueType)
            grid.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
            for (row, cells) in ([table.header] + table.rows).enumerated() {
                for (column, text) in cells.enumerated() {
                    let cell = NSTextTableBlock(table: grid, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(NSColor.labelColor.withAlphaComponent(0.15))
                    cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                    cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                    if row == 0 { cell.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06) }
                    let style = style(in: cell)
                    switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
                    case .leading: style.alignment = .natural
                    case .center: style.alignment = .center
                    case .trailing: style.alignment = .right
                    }
                    let font = row == 0 ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
                    result.append(paragraph(inline(text, font: font), style: style))
                }
            }
            return result
        }

        private func style(before: CGFloat, lineSpacing: CGFloat? = nil) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing ?? self.lineSpacing
            style.paragraphSpacingBefore = before
            return style
        }

        /// A paragraph inside `block`, whose own margin sets the space above it.
        private func style(in block: NSTextBlock, lineSpacing: CGFloat? = nil) -> NSMutableParagraphStyle {
            let style = style(before: 0, lineSpacing: lineSpacing)
            style.textBlocks = [block]
            return style
        }

        /// One paragraph of `body`, its own lines joined by line separators so it stays one paragraph in one block.
        private func paragraph(_ body: NSAttributedString, style: NSParagraphStyle) -> NSAttributedString {
            let text = NSMutableAttributedString(attributedString: body)
            text.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: NSRange(location: 0, length: text.length))
            if text.length == 0 { text.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
            text.append(NSAttributedString(string: "\n", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            return text
        }

        /// Markdown's inline styles as AppKit draws them: bold, italic, code, struck through and links.
        private func inline(_ text: AttributedString, font: NSFont? = nil, color: NSColor = .labelColor) -> NSAttributedString {
            let base = font ?? NSFont.systemFont(ofSize: size)
            let result = NSMutableAttributedString()
            for run in text.runs {
                let intent = run.inlinePresentationIntent ?? []
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if intent.contains(.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: base.pointSize - 1.5, weight: .regular)
                    attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
                } else {
                    var traits = base.fontDescriptor.symbolicTraits
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    attributes[.font] = traits == base.fontDescriptor.symbolicTraits ? base
                        : NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
            }
            return result
        }
    }
}
#endif
