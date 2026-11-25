import AppKit
import SwiftUI
import NoodleCore
import NoodleDocument
import NoodleWallpaperCore

extension ConversationAttachment {
    /// A Markdown or shader file, which opens rendered or as its source in a window of its own.
    var opensAsDocument: Bool { annotation == nil && url == nil && voice == nil && DocumentPreviewModel.Kind(self) != nil }
}

/// A Markdown or shader document, and whether it shows rendered or as its source.
@MainActor @Observable final class DocumentPreviewModel {
    enum Kind: Equatable {
        case markdown, shader

        init?(_ attachment: ConversationAttachment) {
            if MarkdownDocument.isMarkdown(name: attachment.originalFilename, mediaType: attachment.mediaType) { self = .markdown }
            else if ShaderSourceFile.isShader(URL(fileURLWithPath: attachment.originalFilename)) { self = .shader }
            else { return nil }
        }

        var label: String { self == .markdown ? "Markdown" : "Shader" }
    }

    /// A larger Markdown file opens in Quick Look, as it would take too long to lay out.
    static let maximumMarkdownBytes = 2 << 20

    let kind: Kind
    let url: URL
    let source: String
    let markdown: MarkdownDocument?
    var showsSource = false

    /// Nil when the file is neither kind, too large, or not text.
    init?(_ attachment: ConversationAttachment, url: URL) {
        guard let kind = Kind(attachment) else { return nil }
        switch kind {
        case .markdown:
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumMarkdownBytes,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
            source = text
            markdown = MarkdownDocument(text)
        case .shader:
            guard let text = try? ShaderSourceFile.read(url) else { return nil }
            source = text
            markdown = nil
        }
        self.kind = kind; self.url = url
    }
}

/// The document rendered, or its source.
struct DocumentPreviewView: View {
    let model: DocumentPreviewModel

    var body: some View {
        Group {
            if model.showsSource {
                DocumentSourceView(text: model.source)
            } else if let markdown = model.markdown {
                MarkdownDocumentView(markdown)
            } else {
                ShaderPreview(url: model.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.3))
    }
}

/// A file's text as it is written, wrapped and selectable.
private struct DocumentSourceView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isRichText = false; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

/// Preview | Source, in the document window's header.
final class DocumentModeControl: NSSegmentedControl {
    private let model: DocumentPreviewModel

    init(model: DocumentPreviewModel) {
        self.model = model
        super.init(frame: .zero)
        segmentCount = 2
        setLabel("Preview", forSegment: 0)
        setLabel("Source", forSegment: 1)
        trackingMode = .selectOne
        controlSize = .small
        selectedSegment = model.showsSource ? 1 : 0
        setAccessibilityLabel("Show")
        target = self; action = #selector(changed)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func changed() { model.showsSource = selectedSegment == 1 }
}

/// The selected text of the key window, as Copy puts it on the pasteboard, which is then put back as it was; nil
/// when nothing is selected.
@MainActor enum CopiedSelection {
    static func text() async -> String? {
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView {
            let range = view.selectedRange()
            return range.length > 0 ? meaningful((view.string as NSString).substring(with: range)) : nil
        }
        let board = NSPasteboard.general
        let oldCount = board.changeCount
        let oldItems = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        guard NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: nil) else { return nil }
        for _ in 0..<20 {
            if board.changeCount != oldCount {
                let value = board.string(forType: .string)
                board.clearContents()
                let restored = oldItems.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !restored.isEmpty { board.writeObjects(restored) }
                return value.flatMap(meaningful)
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private static func meaningful(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
