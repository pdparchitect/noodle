import AppKit
import NoodleCore

extension AttachmentPreviewController {
    func showRegion(image: NSImage, frame: NSRect) {
        guard let panel else { return }
        let overlay = AnnotationCapturePanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false; overlay.title = "Choose annotation region"
        overlay.nextResponder = self; overlay.hidesOnDeactivate = false; overlay.hasShadow = false
        let canvas = AnnotationRegionCanvas(image: image)
        canvas.onRegion = { [weak self] region, point in
            guard let self else { return }
            guard self.commentPopover == nil else { return }
            self.pending?.region = .init(x: region.minX, y: region.minY, width: region.width, height: region.height)
            self.textAnchorInPreview = NSPoint(x: point.x * frame.width, y: point.y * frame.height)
            self.showComment()
        }
        overlay.contentView = canvas; self.overlay = overlay
        panel.addChildWindow(overlay, ordered: .above)
        overlay.makeKeyAndOrderFront(nil); overlay.makeFirstResponder(canvas)
        updateCommands()
    }

    func showComment(message: String? = nil) {
        guard commentPopover == nil, let panel, let pending else { return }
        // A clear child window provides a public AppKit anchor without altering Quick Look's view hierarchy.
        let editor = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        editor.title = "Annotation anchor"; editor.isReleasedWhenClosed = false
        editor.nextResponder = self; editor.delegate = self; editor.hidesOnDeactivate = false
        editor.isOpaque = false; editor.backgroundColor = .clear; editor.hasShadow = false
        editor.ignoresMouseEvents = true
        editor.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 346, height: 278))
        let contentController = AnnotationCommentController()
        contentController.owner = self; contentController.view = content
        contentController.nextResponder = self
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.appearance = panel.effectiveAppearance
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = contentController
        popover.contentSize = content.frame.size
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)])
        let header = NSStackView(); header.orientation = .horizontal; header.spacing = 9
        let icon = NSImageView(image: NSImage(systemSymbolName: "bubble.left.and.text.bubble.right.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(annotationLabel("Add a comment", size: 15, weight: .semibold))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal); header.addArrangedSubview(spacer)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel annotation")!, target: self, action: #selector(cancelAnnotation))
        close.isBordered = false; close.contentTintColor = .secondaryLabelColor
        close.imageScaling = .scaleProportionallyDown; close.setAccessibilityLabel("Cancel annotation")
        close.widthAnchor.constraint(equalToConstant: 20).isActive = true
        close.heightAnchor.constraint(equalToConstant: 20).isActive = true
        header.addArrangedSubview(close); stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let reference = NSView(); reference.wantsLayer = true
        reference.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        reference.layer?.cornerRadius = 10
        let quote = annotationLabel(message ?? pending.quote?.replacingOccurrences(of: "\n", with: " ") ?? "Selected image region", size: 12, weight: .medium)
        quote.maximumNumberOfLines = 2; quote.lineBreakMode = .byTruncatingTail
        let source = annotationLabel(pending.file, size: 11); source.textColor = .secondaryLabelColor
        let refStack = NSStackView(views: [quote, source]); refStack.orientation = .vertical; refStack.alignment = .leading; refStack.spacing = 4
        refStack.translatesAutoresizingMaskIntoConstraints = false; reference.addSubview(refStack)
        NSLayoutConstraint.activate([refStack.leadingAnchor.constraint(equalTo: reference.leadingAnchor, constant: 11),
            refStack.trailingAnchor.constraint(equalTo: reference.trailingAnchor, constant: -11),
            refStack.centerYAnchor.constraint(equalTo: reference.centerYAnchor),
            quote.widthAnchor.constraint(equalTo: refStack.widthAnchor)])
        stack.addArrangedSubview(reference)
        reference.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        reference.heightAnchor.constraint(equalToConstant: 60).isActive = true

        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = false; scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 11; scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        let input = AnnotationCommentTextView(frame: NSRect(x: 0, y: 0, width: 316, height: 88))
        input.drawsBackground = false; input.isRichText = false
        input.font = .systemFont(ofSize: 14); input.textContainerInset = NSSize(width: 9, height: 10)
        input.autoresizingMask = [.width]; input.isVerticallyResizable = true
        input.textContainer?.widthTracksTextView = true; input.setAccessibilityLabel("Annotation comment")
        scroll.documentView = input; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let footer = NSStackView(); footer.orientation = .horizontal
        let hint = annotationLabel("⌘↩ to save  ·  Esc to cancel", size: 10); hint.textColor = .secondaryLabelColor
        footer.addArrangedSubview(hint)
        let footerSpace = NSView(); footerSpace.setContentHuggingPriority(.init(1), for: .horizontal); footer.addArrangedSubview(footerSpace)
        let save = NSButton(title: "Save", target: self, action: #selector(saveComment)); save.bezelStyle = .rounded
        save.controlSize = .regular; save.bezelColor = .controlAccentColor
        save.setAccessibilityLabel("Save annotation")
        save.widthAnchor.constraint(equalToConstant: 74).isActive = true
        footer.addArrangedSubview(save); stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        commentPanel = editor; commentPopover = popover; commentInput = input
        panel.addChildWindow(editor, ordered: .above)
        editor.orderFront(nil)
        positionComment()
        content.window?.title = "Add annotation"
        content.window?.makeKey(); content.window?.makeFirstResponder(input)
        updateCommands()
    }

    func positionComment() {
        guard let editor = commentPanel, let panel, let popover = commentPopover else { return }
        let visible = panel.screen?.visibleFrame ?? panel.frame
        let anchor: NSRect
        if let point = textAnchorInPreview {
            anchor = NSRect(x: panel.frame.minX + point.x, y: panel.frame.minY + point.y, width: 1, height: 1)
        } else if let r = pending?.region, let overlay {
            anchor = NSRect(x: overlay.frame.minX + r.x * overlay.frame.width,
                            y: overlay.frame.minY + r.y * overlay.frame.height,
                            width: r.width * overlay.frame.width, height: r.height * overlay.frame.height)
        } else {
            let point = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
            anchor = NSRect(x: panel.frame.minX + point.x, y: panel.frame.minY + point.y, width: 1, height: 1)
        }
        let preferredEdge: NSRectEdge = anchor.maxX + popover.contentSize.width + 30 < visible.maxX ? .maxX : .minX
        editor.setFrame(anchor, display: true)
        popover.show(relativeTo: editor.contentView!.bounds, of: editor.contentView!, preferredEdge: preferredEdge)
    }
}

@MainActor func annotationLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    return field
}

// MARK: - Native popover content

@MainActor final class AnnotationCommentTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("What should change?" as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                withAttributes: [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
}

@MainActor final class AnnotationCommentController: NSViewController {
    weak var owner: AttachmentPreviewController?
    // Keep the same QL controller while the popover is key. A second controller
    // forwarding begin/end callbacks clears the shared data source on handoff.
    // AppKit can change a content controller's next responder when mounting it;
    // always route this controller's chain through the existing preview owner.
    override var nextResponder: NSResponder? {
        get { owner ?? super.nextResponder }
        set { super.nextResponder = newValue }
    }
}

// MARK: - Frozen capture with coordinate-stable region selection

@MainActor final class AnnotationCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AnnotationRegionCanvas: NSView {
    let image: NSImage
    var start: NSPoint?
    var selected: NSRect?
    var onRegion: ((NSRect, NSPoint) -> Void)?
    init(image: NSImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        if let selected {
            NSColor.systemOrange.withAlphaComponent(0.14).setFill(); selected.fill()
            NSColor.systemOrange.setStroke(); let path = NSBezierPath(rect: selected); path.lineWidth = 3; path.stroke()
            let pin = NSRect(x: selected.minX - 13, y: selected.maxY - 13, width: 26, height: 26)
            NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: pin).fill()
            ("1" as NSString).draw(at: NSPoint(x: pin.minX + 8, y: pin.minY + 4), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white])
        }
        let hint = "Drag around a detail · Click to place a pin · Esc to cancel"
        let pill = NSRect(x: 25, y: 20, width: 500, height: 38)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: pill, xRadius: 19, yRadius: 19).fill()
        (hint as NSString).draw(at: NSPoint(x: 42, y: 31), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); selected = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selected = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        if selected == nil || selected!.width < 4 || selected!.height < 4 {
            selected = NSRect(x: start.x - 8, y: start.y - 8, width: 16, height: 16).intersection(bounds)
        }
        self.start = nil; needsDisplay = true
        let rect = selected!
        let pointer = convert(event.locationInWindow, from: nil)
        onRegion?(NSRect(x: rect.minX / bounds.width, y: rect.minY / bounds.height,
                         width: rect.width / bounds.width, height: rect.height / bounds.height),
                  NSPoint(x: min(1, max(0, pointer.x / bounds.width)), y: min(1, max(0, pointer.y / bounds.height))))
    }
}

enum AnnotationPopoverAnchor {
    /// Mouse selection ends in the preview, but choosing its menu command moves
    /// the cursor into the menu bar. Preserve the last preview interaction then.
    static func point(in frame: NSRect, screenPointer: NSPoint, lastPoint: NSPoint?) -> NSPoint {
        if frame.contains(screenPointer) {
            return NSPoint(x: screenPointer.x - frame.minX, y: screenPointer.y - frame.minY)
        }
        if let lastPoint {
            return NSPoint(x: min(frame.width, max(0, lastPoint.x)), y: min(frame.height, max(0, lastPoint.y)))
        }
        return NSPoint(x: frame.width / 2, y: frame.height / 2)
    }
}
