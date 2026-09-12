import AppKit
import SwiftUI
import NoodleCore

extension AttachmentPreviewController {
    func showRegion(image: NSImage, frame: NSRect) {
        guard let panel = annotationWindow else { return }
        if isConversationAnnotation, let content = panel.contentView {
            let canvas = AnnotationRegionCanvas(image: image, embedded: true)
            // Keep the original window, toolbar and rounded window silhouette.
            // Draw the frozen window at its original coordinates, clipped to
            // the existing content area instead of showing a duplicate window.
            canvas.frame = content.convert(panel.contentLayoutRect, from: nil)
            content.addSubview(canvas, positioned: .above, relativeTo: nil)
            canvas.imageRect = canvas.convert(NSRect(origin: .zero, size: frame.size), from: nil)
            canvas.onRegion = { [weak self] region, point in
                guard let self, self.commentPopover == nil else { return }
                self.pending?.region = .init(x: region.minX, y: region.minY, width: region.width, height: region.height)
                self.textAnchorInPreview = NSPoint(x: point.x * frame.width, y: point.y * frame.height)
                self.showComment()
            }
            conversationCanvas = canvas
            panel.makeFirstResponder(canvas)
            panel.invalidateCursorRects(for: canvas)
            updateCommands()
            return
        }
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
        guard commentPopover == nil, let panel = annotationWindow, let pending else { return }
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
        let hint = NSHostingView(rootView: AnnotationShortcutHint())
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
        guard let editor = commentPanel, let panel = annotationWindow, let popover = commentPopover else { return }
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

private struct AnnotationShortcutHint: View {
    var body: some View {
        Text(KeyboardBindings.shared.binding(for: .saveAnnotation)
            .map { "\($0.displayName) to save  ·  Esc to cancel" } ?? "Esc to cancel")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
    }
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
    private var cursorObserver: CFRunLoopObserver?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        guard let canvas = contentView as? AnnotationRegionCanvas else { return }
        canvas.updateSelectionCursor()
        guard cursorObserver == nil else { return }
        // Quick Look's remote renderer can send cursor changes after losing
        // focus. Repair those at the end of the event cycle, without polling.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
            true, CFIndex.max) { [weak canvas] _, _ in
                MainActor.assumeIsolated { canvas?.updateSelectionCursor() }
        }
        cursorObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    override func resignKey() {
        if let cursorObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), cursorObserver, .commonModes)
            self.cursorObserver = nil
        }
        super.resignKey()
        if contentView is AnnotationRegionCanvas, NSCursor.current == .crosshair {
            NSCursor.arrow.set()
        }
    }

    deinit {
        if let cursorObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), cursorObserver, .commonModes) }
    }
}

@MainActor final class AnnotationRegionCanvas: NSView {
    let image: NSImage
    let embedded: Bool
    var imageRect: NSRect?
    private var pointerHint: NSVisualEffectView?
    private var pointerTracking: NSTrackingArea?
    private weak var trackingWindow: NSWindow?
    private var previousMouseMovedEvents: Bool?
    private var hasStartedSelection = false
    var start: NSPoint?
    var selected: NSRect?
    var onRegion: ((NSRect, NSPoint) -> Void)?
    init(image: NSImage, embedded: Bool = false) {
        self.image = image; self.embedded = embedded
        super.init(frame: .zero)
        if embedded {
            let hint = AnnotationRegionHint()
            hint.material = .hudWindow; hint.blendingMode = .withinWindow; hint.state = .active
            hint.wantsLayer = true; hint.layer?.cornerRadius = 15; hint.layer?.masksToBounds = true
            let text = annotationLabel("Drag to select · Esc to cancel", size: 12, weight: .medium)
            text.translatesAutoresizingMaskIntoConstraints = false; hint.addSubview(text)
            hint.setFrameSize(NSSize(width: text.intrinsicContentSize.width + 26, height: 30))
            hint.isHidden = true; addSubview(hint); pointerHint = hint
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: hint.leadingAnchor, constant: 13),
                text.trailingAnchor.constraint(equalTo: hint.trailingAnchor, constant: -13),
                text.centerYAnchor.constraint(equalTo: hint.centerYAnchor)
            ])
            setAccessibilityLabel("Select a conversation region to annotate")
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let trackingWindow, let previousMouseMovedEvents {
            trackingWindow.acceptsMouseMovedEvents = previousMouseMovedEvents
        }
        trackingWindow = nil; previousMouseMovedEvents = nil
        guard embedded, let window else { return }
        trackingWindow = window; previousMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        positionHint(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking); self.pointerTracking = nil }
        guard embedded else { return }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); pointerTracking = area
    }
    override func mouseEntered(with event: NSEvent) { positionHint(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { positionHint(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerHint?.isHidden = true }
    private func positionHint(at pointer: NSPoint) {
        guard let hint = pointerHint else { return }
        guard !hasStartedSelection, bounds.contains(pointer) else { hint.isHidden = true; return }
        let size = hint.frame.size
        let margin: CGFloat = 8
        var x = pointer.x + 16
        var y = pointer.y - size.height - 14
        if x + size.width > bounds.maxX - margin { x = pointer.x - size.width - 16 }
        if y < bounds.minY + margin { y = pointer.y + 14 }
        x = max(bounds.minX + margin, min(x, bounds.maxX - size.width - margin))
        y = max(bounds.minY + margin, min(y, bounds.maxY - size.height - margin))
        hint.setFrameOrigin(NSPoint(x: x, y: y)); hint.isHidden = false
    }
    override func scrollWheel(with event: NSEvent) { /* Keep the frozen selection stationary. */ }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    func updateSelectionCursor() {
        guard let window, NSApp.isActive, window.isKeyWindow, window.isVisible else { return }
        if start == nil {
            let point = NSEvent.mouseLocation
            guard bounds.contains(convert(window.convertPoint(fromScreen: point), from: nil)),
                  NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
        }
        if NSCursor.current != .crosshair { NSCursor.crosshair.set() }
    }
    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: imageRect ?? bounds)
        if embedded {
            let dimming = NSBezierPath(rect: bounds)
            if let selected { dimming.appendRect(selected) }
            dimming.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.15).setFill(); dimming.fill()
        }
        if let selected {
            NSColor.systemOrange.withAlphaComponent(0.14).setFill(); selected.fill()
            NSColor.systemOrange.setStroke(); let path = NSBezierPath(rect: selected); path.lineWidth = 3; path.stroke()
        }
        guard !embedded else { return }
        let hint = "Drag around a detail · Click to place a pin · Esc to cancel"
        let pill = NSRect(x: 25, y: 20, width: 500, height: 38)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: pill, xRadius: 19, yRadius: 19).fill()
        (hint as NSString).draw(at: NSPoint(x: 42, y: 31), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) {
        hasStartedSelection = true; pointerHint?.isHidden = true
        start = convert(event.locationInWindow, from: nil); selected = nil
    }
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
        let imageFrame = imageRect ?? bounds
        onRegion?(NSRect(x: (rect.minX - imageFrame.minX) / imageFrame.width,
                         y: (rect.minY - imageFrame.minY) / imageFrame.height,
                         width: rect.width / imageFrame.width, height: rect.height / imageFrame.height),
                  NSPoint(x: min(1, max(0, (pointer.x - imageFrame.minX) / imageFrame.width)),
                          y: min(1, max(0, (pointer.y - imageFrame.minY) / imageFrame.height))))
    }
}

/// A moving hint is informational; it must never intercept a selection gesture.
@MainActor private final class AnnotationRegionHint: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
