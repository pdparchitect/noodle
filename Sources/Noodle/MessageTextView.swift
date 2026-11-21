import AppKit
import SwiftUI

/// A message's prose as one read-only text view, so a selection runs across its paragraphs, lists, quotes and code,
/// laid out as `MessageBlocksView` lays them out: the same sizes, indents and space between blocks.
struct MessageTextView: NSViewRepresentable {
    let blocks: [MessageBlock]
    var size: CGFloat = 14
    var lineSpacing: CGFloat = 3.5
    /// The space between blocks; items in a list have half of it.
    var spacing: CGFloat = 10
    /// Whether it is as wide as it is offered, or as wide as its longest line, as the champion's own messages are.
    var fills = true

    func makeNSView(context: Context) -> MessageNSTextView {
        let view = MessageNSTextView()
        view.show(text(), signature: signature)
        return view
    }

    func updateNSView(_ view: MessageNSTextView, context: Context) {
        view.show(text(), signature: signature)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageNSTextView, context: Context) -> CGSize? {
        view.fitting(width: proposal.width, fills: fills)
    }

    /// What the text was built from, so an unchanged message is not built again on every update.
    private var signature: Int {
        var hasher = Hasher()
        hasher.combine(size); hasher.combine(lineSpacing); hasher.combine(spacing)
        for block in blocks {
            switch block {
            case .text(let text): hasher.combine(0); hasher.combine(text)
            case .code(let code): hasher.combine(1); hasher.combine(code)
            case .list(let items): hasher.combine(2); for item in items { hasher.combine(item.marker); hasher.combine(item.text) }
            case .quote(let text): hasher.combine(3); hasher.combine(text)
            case .rule: hasher.combine(4)
            }
        }
        return hasher.finalize()
    }

    private func text() -> () -> NSAttributedString {
        { MessageTextBuilder(size: size, lineSpacing: lineSpacing, spacing: spacing).build(blocks) }
    }
}

/// The blocks as one attributed string: each block one paragraph, or one per list item, with lines inside a quote or
/// code block kept in one paragraph so its bar or box is drawn once around all of it.
struct MessageTextBuilder {
    let size: CGFloat
    let lineSpacing: CGFloat
    let spacing: CGFloat

    /// What a paragraph is drawn with besides its text.
    enum Decoration: Int { case quote = 1, code, rule }

    func build(_ blocks: [MessageBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            switch block {
            case .text(let text):
                result.append(paragraph(inline(text), style: style(after: last ? 0 : spacing)))
            case .quote(let text):
                let style = style(after: last ? 0 : spacing)
                style.firstLineHeadIndent = size * 0.75
                style.headIndent = size * 0.75
                let body = inline(text, color: .secondaryLabelColor)
                result.append(paragraph(body, style: style, decoration: .quote))
            case .code(let code):
                // Set in by the box's padding on every side; the box itself is drawn around the paragraph.
                let padding = size * 0.85
                let style = style(after: (last ? 0 : spacing) + padding, lineSpacing: 0)
                style.paragraphSpacingBefore = padding
                style.firstLineHeadIndent = padding
                style.headIndent = padding
                style.tailIndent = -padding
                style.lineBreakMode = .byCharWrapping
                let body = NSAttributedString(string: code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular), .foregroundColor: NSColor.labelColor,
                ])
                result.append(paragraph(body, style: style, decoration: .code))
            case .rule:
                let style = style(after: last ? 0 : spacing)
                style.paragraphSpacingBefore = size * 0.15
                let body = NSAttributedString(string: "\u{00A0}", attributes: [.font: NSFont.systemFont(ofSize: size * 0.4)])
                result.append(paragraph(body, style: style, decoration: .rule))
            case .list(let items):
                result.append(list(items, after: last ? 0 : spacing))
            }
        }
        // No break after the last paragraph, which would add an empty line under it.
        if result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    /// Each item a paragraph: the marker right-aligned in a column as wide as the longest number, the text after it,
    /// and wrapped lines hanging under the text, not the marker.
    private func list(_ items: [MessageListItem], after: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let widest = items.map(\.marker.count).max() ?? 1
        let markerWidth = items.contains { $0.marker != "•" } ? size * (0.6 + CGFloat(widest) * 0.58) : size * 0.7
        let lead = size * 0.15, gap = size * 0.43
        for (index, item) in items.enumerated() {
            let style = style(after: index == items.count - 1 ? after : spacing / 2)
            style.tabStops = [NSTextTab(textAlignment: .right, location: lead + markerWidth),
                              NSTextTab(textAlignment: .left, location: lead + markerWidth + gap)]
            style.headIndent = lead + markerWidth + gap
            let line = NSMutableAttributedString(string: "\t", attributes: [.font: NSFont.systemFont(ofSize: size)])
            line.append(NSAttributedString(string: item.marker, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            line.append(NSAttributedString(string: "\t", attributes: [.font: NSFont.systemFont(ofSize: size)]))
            line.append(inline(item.text))
            result.append(paragraph(line, style: style))
        }
        return result
    }

    /// A paragraph `after` points above the next. TextKit adds the line spacing after a paragraph's last line too, which
    /// SwiftUI does not, so it comes off the paragraph spacing.
    private func style(after: CGFloat, lineSpacing: CGFloat? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing ?? self.lineSpacing
        style.paragraphSpacing = max(0, after - style.lineSpacing)
        return style
    }

    /// One paragraph of `body`, its own lines joined by line separators so it stays one paragraph.
    private func paragraph(_ body: NSAttributedString, style: NSParagraphStyle, decoration: Decoration? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: body)
        text.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: NSRange(location: 0, length: text.length))
        text.append(NSAttributedString(string: "\n", attributes: body.length > 0 ? body.attributes(at: body.length - 1, effectiveRange: nil) : [:]))
        let range = NSRange(location: 0, length: text.length)
        text.addAttribute(.paragraphStyle, value: style, range: range)
        if let decoration { text.addAttribute(.messageDecoration, value: decoration.rawValue, range: range) }
        return text
    }

    /// Markdown's inline styles as AppKit draws them: bold, italic, code, struck through and links.
    func inline(_ text: AttributedString, color: NSColor = .labelColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            let string = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if intent.contains(.code) {
                // As the renderer sets it, whatever the prose's size: 11.5 points, and dimmer.
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
                attributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(0.65)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                let base = NSFont.systemFont(ofSize: size)
                attributes[.font] = traits.isEmpty ? base
                    : NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }
}

extension NSAttributedString.Key {
    /// A paragraph drawn with a quote's bar, a code block's box or as a rule; its value is a `MessageTextBuilder.Decoration`.
    static let messageDecoration = NSAttributedString.Key("NoodleMessageDecoration")
}

/// The text view: read-only, selectable, without a scroll view of its own, its text container as wide as it is.
final class MessageNSTextView: NSTextView, NSTextLayoutManagerDelegate {
    private var signature: Int?

    init() {
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)
        layoutManager.delegate = self
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor(MessageMarkdownCache.linkColor), .cursor: NSCursor.pointingHand]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("Not built from a coder") }

    func show(_ text: () -> NSAttributedString, signature: Int) {
        guard signature != self.signature else { return }
        self.signature = signature
        textStorage?.setAttributedString(text())
    }

    /// How big it is at `width`: as tall as its text, and as wide as offered, or as its longest line when it does not fill.
    func fitting(width proposed: CGFloat?, fills: Bool) -> CGSize {
        guard let layoutManager = textLayoutManager, let container = layoutManager.textContainer else { return .zero }
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? 100_000
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let used = layoutManager.usageBoundsForTextContainer
        // TextKit leaves out the space after the last paragraph, which for a code block holds its box's padding below.
        var trailing: CGFloat = 0
        if let storage = textStorage, storage.length > 0,
           storage.attribute(.messageDecoration, at: storage.length - 1, effectiveRange: nil) as? Int == MessageTextBuilder.Decoration.code.rawValue,
           let style = storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) as? NSParagraphStyle {
            trailing = style.paragraphSpacingBefore
        }
        return CGSize(width: fills && proposed?.isFinite == true ? width : min(ceil(used.width), width), height: ceil(used.height + trailing))
    }

    /// Only one message keeps a selection: leaving this one clears its own.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let raw = paragraph.attributedString.attribute(.messageDecoration, at: 0, effectiveRange: nil) as? Int,
           let decoration = MessageTextBuilder.Decoration(rawValue: raw) {
            return DecoratedFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A paragraph drawn with its bar, box or rule under its text.
private final class DecoratedFragment: NSTextLayoutFragment {
    let decoration: MessageTextBuilder.Decoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: MessageTextBuilder.Decoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { fatalError("Not built from a coder") }

    private var style: NSParagraphStyle? {
        (textElement as? NSTextParagraph)?.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    /// Where the decoration goes, in the fragment's own coordinates, across the whole width of the text. The fragment
    /// starts at the paragraph's indent, so the decoration starts that far to its left, at the text's edge. It holds the
    /// space before and after the paragraph too: a code block's box takes the padding before it and leaves
    /// the gap to the next block after it; a quote's bar and a rule take only the lines.
    private var decorationRect: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let height = layoutFragmentFrame.height, left = -layoutFragmentFrame.minX
        let before = style?.paragraphSpacingBefore ?? 0, after = (style?.paragraphSpacing ?? 0) + (style?.lineSpacing ?? 0)
        switch decoration {
        case .code:
            // From the padding above its first line to the same padding below its last, measured from the lines, as
            // TextKit leaves out the space after the last paragraph of all.
            let bottom = textLineFragments.last?.typographicBounds.maxY ?? (height - after)
            return CGRect(x: left, y: 0, width: width, height: bottom + before)
        case .quote:
            let top = textLineFragments.first?.typographicBounds.minY ?? before
            let bottom = textLineFragments.last?.typographicBounds.maxY ?? (height - after)
            return CGRect(x: left, y: top, width: 3, height: max(0, bottom - top))
        case .rule:
            let top = textLineFragments.first?.typographicBounds.minY ?? before
            let bottom = textLineFragments.last?.typographicBounds.maxY ?? (height - after)
            return CGRect(x: left, y: (top + bottom) / 2, width: width, height: 1)
        }
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(decorationRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        switch decoration {
        case .code:
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.09).cgColor)
            context.fillPath()
        case .quote:
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor)
            context.fillPath()
        case .rule:
            context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor)
            context.fill(rect)
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
