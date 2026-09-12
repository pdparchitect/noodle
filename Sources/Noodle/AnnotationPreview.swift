import AppKit
import SwiftUI
import PDFKit
import NoodleCore

/// Reads saved feedback directly. Original documents still open in Quick Look.
@MainActor final class AnnotationPreviewController: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?

    func show(_ attachment: ConversationAttachment, url: URL, relativeTo host: NSWindow,
              edit: ((ConversationAttachment, String) throws -> ConversationAttachment)? = nil,
              canEdit: @escaping (ConversationAttachment) -> Bool = { _ in false }) {
        guard let note = attachment.annotation else { return }
        let panel: NSPanel
        if let window {
            panel = window
        } else {
            sourceWindow = host; sourceResponder = host.firstResponder
            panel = Self.makeWindow(for: note)
            panel.delegate = self
            let screen = host.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? host.frame
            var frame = panel.frame
            frame.size.width = min(frame.width, screen.width)
            frame.size.height = min(frame.height, screen.height)
            frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
            panel.setFrame(frame, display: false)
            window = panel
        }
        panel.title = "Annotation — \(note.sourceFilename)"
        var current = attachment
        let saveEdit: ((String) throws -> AttachmentAnnotation)? = edit.map { edit in
            { comment in
                guard canEdit(current) else { throw WorkspaceError.invalidAttachment }
                let updated = try edit(current, comment)
                guard let annotation = updated.annotation else { throw WorkspaceError.invalidAttachment }
                current = updated
                return annotation
            }
        }
        Self.setContent(note: note, image: AnnotationPreviewContent.image(for: attachment, url: url), in: panel,
            edit: saveEdit, canEdit: { canEdit(current) })
        panel.makeKeyAndOrderFront(nil)
    }

    /// Construction is separate from presentation so the real frame can also be
    /// rendered offscreen without activating the app or showing a window.
    static func makeWindow(for note: AttachmentAnnotation) -> NSPanel {
        let panel = AnnotationPreviewPanel(contentRect: NSRect(x: 0, y: 0,
            width: note.region == nil ? 680 : 860, height: note.region == nil ? 480 : 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 320)
        panel.identifier = NSUserInterfaceItemIdentifier("NoodleAnnotationPreview")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        return panel
    }

    static func setContent(note: AttachmentAnnotation, image: NSImage?, in panel: NSPanel,
                           edit: ((String) throws -> AttachmentAnnotation)? = nil, canEdit: @escaping () -> Bool = { true }) {
        let content = NSHostingView(rootView: AnnotationPreviewContent(note: note, image: image, edit: edit, canEdit: canEdit))
        content.sizingOptions = []
        panel.contentView = AnnotationPreviewFrame(content: content, filename: note.sourceFilename)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        if closing.isKeyWindow {
            sourceWindow?.makeKeyAndOrderFront(nil)
            if let sourceResponder { sourceWindow?.makeFirstResponder(sourceResponder) }
        }
        sourceWindow = nil; sourceResponder = nil
    }
}

private final class AnnotationPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct AnnotationPreviewContent: View {
    @State private var note: AttachmentAnnotation
    let image: NSImage?
    let edit: ((String) throws -> AttachmentAnnotation)?
    let canEdit: () -> Bool
    @State private var commentHeight: CGFloat = 72
    @State private var isEditing = false
    @State private var draftComment = ""
    @State private var editError: String?
    @FocusState private var editorFocused: Bool

    init(note: AttachmentAnnotation, image: NSImage?, edit: ((String) throws -> AttachmentAnnotation)? = nil,
         canEdit: @escaping () -> Bool = { true }) {
        _note = State(initialValue: note); self.image = image; self.edit = edit
        self.canEdit = canEdit
    }

    private var editingAllowed: Bool { edit != nil && canEdit() }

    @MainActor static func image(for attachment: ConversationAttachment, url: URL) -> NSImage? {
        guard let note = attachment.annotation, note.region != nil else { return nil }
        if note.version == 1 {
            // Read previously saved reports without rewriting their stored files.
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 1,
                  let page = pdf.page(at: pdf.pageCount - 1) else { return nil }
            return page.thumbnail(of: NSSize(width: 1600, height: 2000), for: .mediaBox)
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if note.region != nil {
                    ZStack {
                        Color.black.opacity(0.6)
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                                .accessibilityLabel("Saved preview with the annotated region outlined in orange")
                        } else {
                            Label("The saved image is unavailable.", systemImage: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let quote = note.quote {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Selected text").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(quote).font(.system(size: 16)).lineSpacing(5)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 16)
                                .overlay(alignment: .leading) { Rectangle().fill(.orange.opacity(0.8)).frame(width: 2) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.3))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            commentHeader(wholeAttachment: true)
                            if isEditing && editingAllowed { commentEditor }
                            else {
                                Text(note.comment).font(.system(size: 16)).lineSpacing(5)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.3))
                }
                if note.quote != nil || note.region != nil {
                    Divider().overlay(.white.opacity(0.08))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            commentHeader()
                            if isEditing && editingAllowed { commentEditor }
                            else {
                                Text(note.comment).font(.system(size: 14)).lineSpacing(3)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { commentHeight = $0 }
                    }
                    .frame(height: min(max(72, commentHeight), max(72, geometry.size.height * (isEditing ? 0.5 : 0.3))))
                    .background(.white.opacity(0.035))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: editingAllowed) { _, allowed in
            if !allowed { isEditing = false; draftComment = ""; editError = nil }
        }
    }

    private func commentHeader(wholeAttachment: Bool = false) -> some View {
        HStack {
            Label(wholeAttachment ? "Whole attachment" : "Comment", systemImage: "text.bubble")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if editingAllowed && !isEditing {
                Button("Edit Comment") {
                    draftComment = note.comment; editError = nil; isEditing = true
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var commentEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draftComment).font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(7).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.18)))
                .frame(height: 90).focused($editorFocused)
                .accessibilityLabel("Edit annotation comment")
                .onAppear { editorFocused = true }
                .onExitCommand { isEditing = false; editError = nil }
            if let editError { Text(editError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer(minLength: 8)
                Button("Cancel") { isEditing = false; editError = nil }
                Button("Save") {
                    guard editingAllowed, let edit else { return }
                    do {
                        note = try edit(draftComment)
                        isEditing = false; editError = nil
                    } catch { editError = error.localizedDescription }
                }
                .appShortcut(.saveAnnotation)
                .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }
}

/// Uses the same native HUD material and compact chrome as Noodle's other
/// preview panels. The header is draggable; feedback stays outside the image.
@MainActor final class AnnotationPreviewFrame: NSVisualEffectView {
    init(content: NSView, filename: String, kindLabel: String = "Annotation", closeHint: String = "Close Preview (Esc or ⌘W)") {
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .behindWindow; state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 18; layer?.masksToBounds = true
        layer?.borderWidth = 1; layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let header = AnnotationPreviewHeader()
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Preview")!,
                             target: header, action: #selector(AnnotationPreviewHeader.closePreview))
        close.isBordered = false; close.contentTintColor = .secondaryLabelColor
        close.toolTip = closeHint; close.setAccessibilityLabel("Close Preview")
        let title = NSTextField(labelWithString: filename)
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kind = NSTextField(labelWithString: kindLabel)
        kind.font = .systemFont(ofSize: 11, weight: .medium); kind.textColor = .secondaryLabelColor
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let inset = NSView(); inset.wantsLayer = true
        inset.layer?.cornerRadius = 13; inset.layer?.masksToBounds = true
        for child in [header, inset] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        for child in [close, title, kind] { header.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        inset.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 36),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18), close.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: kind.leadingAnchor, constant: -16),
            kind.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            kind.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            inset.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            inset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            inset.topAnchor.constraint(equalTo: header.bottomAnchor), inset.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            content.leadingAnchor.constraint(equalTo: inset.leadingAnchor), content.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
            content.topAnchor.constraint(equalTo: inset.topAnchor), content.bottomAnchor.constraint(equalTo: inset.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor private final class AnnotationPreviewHeader: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
    @objc func closePreview() { window?.performClose(nil) }
}
