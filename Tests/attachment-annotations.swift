import AppKit
import SwiftUI
import PDFKit
import NoodleCore

@MainActor final class AnnotationFixture: NSObject, NSApplicationDelegate {
    let first = AttachmentPreviewController()
    let second = AttachmentPreviewController()
    var windows: [NSWindow] = []
    var stored: [ConversationAttachment] = []
    var directory: URL!
    var repository: WorkspaceRepository!
    var savedContent: Data?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--visual-cancellation") {
                    try await runVisualCancellation()
                    print("PASS: Quick Look annotations — recorded native cancellation and close transitions")
                    NSApp.terminate(nil)
                    return
                }
                try await run()
                print("PASS: Quick Look annotations, focus, cancellation, text/PNG export, custom previews and window routing")
                if CommandLine.arguments.contains("--preview") { show(stored[1], on: first) }
                else { NSApp.terminate(nil) }
            }
            catch { fixtureFailure(error.localizedDescription) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    func wait(_ seconds: Double = 0.2) async throws { try await Task.sleep(for: .seconds(seconds)) }
    func until(_ description: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await wait(0.05)
        }
        fixtureFailure(description())
    }
    /// Establish foreground setup before simulated user input. Save/Cancel focus
    /// assertions deliberately do not call this helper.
    func focus(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await until("Could not establish foreground test setup for \(window.title)") { NSApp.isActive && window.isKeyWindow }
    }
    func window(_ title: String, controller: AttachmentPreviewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 650, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text(title).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AttachmentPreviewHost(controller: controller)))
        windows.append(window); window.makeKeyAndOrderFront(nil)
        return window
    }
    func show(_ source: ConversationAttachment, on controller: AttachmentPreviewController) {
        controller.show(source, url: repository.attachmentFileURL(source)) { [unowned self] note, data, source in
            self.savedContent = data
            self.stored.append(try repository.importAttachment(data: data, originalFilename: "Annotation.\(note.fileExtension)",
                into: source.conversationID, mediaType: note.mediaType, annotation: note))
        }
    }
    func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = [], window: NSWindow) async throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        let release = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        NSApp.postEvent(event, atStart: false)
        NSApp.postEvent(release, atStart: false)
        try await wait()
    }
    func run() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-fixture-\(UUID())")
        repository = WorkspaceRepository(rootURL: directory)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Fixture — never launched")
        let documentText = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        documentText.string = "The launch is scheduled for Thursday."
        documentText.font = NSFont.systemFont(ofSize: 18)
        let original = documentText.dataWithPDF(inside: documentText.bounds)
        let pdf = try repository.importAttachment(data: original, originalFilename: "Review.pdf",
            into: bot.conversation.id, mediaType: "application/pdf")
        let art = NSImage(size: NSSize(width: 900, height: 600), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 450, y: 120, width: 250, height: 250)).fill()
            ("Review this image" as NSString).draw(at: NSPoint(x: 50, y: 460),
                withAttributes: [.font: NSFont.systemFont(ofSize: 46, weight: .bold), .foregroundColor: NSColor.white])
            return true
        }
        let png = NSBitmapImageRep(data: art.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let image = try repository.importAttachment(data: png, originalFilename: "Artwork.png", into: bot.conversation.id, mediaType: "image/png")
        NSApp.activate(ignoringOtherApps: true)
        let host = window("Annotation fixture", controller: first)
        _ = window("Second chat", controller: second)
        NSApp.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)
        try await until("Fixture must activate before opening Quick Look") { NSApp.isActive && host.isKeyWindow }
        try await wait()
        show(pdf, on: first)
        try await wait(1.2)
        guard let preview = first.panel else { fixtureFailure("Missing native preview") }
        try await focus(preview)
        require(preview.isVisible && preview.isKeyWindow,
            "Quick Look must open from SwiftUI host: visible=\(preview.isVisible), key=\(preview.isKeyWindow), controller=\(String(describing: preview.currentController)), hostResponder=\(String(describing: host.nextResponder)), item=\(String(describing: first.currentURL)), appActive=\(NSApp.isActive), keyWindow=\(NSApp.keyWindow?.title ?? "nil")")
        require(preview.currentController as? AttachmentPreviewController === first, "Host responder must own Quick Look")
        require(first.commentPopover == nil && first.overlay == nil && first.canAnnotate, "No annotation controls at rest")

        // Actual Quick Look copy provider, not a substituted text view.
        let board = NSPasteboard.general
        let originalBoard = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        defer {
            let items = originalBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            }
            board.clearContents(); if !items.isEmpty { board.writeObjects(items) }
        }
        board.clearContents(); board.setString("Original clipboard sentinel", forType: .string)
        require(NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: nil), "Quick Look must support text selection")
        try await key(0, characters: "a", flags: [.command, .shift], window: preview)
        try await until("Native popover must open for text: active=\(NSApp.isActive), key=\(NSApp.keyWindow?.title ?? "nil"), visible=\(preview.isVisible), canAnnotate=\(first.canAnnotate), busy=\(first.busy), pending=\(first.pending != nil), controller=\(String(describing: preview.currentController))") { first.commentPopover?.isShown == true }
        require(first.pending?.quote?.contains("The launch is scheduled for Thursday.") == true,
            "Selected text must come from the displayed Quick Look document")
        require(board.string(forType: .string) == "Original clipboard sentinel", "Copy capture must restore the clipboard")
        require(first.commentPopover?.contentViewController?.view.window?.firstResponder === first.commentInput,
            "Popover must focus its editor")
        first.commentInput?.string = "Make the date more specific."
        try await key(36, characters: "\r", flags: .command, window: first.commentInput!.window!)
        try await until("Save focus: active=\(NSApp.isActive), key=\(NSApp.keyWindow?.title ?? "nil"), visible=\(preview.isVisible), controller=\(String(describing: preview.currentController))") { preview.isKeyWindow && first.commentPopover == nil && first.commentPanel == nil }
        require(stored.count == 1 && first.overlay == nil && first.canAnnotate, "Save must create one annotation and remove all transient controls")
        let textNote = String(data: savedContent!, encoding: .utf8)!
        require(stored[0].mediaType == "text/plain" && stored[0].annotation?.version == 2, "Text note must be a text attachment")
        require(textNote.contains("Make the date more specific."), "Export must contain plain comment text")
        require(textNote.contains("The launch is scheduled for Thursday."), "Export must preserve source context")
        let unchanged = try Data(contentsOf: repository.attachmentFileURL(pdf))
        require(unchanged == original, "Original file must remain untouched")

        first.annotate()
        try await until("Second popover") { first.commentPopover?.isShown == true }
        first.commentInput?.string = "Discard this"
        try await key(53, characters: "\u{1b}", window: first.commentInput!.window!)
        try await until("Escape focus: active=\(NSApp.isActive), key=\(NSApp.keyWindow?.title ?? "nil"), visible=\(preview.isVisible), controller=\(String(describing: preview.currentController))") { preview.isKeyWindow && first.commentPopover == nil && first.commentPanel == nil }
        require(stored.count == 1, "Cancel must not create a file")

        // Match the reported text-provider regression. Check the item after the
        // close animation, not just the first instant QL becomes key again.
        let diff = try repository.importAttachment(data: Data("diff --git a/hello.py b/hello.py\n--- a/hello.py\n+++ b/hello.py\n@@ -1 +1 @@\n-print('Hello')\n+print('Hello, world')\n".utf8),
            originalFilename: "Review.diff", into: bot.conversation.id, mediaType: "text/plain")
        let diffURL = repository.attachmentFileURL(diff)
        show(diff, on: first)
        try await wait(1.2)
        try await focus(preview)
        for _ in 0..<3 {
            require(NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: nil), "Diff preview must support text selection")
            try await key(0, characters: "a", flags: [.command, .shift], window: preview)
            try await until("Diff annotation editor") { first.commentInput?.window?.isKeyWindow == true }
            require(first.pending?.quote?.contains("Hello, world") == true, "Annotation must retain the selected diff text")
            require(preview.currentController as? AttachmentPreviewController === first,
                "The popover must use the same Quick Look owner")
            try await key(53, characters: "\u{1b}", window: first.commentInput!.window!)
            try await until("Diff must regain focus after cancelling") { preview.isKeyWindow && first.commentPanel == nil }
            try await wait(0.6)
            require(preview.isVisible && preview.isKeyWindow && first.currentURL == diffURL && preview.currentPreviewItem?.previewItemURL == diffURL,
                "Escape must leave the same diff visible after every delayed close callback")
            require(preview.dataSource as? AttachmentPreviewController === first && first.canAnnotate,
                "Escape must retain Quick Look's data source and allow another annotation")
        }
        require(stored.count == 1, "Repeated Escape must not save annotations")
        try await key(53, characters: "\u{1b}", window: preview)
        try await until("A separate Escape must close the diff preview") { !preview.isVisible }
        try await wait(1)
        require(!preview.isVisible && first.currentURL == nil,
            "Closing Quick Look must not reopen it through delayed focus or duplicate close callbacks")

        show(image, on: first)
        try await wait(2)
        try await focus(preview)
        try await until("Image preview must acquire its controller before annotation") { first.canAnnotate }
        require(first.currentURL == repository.attachmentFileURL(image), "Switch must retain the requested source")
        first.annotate()
        for _ in 0..<200 {
            if !first.busy { break }
            try await wait(0.05)
        }
        func labels(_ view: NSView?) -> [String] {
            guard let view else { return [] }
            return (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels($0) }
        }
        require(first.overlay != nil, "Own-process image capture: busy=\(first.busy), canAnnotate=\(first.canAnnotate), active=\(NSApp.isActive), keyWindow=\(NSApp.keyWindow?.title ?? "nil"), visible=\(preview.isVisible), controller=\(String(describing: preview.currentController)), pending=\(String(describing: first.pending)), error=\(labels(preview.attachedSheet?.contentView)), windows=\(NSApp.windows.map { "\(type(of: $0)): \($0.title), visible=\($0.isVisible), key=\($0.isKeyWindow)" })")
        guard let canvas = first.overlay?.contentView as? AnnotationRegionCanvas else { fixtureFailure("Missing region canvas") }
        let frame = canvas.bounds
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: frame.width * 0.2, y: frame.height * 0.3),
            modifierFlags: [], timestamp: 0, windowNumber: first.overlay!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: frame.width * 0.6, y: frame.height * 0.7),
            modifierFlags: [], timestamp: 0, windowNumber: first.overlay!.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: drag)
        try await until("Region selection must open popover") { first.commentPopover?.isShown == true }
        require(first.pending?.region?.isValid == true && first.pendingImage != nil, "Region must carry normalized coordinates and snapshot")
        try await until("Region editor must receive keyboard focus") { first.commentInput?.window?.isKeyWindow == true }
        first.commentInput?.string = "Move the orange circle."
        try await key(36, characters: "\r", flags: .command, window: first.commentInput!.window!)
        try await until("Region save focus: active=\(NSApp.isActive), key=\(NSApp.keyWindow?.title ?? "nil"), visible=\(preview.isVisible), controller=\(String(describing: preview.currentController))") { preview.isKeyWindow && first.overlay == nil }
        require(stored.count == 2 && stored[1].mediaType == "image/png" && NSBitmapImageRep(data: savedContent!) != nil,
            "Visual annotation must store an actual PNG with metadata")
        require(stored[1].annotation?.comment == "Move the orange circle.", "Image comment must remain in metadata")

        // Long comments remain plain text without clipping or pagination.
        let longComment = String(repeating: "A long line of feedback for the document.\n", count: 180) + "END OF FEEDBACK"
        let longText = try AnnotationContent.data(for: AttachmentAnnotation(source: pdf, comment: longComment), snapshot: nil)
        require(String(data: longText, encoding: .utf8)!.contains(longComment), "Long feedback must be preserved in full")
        let markerNote = AttachmentAnnotation(source: image, comment: "Keep the marker aligned",
            region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let markedPNG = try AnnotationContent.data(for: markerNote, snapshot: art)
        let marked = NSBitmapImageRep(data: markedPNG)!
        let originalPixels = NSBitmapImageRep(data: png)!
        require(marked.pixelsWide == originalPixels.pixelsWide && marked.pixelsHigh == originalPixels.pixelsHigh,
            "PNG must preserve snapshot dimensions")
        let markerPixel = marked.colorAt(x: marked.pixelsWide / 10, y: marked.pixelsHigh * 6 / 10)!.usingColorSpace(.deviceRGB)!
        require(markerPixel.redComponent > 0.9 && markerPixel.greenComponent > 0.4 && markerPixel.greenComponent < 0.7 && markerPixel.blueComponent < 0.1,
            "PNG must contain its orange marker at the normalized bottom-left region")

        // Switching the item during asynchronous capture cancels stale results.
        first.startRegion()
        show(pdf, on: first)
        try await wait(1)
        require(first.currentURL == repository.attachmentFileURL(pdf) && first.overlay == nil && first.pending == nil)
        NSApp.activate(ignoringOtherApps: true)
        preview.makeKeyAndOrderFront(nil)
        try await until("Fixture must focus the next document before invoking its shortcut") { preview.isKeyWindow }
        first.annotate()
        try await until("Popover before closing preview") { first.commentPopover?.isShown == true }
        preview.close()
        try await wait()
        try await until("Closing preview: popover=\(first.commentPopover != nil), overlay=\(first.overlay != nil), visible=\(preview.isVisible), controller=\(String(describing: preview.currentController))") {
            first.commentPopover == nil && first.overlay == nil && !preview.isVisible
        }

        show(image, on: second)
        try await wait(1)
        NSApp.activate(ignoringOtherApps: true)
        preview.makeKeyAndOrderFront(nil)
        try await until("Fixture must focus the second chat's preview") { preview.isKeyWindow }
        require(preview.currentController as? AttachmentPreviewController === second, "Second chat must acquire the shared preview")
        first.close()
        require(preview.isVisible && second.canAnnotate, "Closing previous chat must not close another chat's preview")
        second.close()
        try await until("Final close: visible=\(preview.isVisible), commands=\(AnnotationCommandsState.shared.enabled)") {
            !preview.isVisible && !AnnotationCommandsState.shared.enabled
        }

        // Composer and transcript share this entry point. Annotations use their
        // own view, while ordinary source files continue to use native Quick Look.
        NSApp.activate(ignoringOtherApps: true)
        show(stored[0], on: first)
        try await until("Saved text must open the custom annotation viewer") { first.annotationPreview.window?.isKeyWindow == true }
        require(!preview.isVisible && !first.canAnnotate, "Reading an annotation must not open or enable source Quick Look")
        require(first.annotationPreview.window?.contentView is AnnotationPreviewFrame, "Notes need their custom preview frame")
        try await key(53, characters: "\u{1b}", window: first.annotationPreview.window!)
        try await until("Escape must close annotation preview") { first.annotationPreview.window == nil }
        show(stored[1], on: first)
        try await until("Saved image annotation must open its viewer") { first.annotationPreview.window?.isKeyWindow == true }
        require(AnnotationPreviewContent.image(for: stored[1], url: repository.attachmentFileURL(stored[1])) != nil,
            "Image notes must load their saved PNG")
        first.close()

        // Previously saved PDFs remain readable, but are never produced by Save.
        let legacyReport = PDFDocument(data: original)!
        legacyReport.insert(PDFPage(image: art)!, at: 1)
        let legacyNote = AttachmentAnnotation(source: image, comment: "Earlier image feedback",
            region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4), version: 1)
        let legacy = try repository.importAttachment(data: legacyReport.dataRepresentation()!, originalFilename: "Old annotation.pdf",
            into: bot.conversation.id, mediaType: "application/pdf", annotation: legacyNote)
        require(AnnotationPreviewContent.image(for: legacy, url: repository.attachmentFileURL(legacy)) != nil,
            "Legacy PDF snapshot must remain readable")
        show(legacy, on: second)
        try await until("Legacy annotation must use custom viewer") { second.annotationPreview.window?.isKeyWindow == true }
        second.close()
        let messages = try repository.loadMessages(conversationID: bot.conversation.id)
        require(messages.isEmpty, "Fixture must never send messages")
    }
}

@main struct AnnotationFixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--headless") {
            app.setActivationPolicy(.prohibited)
            do {
                try AnnotationContentChecks.run()
                print("PASS: Quick Look annotations — headless content, navigation, anchors, popover dismissal and native close lifecycle")
            } catch { fixtureFailure(error.localizedDescription) }
            return
        }
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (title, key, selector) in [("Copy", "c", "copy:"), ("Paste", "v", "paste:"), ("Select All", "a", "selectAll:")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem); app.mainMenu = menu
        let delegate = AnnotationFixture(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
