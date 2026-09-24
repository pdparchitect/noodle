import AppKit
import XCTest
import NoodleCore
@testable import Noodle

/// The annotation editor over Quick Look, driven without showing a window or posting events.
@MainActor final class AnnotationEditorTests: XCTestCase {
    private let source = ConversationAttachment(conversationID: UUID(), originalFilename: "Example.png",
                                                storedFilename: "Example.png", mediaType: "image/png", byteCount: 0)

    private func escape(window: NSWindow, _ type: NSEvent.EventType = .keyDown, repeating: Bool = false) -> NSEvent {
        key(53, "\u{1b}", window: window, type, repeating: repeating)
    }

    private func key(_ code: UInt16, _ characters: String, window: NSWindow, _ type: NSEvent.EventType = .keyDown,
                     repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: repeating, keyCode: code)!
    }

    /// Escape cancels the annotation and the whole press (repeats and release) is consumed, so Quick Look
    /// does not close too. A fresh Escape press then belongs to Quick Look again. The monitor does not keep
    /// its controller alive.
    func testEscapeCancelsTheAnnotationWithoutClosingThePreview() {
        let window = AnnotationCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var owner: AttachmentPreviewController? = AttachmentPreviewController()
        let handler = owner!.eventMonitorHandler()
        owner!.overlay = window
        owner!.pending = .init(source: source)
        let unrelated = key(7, "x", window: window)
        XCTAssertTrue(handler(unrelated) === unrelated)
        XCTAssertNil(handler(escape(window: window)))
        XCTAssertNil(owner!.pending, "Escape cancels the annotation")
        XCTAssertNil(handler(escape(window: window, repeating: true)))
        XCTAssertNil(handler(escape(window: window, .keyUp)))
        let fresh = escape(window: window)
        XCTAssertTrue(handler(fresh) === fresh, "A new Escape press is Quick Look's")
        weak let released = owner
        owner = nil
        XCTAssertNil(released, "The monitor does not retain its controller")
        XCTAssertTrue(handler(unrelated) === unrelated)
    }

    /// The comment popover closes once per cancel and keeps its anchor until the close animation ends. A
    /// late close callback from an earlier popover cannot dismiss the one that replaced it.
    func testCommentPopoverClosesOnceAndStaleClosesAreIgnored() {
        let controller = AttachmentPreviewController()
        let content = AnnotationCommentController()
        content.owner = controller
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 280))
        let window = NSWindow(contentRect: content.view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        defer { controller.close(); window.close() }
        // AppKit resets the mounted content controller's successor; the popover keeps routing to Quick Look's owner.
        content.nextResponder = window
        XCTAssertTrue(content.nextResponder === controller)

        func prepare() -> AnimatedPopover {
            let popover = AnimatedPopover()
            popover.contentViewController = content
            popover.delegate = controller
            controller.commentPopover = popover
            controller.commentPanel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            controller.pending = .init(source: source, quote: "Selected diff text")
            return popover
        }
        let popover = prepare()
        let anchor = controller.commentPanel
        XCTAssertNil(controller.handle(escape(window: window)))
        XCTAssertEqual(popover.closeCount, 1)
        XCTAssertNil(controller.pending)
        XCTAssertTrue(controller.commentPanel === anchor, "The anchor outlives the close animation")
        controller.cancelAnnotation()
        XCTAssertNil(controller.handle(escape(window: window, repeating: true)))
        XCTAssertEqual(popover.closeCount, 1, "Cancelling again does not restart the close")
        popover.completeClose()
        XCTAssertNil(controller.commentPanel)
        XCTAssertNil(controller.overlay)
        XCTAssertNil(controller.handle(escape(window: window, repeating: true)), "A held Escape does not close the source")
        XCTAssertNil(controller.handle(escape(window: window, .keyUp)))
        XCTAssertNotNil(controller.handle(escape(window: window)), "A new press can close the preview")

        let interrupted = prepare()
        controller.cancelAnnotation()
        controller.close()
        XCTAssertNil(controller.commentPanel, "Navigating away cleans up an animating popover at once")
        let replacement = prepare()
        let replacementAnchor = controller.commentPanel
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: interrupted))
        XCTAssertTrue(controller.commentPopover === replacement)
        XCTAssertTrue(controller.commentPanel === replacementAnchor)
        XCTAssertNotNil(controller.pending)
        controller.close()

        let immediate = prepare()
        immediate.completesSynchronously = true
        controller.cancelAnnotation()
        XCTAssertEqual(immediate.closeCount, 1)
        XCTAssertNil(controller.commentPanel, "A close that completes at once is cleaned up exactly once")
    }

    /// The popover points at the pointer when it is over the preview, otherwise at the last selection,
    /// which moves with the window and is kept inside it. A region drag in any direction selects the same
    /// region and anchors at the release point; a click anchors where it landed.
    func testPopoverAnchorsFollowThePointerSelectionAndRegion() throws {
        let frame = NSRect(x: -1100, y: 180, width: 800, height: 600)
        let selected = NSPoint(x: 360, y: 125)
        XCTAssertEqual(AnnotationPopoverAnchor.point(in: frame, screenPointer: NSPoint(x: -1098, y: 182), lastPoint: selected),
                       NSPoint(x: 2, y: 2))
        XCTAssertEqual(AnnotationPopoverAnchor.point(in: frame, screenPointer: NSPoint(x: 300, y: 1000), lastPoint: selected), selected)
        XCTAssertEqual(AnnotationPopoverAnchor.point(in: frame.offsetBy(dx: 1200, dy: -300), screenPointer: NSPoint(x: 300, y: 1000),
                                                     lastPoint: selected), selected)
        XCTAssertEqual(AnnotationPopoverAnchor.point(in: frame, screenPointer: .zero, lastPoint: nil), NSPoint(x: 400, y: 300))
        XCTAssertEqual(AnnotationPopoverAnchor.point(in: frame, screenPointer: .zero, lastPoint: NSPoint(x: 900, y: -5)),
                       NSPoint(x: 800, y: 0))

        let canvas = AnnotationRegionCanvas(image: NSImage(size: frame.size))
        canvas.frame = NSRect(origin: .zero, size: frame.size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        var region: NSRect?, anchor: NSPoint?
        canvas.onRegion = { region = $0; anchor = $1 }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 600, y: 450)))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 200, y: 150)))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 200, y: 150)))
        XCTAssertEqual(region, NSRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(anchor, NSPoint(x: 0.25, y: 0.25))
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 400, y: 300)))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 400, y: 300)))
        XCTAssertEqual(anchor, NSPoint(x: 0.5, y: 0.5))
    }
}

/// A popover whose close animates: it stays shown until the test finishes the close, or closes at once
/// when told to.
@MainActor private final class AnimatedPopover: NSPopover {
    private var showing = true
    var completesSynchronously = false
    private(set) var closeCount = 0
    override var isShown: Bool { showing }
    override func close() {
        closeCount += 1
        if completesSynchronously { completeClose() }
    }
    func completeClose() {
        showing = false
        delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
    }
}
