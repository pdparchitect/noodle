import AppKit
import ScreenCaptureKit
import NoodleCore

/// Foreground, opt-in check with a disposable native PDF preview. Temporarily
/// moves the pointer and captures only this sandboxed fixture's own windows.
@MainActor extension AnnotationFixture {
    func runCursorCheck() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-cursor-\(UUID())")
        repository = WorkspaceRepository(rootURL: directory)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Cursor fixture — never launched")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        text.string = String(repeating: "Select a region of this document.\n", count: 20)
        text.font = .systemFont(ofSize: 18)
        let pdf = try repository.importAttachment(data: text.dataWithPDF(inside: text.bounds),
            originalFilename: "Cursor.pdf", into: bot.conversation.id, mediaType: "application/pdf")
        let host = window("Isolated annotation cursor check", controller: first)
        try await focus(host)
        try await wait()
        show(pdf, on: first)
        try await wait(1.2)
        guard let preview = first.panel else { fixtureFailure("Missing preview") }
        try await focus(preview)
        try await until("Quick Look must acquire focus") { first.canAnnotate }
        let originalPointer = NSEvent.mouseLocation
        defer { moveCursor(to: originalPointer) }
        let point = NSPoint(x: preview.frame.midX, y: preview.frame.midY)
        moveCursor(to: point)
        try await wait(0.2)
        try await key(15, characters: "r", flags: [.command, .shift], window: preview)
        try await until("Region overlay must open") { first.overlay?.isKeyWindow == true }
        for _ in 0..<3 {
            try await wait(0.1)
            checkCrosshair("Stationary pointer after the shortcut")
        }
        // Reproduce the observed delayed NSRemoteView cursor update, without
        // private Quick Look APIs or relying on an XPC timing race to occur.
        NSCursor.arrow.set()
        try await wait(0.1)
        checkCrosshair("Late preview cursor update must be repaired without mouse movement")
        try await captureCursorWindow(first.overlay!, name: "selection")
        moveCursor(to: NSPoint(x: point.x + 50, y: point.y + 50))
        try await wait(0.2)
        checkCrosshair("Moving within the selection canvas")

        // An overlapping window must keep its own cursor even when the canvas
        // remains key, as can happen with floating panels and menus.
        let pointer = NSEvent.mouseLocation
        let cover = NSPanel(contentRect: NSRect(x: pointer.x - 60, y: pointer.y - 60, width: 120, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = NSWindow.Level(rawValue: first.overlay!.level.rawValue + 1)
        cover.orderFront(nil)
        try await wait(0.1)
        require(NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == cover.windowNumber,
            "The fixture's covering window must be under the pointer")
        NSCursor.arrow.set()
        try await wait(0.1)
        require(NSCursor.current == .arrow, "The selection must not override an overlapping window's cursor")
        cover.orderOut(nil)
        try await wait(0.1)
        checkCrosshair("Returning to the uncovered selection canvas")

        try await key(53, characters: "\u{1b}", window: first.overlay!)
        try await until("Escape must restore Quick Look") { first.canAnnotate }
        try await wait(0.2)
        require(NSCursor.current != .crosshair, "Escape must not leave or restore the selection crosshair")

        try await key(15, characters: "r", flags: [.command, .shift], window: preview)
        try await until("Region overlay must reopen") { first.overlay?.isKeyWindow == true }
        let overlay = first.overlay!
        try await cursorMouse(.leftMouseDown, at: point, in: overlay)
        let end = NSPoint(x: point.x + 100, y: point.y + 80)
        try await cursorMouse(.leftMouseDragged, at: end, in: overlay)
        checkCrosshair("Dragging a selection")
        try await captureCursorWindow(overlay, name: "dragging")
        try await cursorMouse(.leftMouseUp, at: end, in: overlay)
        try await until("Selecting a region must focus its comment") { first.commentInput?.window?.isKeyWindow == true }
        try await wait(0.2)
        require(NSCursor.current != .crosshair, "The comment editor must not inherit the selection crosshair")
        NSCursor.iBeam.set()
        try await wait(0.2)
        require(NSCursor.current != .crosshair, "Late selection work must not override the comment cursor")
        try await key(53, characters: "\u{1b}", window: first.commentInput!.window!)
        try await until("Comment cancellation must restore Quick Look") { first.canAnnotate }
        require(stored.isEmpty, "The cursor fixture must never save or send annotations")
        first.close()
    }

    private func checkCrosshair(_ context: String) {
        guard let overlay = first.overlay, overlay.isKeyWindow, NSApp.isActive,
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == overlay.windowNumber else {
            fixtureFailure("Cursor check interrupted by a focus or pointer change: \(context)")
        }
        require(NSCursor.current == .crosshair, "\(context): expected a crosshair, got \(NSCursor.current)")
    }

    private func cursorMouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        moveCursor(to: point)
        let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        guard let canvas = window.contentView as? AnnotationRegionCanvas else { fixtureFailure("Missing selection canvas") }
        // Deliver to the production canvas directly: synthetic mouse drags are
        // not backed by a physical button-down sequence in the window server.
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        default: fixtureFailure("Unexpected fixture mouse event")
        }
        try await wait(0.15)
    }

    private func moveCursor(to point: NSPoint) {
        let displayHeight = NSScreen.screens.first!.frame.maxY
        let result = CGWarpMouseCursorPosition(CGPoint(x: point.x, y: displayHeight - point.y))
        require(result == .success, "Could not move the pointer within the foreground fixture")
    }

    private func captureCursorWindow(_ window: NSWindow, name: String) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let captured = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            fixtureFailure("Missing own-process capture window")
        }
        let filter = SCContentFilter(desktopIndependentWindow: captured)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.showsCursor = true; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-cursor-\(name).png")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
        print("CURSOR_IMAGE: \(url.path)")
    }
}
