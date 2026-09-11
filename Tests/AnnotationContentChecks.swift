import AppKit
import PDFKit
import NoodleCore
import SwiftUI
import Observation
import Vision

/// Exercises encoding and preview content loading without opening any windows.
@MainActor enum AnnotationContentChecks {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-content-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = ConversationAttachment(conversationID: UUID(), originalFilename: "Example.png",
            storedFilename: "Example.png", mediaType: "image/png", byteCount: 0)
        let quote = "The selected text includes Unicode: café, 日本語, 🐈."
        let comment = String(repeating: "A long line of feedback.\n", count: 180) + "END OF FEEDBACK"
        let textNote = AttachmentAnnotation(source: source, quote: quote, comment: comment)
        let textData = try AnnotationContent.data(for: textNote, snapshot: nil)
        require(String(data: textData, encoding: .utf8) == textNote.textRepresentation)
        require(String(data: textData, encoding: .utf8)!.contains(comment) && String(data: textData, encoding: .utf8)!.contains(quote),
            "Plain text must preserve full feedback and Unicode source text")

        let image = NSImage(size: NSSize(width: 900, height: 600), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.blue.setFill(); NSRect(x: 630, y: 420, width: 180, height: 120).fill()
            return true
        }
        let note = AttachmentAnnotation(source: source, comment: "Move the blue rectangle",
            region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let imageData = try AnnotationContent.data(for: note, snapshot: image)
        let png = NSBitmapImageRep(data: imageData)!
        require(png.pixelsWide == 900 && png.pixelsHigh == 600, "PNG must preserve snapshot dimensions")
        let marker = png.colorAt(x: 90, y: 360)!.usingColorSpace(.deviceRGB)!
        require(marker.redComponent > 0.9 && marker.greenComponent > 0.4 && marker.greenComponent < 0.7 && marker.blueComponent < 0.1,
            "PNG marker must follow bottom-left normalized coordinates")
        let blue = png.colorAt(x: 700, y: 100)!.usingColorSpace(.deviceRGB)!
        require(blue.blueComponent > 0.9 && blue.redComponent < 0.1, "Snapshot orientation and unmarked pixels must be preserved")
        let imageURL = directory.appendingPathComponent("note.png")
        try imageData.write(to: imageURL)
        let attachment = ConversationAttachment(conversationID: source.conversationID, originalFilename: "note.png",
            storedFilename: "note.png", mediaType: "image/png", byteCount: Int64(imageData.count), annotation: note)
        require(AnnotationPreviewContent.image(for: attachment, url: imageURL) != nil, "Viewer must load the PNG file")
        require(attachment.annotation?.comment == note.comment, "Comment must remain separate metadata")
        do {
            _ = try AnnotationContent.data(for: note, snapshot: nil)
            fixtureFailure("A visual note must not save without its image")
        } catch WorkspaceError.invalidAttachment {}

        let legacy = AttachmentAnnotation(source: source, comment: "Earlier feedback", region: note.region, version: 1)
        let report = PDFDocument()
        report.insert(PDFPage(image: image)!, at: 0)
        report.insert(PDFPage(image: image)!, at: 1)
        let legacyURL = directory.appendingPathComponent("legacy.pdf")
        try report.dataRepresentation()!.write(to: legacyURL)
        let oldAttachment = ConversationAttachment(conversationID: source.conversationID, originalFilename: "legacy.pdf",
            storedFilename: "legacy.pdf", mediaType: "application/pdf", byteCount: 0, annotation: legacy)
        require(AnnotationPreviewContent.image(for: oldAttachment, url: legacyURL) != nil, "Viewer must still read legacy report snapshots")
        let editedLegacy = try AnnotationContent.editedData(for: legacy.replacingComment("Updated legacy feedback"), originalURL: legacyURL)
        let editedReport = PDFDocument(data: editedLegacy)!
        require(editedReport.string?.contains("Updated legacy feedback") == true && editedReport.pageCount >= 2,
            "Legacy edits must update feedback pages and preserve the snapshot")
        try checkHostRemount()
        checkConversationNavigation(source: source)
        checkPopoverAnchors()
        checkPopoverDismissal(source: source)
        checkEventMonitorBoundary(source: source)
        checkSubmittedPreviewBecomesReadOnly(source: source)
        checkNativePreviewClosing()
        if CommandLine.arguments.contains("--render-previews") {
            renderPreview(note: note, image: NSImage(data: imageData), name: "image")
            renderPreview(note: AttachmentAnnotation(source: source, quote: quote, comment: "Make the launch date more specific."), image: nil, name: "text")
        }
        require(NSApp.windows.allSatisfy { !$0.isVisible }, "Headless checks must never show a window")
    }

    private static func checkEventMonitorBoundary(source: ConversationAttachment) {
        let window = AnnotationCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var owner: AttachmentPreviewController? = AttachmentPreviewController()
        let handler = owner!.eventMonitorHandler()
        owner!.overlay = window
        owner!.pending = .init(source: source)
        func key(_ code: UInt16, type: NSEvent.EventType = .keyDown, repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : "x",
                charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "x", isARepeat: repeating, keyCode: code)!
        }
        let unrelated = key(7)
        require(handler(unrelated) === unrelated, "Unrelated keyboard input must pass through")
        require(handler(key(53)) == nil, "The installed monitor must preserve consumed Escape, not forward it to AppKit")
        require(owner!.pending == nil, "Escape must cancel the annotation")
        require(handler(key(53, repeating: true)) == nil, "The installed monitor must consume held Escape")
        require(handler(key(53, type: .keyUp)) == nil, "The installed monitor must consume Escape release")
        let separateEscape = key(53)
        require(handler(separateEscape) === separateEscape, "A new Escape press must remain available to Quick Look")
        weak let releasedOwner = owner
        owner = nil
        require(releasedOwner == nil, "The event monitor must not retain its controller")
        require(handler(unrelated) === unrelated, "Input must pass through after owner deallocation")
    }

    private static func checkSubmittedPreviewBecomesReadOnly(source: ConversationAttachment) {
        let note = AttachmentAnnotation(source: source, quote: "Selected source", comment: "Draft comment")
        let attachment = ConversationAttachment(conversationID: source.conversationID, originalFilename: "note.txt",
            storedFilename: "note.txt", mediaType: "text/plain", byteCount: 0, annotation: note)
        var drafts = ConversationDrafts()
        drafts[attachment.conversationID].attachments = [attachment]
        let conversation = AnnotationPreviewTestConversation()
        var savedComments = 0
        let panel = AnnotationPreviewController.makeWindow(for: note)
        defer { panel.close() }
        AnnotationPreviewController.setContent(note: note, image: nil, in: panel,
            edit: { comment in savedComments += 1; return note.replacingComment(comment) },
            canEdit: { drafts.canEditAnnotation(attachment, messages: conversation.messages) })
        func settle() {
            for _ in 0..<8 {
                panel.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
        }
        func renderedText(_ name: String) -> String {
            settle()
            guard let content = panel.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                fixtureFailure("Missing offscreen preview bitmap")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let image = bitmap.cgImage,
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                fixtureFailure("Missing offscreen preview image")
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-annotation-editing-\(name).png")
            do {
                try data.write(to: file)
                print("RENDER: \(file.path)")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").lowercased()
            } catch { fixtureFailure(error.localizedDescription) }
        }
        let draftText = renderedText("draft")
        require(draftText.contains("edit comment"), "The actual draft preview must render Edit Comment: \(draftText)")
        conversation.messages = [ChatMessage(conversationID: attachment.conversationID, author: .user,
            body: "Submitted", delivery: .queued, attachmentIDs: [attachment.id])]
        let submittedText = renderedText("submitted")
        require(!submittedText.contains("edit comment") && !submittedText.contains("save"),
            "Submission must remove editing controls from the actual open preview")
        require(submittedText.contains("draft comment") && submittedText.contains("selected source"),
            "Submitted comments and source text must remain readable: \(submittedText)")
        require(savedComments == 0, "Submission must never save a new comment")
    }

    private static func checkHostRemount() throws {
        let first = AttachmentPreviewController(), second = AttachmentPreviewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AttachmentPreviewHost(controller: first))
        window.contentView = host
        for controller in [first, second, first] {
            first.close(); second.close()
            host.rootView = AttachmentPreviewHost(controller: controller)
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                if controller.isViewLoaded && controller.view.window === window { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            require(controller.isViewLoaded && controller.view.window === window,
                "Switching chats must mount the same controller used by attachment clicks")
            require(window.makeFirstResponder(controller.view), "Preview host must become first responder")
            var responder = window.firstResponder
            var chain: [NSResponder] = []
            while let current = responder, !chain.contains(where: { $0 === current }), chain.count < 30 {
                chain.append(current); responder = current.nextResponder
            }
            require(chain.contains(where: { $0 === controller }),
                "Quick Look must find the controller after close and navigation: \(chain.map { String(describing: type(of: $0)) })")
        }
        window.close()
    }

    private static func checkConversationNavigation(source: ConversationAttachment) {
        let first = UUID(), second = UUID()
        var current: AttachmentPreviewController?
        var retainedClick: (() -> NSWindow?)?
        let record: (AttachmentPreviewController) -> Void = { controller in
            current = controller
            if retainedClick == nil { retainedClick = { controller.resolveHostWindow() } }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnnotationNavigationFixture(conversationID: first, record: record))
        window.contentView = host
        var initial: AttachmentPreviewController?
        for selection in [first, second, first, nil, second, first] as [UUID?] {
            current?.close()
            // A pending annotation must also be discarded by navigation itself.
            if selection != first { current?.pending = .init(source: source, quote: "Selection before switching") }
            current = nil
            host.rootView = AnnotationNavigationFixture(conversationID: selection, record: record)
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if current?.resolveHostWindow() === window, current?.pending == nil { break }
            }
            guard let current else { fixtureFailure("Navigation did not construct the conversation detail") }
            if initial == nil { initial = current }
            require(current === initial, "Conversation changes must preserve the window's preview controller")
            require(current.resolveHostWindow() === window && retainedClick?() === window,
                "Both current and retained attachment clicks must resolve the live host after returning to a chat")
            require(current.pending == nil, "Changing conversations must dismiss pending annotation state")
            require(window.makeFirstResponder(current.view), "The persistent preview responder must remain reachable")
            var responder = window.firstResponder
            var found = false
            for _ in 0..<30 {
                if responder === current { found = true; break }
                responder = responder?.nextResponder
            }
            require(found, "Quick Look must find the window-scoped controller after navigation")
        }
        window.close()
    }

    private static func checkPopoverAnchors() {
        let frame = NSRect(x: -1100, y: 180, width: 800, height: 600)
        let selected = NSPoint(x: 360, y: 125)
        require(AnnotationPopoverAnchor.point(in: frame, screenPointer: NSPoint(x: -1098, y: 182), lastPoint: selected)
            == NSPoint(x: 2, y: 2), "A shortcut near the preview edge must anchor at the cursor")
        require(AnnotationPopoverAnchor.point(in: frame, screenPointer: NSPoint(x: 300, y: 1000), lastPoint: selected)
            == selected, "Choosing the menu command must preserve the last selection point")
        let moved = frame.offsetBy(dx: 1200, dy: -300)
        require(AnnotationPopoverAnchor.point(in: moved, screenPointer: NSPoint(x: 300, y: 1000), lastPoint: selected)
            == selected, "A remembered anchor must move with its preview window")
        require(AnnotationPopoverAnchor.point(in: frame, screenPointer: .zero, lastPoint: nil)
            == NSPoint(x: 400, y: 300), "Only an unknown pointer should fall back to the preview center")
        require(AnnotationPopoverAnchor.point(in: frame, screenPointer: .zero, lastPoint: NSPoint(x: 900, y: -5))
            == NSPoint(x: 800, y: 0), "A resized preview must keep remembered points within its bounds")

        let canvas = AnnotationRegionCanvas(image: NSImage(size: frame.size))
        canvas.frame = NSRect(origin: .zero, size: frame.size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        var region: NSRect?, anchor: NSPoint?
        canvas.onRegion = { region = $0; anchor = $1 }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Invoke only this offscreen canvas; never post events to the desktop.
        canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 600, y: 450)))
        canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 200, y: 150)))
        canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 200, y: 150)))
        require(region == NSRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), "A reverse drag must preserve the selected region")
        require(anchor == NSPoint(x: 0.25, y: 0.25), "The region popover must point at the drag's release point")
        canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 400, y: 300)))
        canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 400, y: 300)))
        require(anchor == NSPoint(x: 0.5, y: 0.5), "A region pin must anchor at the clicked point")
        window.close()
    }

    private static func checkPopoverDismissal(source: ConversationAttachment) {
        let controller = AttachmentPreviewController()
        let content = AnnotationCommentController()
        content.owner = controller
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 280))
        let window = NSWindow(contentRect: content.view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = content
        // Simulate AppKit resetting the mounted content controller's successor.
        content.nextResponder = window
        require(content.nextResponder === controller,
            "The popover must route to the existing QL owner instead of taking ownership itself")

        func prepare() -> DeferredAnnotationPopover {
            let popover = DeferredAnnotationPopover()
            popover.contentViewController = content; popover.delegate = controller
            controller.commentPopover = popover
            controller.commentPanel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            controller.pending = .init(source: source, quote: "Selected diff text")
            return popover
        }
        func escape(_ type: NSEvent.EventType = .keyDown, repeat isRepeat: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: isRepeat, keyCode: 53)!
        }
        let popover = prepare()
        let anchor = controller.commentPanel
        require(controller.handle(escape()) == nil, "Escape must be consumed by annotation cancellation")
        require(popover.closeCount == 1 && controller.pending == nil, "Escape must request one editor close")
        require(controller.commentPanel === anchor,
            "The anchor must survive until the native popover close animation completes")
        controller.cancelAnnotation()
        require(controller.handle(escape(repeat: true)) == nil && popover.closeCount == 1,
            "Repeated cancellation must neither restart closing nor pass Escape to Quick Look")
        popover.completeClose()
        require(controller.commentPanel == nil && controller.overlay == nil,
            "Close completion must remove annotation-only windows")
        require(controller.handle(escape(repeat: true)) == nil,
            "Holding Escape must not close the source after the popup disappears")
        require(controller.handle(escape(.keyUp)) == nil, "The matching Escape release must finish the consumed press")
        require(controller.handle(escape()) != nil, "A new Escape press must remain available to close the preview")

        let interrupted = prepare()
        controller.cancelAnnotation()
        controller.close()
        require(controller.commentPanel == nil, "Navigating away must clean up an animating popup immediately")
        let replacement = prepare()
        let replacementAnchor = controller.commentPanel
        // A late notification from the first animation cannot dismiss the next editor.
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: interrupted))
        require(controller.commentPopover === replacement && controller.commentPanel === replacementAnchor && controller.pending != nil,
            "A stale close callback must not affect a newer annotation")
        controller.close()
        let immediate = prepare()
        immediate.completesSynchronously = true
        controller.cancelAnnotation()
        require(immediate.closeCount == 1 && controller.commentPanel == nil,
            "An immediate native close notification must also complete cleanup exactly once")
        controller.close()
        window.close()
    }

    private static func checkNativePreviewClosing() {
        func window() -> CountingPreviewWindow {
            let window = CountingPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        let baseline = window()
        baseline.close()
        let native = window()
        var ended = 0
        let nativeSession = PreviewWindowSession(window: native) { ended += 1 }
        native.close()
        require(ended == 1, "A native window close must end the preview session once")
        require(native.orderOutCount == baseline.orderOutCount,
            "Observing the native close must not issue another orderOut request")
        nativeSession.close()
        require(ended == 1 && native.orderOutCount == baseline.orderOutCount,
            "A late app cleanup must not close an already closed preview again")

        let requested = window()
        var requestedEnds = 0
        let requestedSession = PreviewWindowSession(window: requested) { requestedEnds += 1 }
        requestedSession.close(); requestedSession.close()
        require(requestedEnds == 1 && requested.orderOutCount == 1,
            "An explicit app close must order out once, even if cleanup repeats")
        requested.close()
        require(requestedEnds == 1, "A later native close notification must not repeat cleanup")

        let handedOff = window()
        var handoffEnds = 0
        let handoff = PreviewWindowSession(window: handedOff) { handoffEnds += 1 }
        handoff.invalidate()
        handedOff.close()
        require(handoffEnds == 0, "A detached owner must ignore its previous window's later close")
    }

    /// Captures our own constructed view offscreen, never the user's desktop.
    private static func renderPreview(note: AttachmentAnnotation, image: NSImage?, name: String) {
        let panel = AnnotationPreviewController.makeWindow(for: note)
        AnnotationPreviewController.setContent(note: note, image: image, in: panel,
            edit: { note.replacingComment($0) })
        guard let content = panel.contentView else { fixtureFailure("Missing annotation frame") }
        for _ in 0..<8 {
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fixtureFailure("Missing offscreen bitmap") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fixtureFailure("Missing offscreen PNG") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-annotation-preview-\(name).png")
        do { try data.write(to: file); print("RENDER: \(file.path)") }
        catch { fixtureFailure(error.localizedDescription) }
        panel.close()
    }
}

@MainActor @Observable private final class AnnotationPreviewTestConversation {
    var messages: [ChatMessage] = []
}

@MainActor private final class CountingPreviewWindow: NSPanel {
    private(set) var orderOutCount = 0
    override func orderOut(_ sender: Any?) {
        orderOutCount += 1
        super.orderOut(sender)
    }
}

/// Exercises delayed native close notifications without ever showing a popover
/// or manufacturing Quick Look lifecycle callbacks.
@MainActor private final class DeferredAnnotationPopover: NSPopover {
    private var simulatedShown = true
    var completesSynchronously = false
    private(set) var closeCount = 0
    override var isShown: Bool { simulatedShown }
    override func close() {
        closeCount += 1
        if completesSynchronously { completeClose() }
    }
    func completeClose() {
        simulatedShown = false
        delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
    }
}

/// Uses the production window scope with an actual NavigationSplitView, while
/// keeping the native window hidden. The recorder represents a retained chat's
/// attachment callback; presentation itself remains a foreground-only check.
private struct AnnotationNavigationFixture: View {
    let conversationID: UUID?
    let record: (AttachmentPreviewController) -> Void

    var body: some View {
        AttachmentPreviewScope(conversationID: conversationID) { controller in
            detail(controller: controller)
        }
    }

    private func detail(controller: AttachmentPreviewController) -> some View {
        record(controller)
        return NavigationSplitView {
            Text("Conversations")
        } detail: {
            if let conversationID { Text(conversationID.uuidString).id(conversationID) }
            else { Color.clear }
        }
    }
}
