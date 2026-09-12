import AppKit
import NoodleCore
import ScreenCaptureKit
import SwiftUI

/// Exercises the production stream and preview in a signed sandbox. Captures
/// only this fixture's own windows; never requests access to the user's screen.
@MainActor final class CaptureFixture: NSObject, NSApplicationDelegate {
    let controller = ScreenCapturePreviewController()
    var sourceWindow: NSWindow!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-capture-\(UUID())")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await run()
                print("PASS: screen capture — filtered picker, sandboxed live and offscreen frames, native shortcuts, region selection, plain/annotated PNGs, cancellation and source exclusion")
                print("RENDERS: \(directory.path)")
                NSApp.terminate(nil)
            } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
    }
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ScreenCaptureFailure(message: message) }
    }
    func until(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ScreenCaptureFailure(message: message)
    }
    func sample(_ image: CGImage?) -> NSColor? {
        guard let image else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
    }
    func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags, panel: ScreenCapturePanel) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
        return panel.performKeyEquivalent(with: event)
    }
    func render(_ panel: NSWindow, name: String) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
            throw ScreenCaptureFailure(message: "Render window disappeared")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
        config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true; config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try CaptureAttachment.png(image).write(to: directory.appendingPathComponent(name + ".png"))
    }
    func run() async throws {
        KeyboardBindings.shared.resetAll()
        defer { KeyboardBindings.shared.resetAll() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = WorkspaceRepository(rootURL: directory.appendingPathComponent("workspace"))
        try repository.prepare()
        let conversation = try repository.createAgent(named: "Capture Reviewer").conversation
        sourceWindow = CaptureFixtureWindow(contentRect: NSRect(x: 90, y: 100, width: 620, height: 390),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false; sourceWindow.title = "Capture fixture source"
        sourceWindow.contentView = NSHostingView(rootView: CaptureFixtureSource(color: .red))
        sourceWindow.makeKeyAndOrderFront(nil)
        let transparentHelper = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        transparentHelper.title = "AutoFill fixture"
        transparentHelper.isReleasedWhenClosed = false; transparentHelper.isOpaque = false
        transparentHelper.backgroundColor = .clear; transparentHelper.hasShadow = false
        transparentHelper.contentView = NSView(); transparentHelper.orderFront(nil)
        let stripHelper = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 3, height: 390),
            styleMask: .borderless, backing: .buffered, defer: false)
        stripHelper.title = "Strip fixture"
        stripHelper.isReleasedWhenClosed = false; stripHelper.backgroundColor = .black
        stripHelper.orderFront(nil)
        let minimizedHelper = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        minimizedHelper.title = "Minimized fixture"
        minimizedHelper.isReleasedWhenClosed = false
        minimizedHelper.contentView = NSHostingView(rootView: CaptureFixtureSource(color: .blue))
        minimizedHelper.orderFront(nil); minimizedHelper.miniaturize(nil)
        try await until("Fixture window did not minimize") { minimizedHelper.isMiniaturized }
        defer { transparentHelper.close(); stripHelper.close(); minimizedHelper.close() }
        NSApp.activate(ignoringOtherApps: true)
        let service = FixtureCaptureService(window: sourceWindow)
        var saved: [CaptureAttachment.Saved] = []
        let save: (CGImage, String, AttachmentAnnotation.Region?, String) throws -> Void = { image, title, region, comment in
            saved.append(try CaptureAttachment.save(image: image, title: title, region: region, comment: comment,
                into: conversation.id, repository: repository))
        }
        controller.show(kind: .window, relativeTo: sourceWindow, service: service, save: save)
        let model = controller.model!, panel = controller.panel!
        let utilityFrame = panel.frame
        panel.zoom(nil); panel.miniaturize(nil); panel.toggleFullScreen(nil)
        try require(panel.frame == utilityFrame && !panel.isMiniaturized && !panel.styleMask.contains(.fullScreen),
            "Capture utility must not maximise, minimise, or enter full screen")
        var resized = utilityFrame; resized.size.width += 20
        panel.setFrame(resized, display: true)
        try require(panel.frame.width == resized.width, "Capture utility must remain resizable")
        panel.setFrame(utilityFrame, display: true)
        try await until("Picker did not finish checking thumbnails") { !model.loadingSources }
        try require(model.sources.map(\.id) == [.window(CGWindowID(sourceWindow.windowNumber))], "Picker retained an empty or tiny helper window")
        try require(service.candidateIDs.contains(.window(CGWindowID(transparentHelper.windowNumber))), "Fixture did not exercise an empty candidate window")
        try require(!service.candidateIDs.contains(.window(CGWindowID(stripHelper.windowNumber))), "Tiny helper window passed source filtering")
        try require(service.candidateIDs.contains(.window(CGWindowID(minimizedHelper.windowNumber))), "Fixture did not exercise a minimized candidate window")
        try require(model.thumbnails.count == 1, "Picker must retain only the usable preview")
        try await render(panel, name: "picker")
        model.select(model.sources[0])
        try await until("Live red frame did not arrive: \(model.error ?? "")") { (sample(model.image)?.redComponent ?? 0) > 0.8 }
        panel.makeKeyAndOrderFront(nil)
        try await until("Preview menu must target live capture when the panel has focus") {
            panel.isKeyWindow && AnnotationCommandsState.shared.owner === controller && AnnotationCommandsState.shared.enabled
        }
        // Move our own source completely outside every connected display. Both
        // an existing stream and a fresh one must still deliver updated pixels.
        let originalFrame = sourceWindow.frame
        let rightEdge = NSScreen.screens.map(\.frame.maxX).max() ?? originalFrame.maxX
        sourceWindow.setFrameOrigin(NSPoint(x: rightEdge + 200, y: originalFrame.minY))
        try require(NSScreen.screens.allSatisfy { !$0.frame.intersects(sourceWindow.frame) }, "Fixture window did not move offscreen")
        sourceWindow.contentView = NSHostingView(rootView: CaptureFixtureSource(color: .blue))
        try await until("Live frame did not follow offscreen source changes") { (sample(model.image)?.blueComponent ?? 0) > 0.8 }
        model.retake()
        try await until("A fresh stream could not capture an offscreen window") { (sample(model.image)?.blueComponent ?? 0) > 0.8 }
        try await render(panel, name: "live")
        // Extra modifiers must not trigger the default shortcut.
        _ = key("r", code: 15, flags: [.command, .shift, .option], panel: panel)
        try require(model.phase == .live, "Annotation shortcut accepted extra modifiers")
        let frozen = model.image
        try require(key("r", code: 15, flags: [.command, .shift], panel: panel), "Annotation shortcut was not handled")
        try require(model.phase == .annotating && model.image === frozen, "Annotation must freeze the displayed frame")
        sourceWindow.contentView = NSHostingView(rootView: CaptureFixtureSource(color: .green))
        try await Task.sleep(for: .milliseconds(250))
        try require(model.image === frozen, "Source updates changed the frozen frame")
        sourceWindow.setFrame(originalFrame, display: true)
        func canvas(in view: NSView) -> ScreenCaptureCanvas? {
            if let canvas = view as? ScreenCaptureCanvas { return canvas }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        guard let canvas = canvas(in: panel.contentView!) else { throw ScreenCaptureFailure(message: "Missing annotation canvas") }
        let rect = canvas.imageRect
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.2)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.75)))
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.75)))
        try await until("Region did not focus the native comment editor") { panel.firstResponder is NSTextView }
        let editor = panel.firstResponder as! NSTextView
        editor.insertText("Move this area to the right", replacementRange: editor.selectedRange())
        try await until("Native comment typing did not update the model") { model.comment == "Move this area to the right" }
        try require(model.region?.isValid == true, "Native region selection must be valid")
        try await render(panel, name: "annotation")
        try require(key("\r", code: 36, flags: .command, panel: panel), "Save shortcut was not handled")
        try require(saved.count == 1, "Annotated capture was not saved")
        try require(saved[0].source != nil && saved[0].attachment.annotation?.comment == "Move this area to the right", "Annotation metadata was lost")
        try require(controller.panel == nil && model.phase == .closed, "Saved capture must close its preview")
        controller.show(kind: .window, relativeTo: sourceWindow, service: service, save: save)
        let plainModel = controller.model!
        let plainPanel = controller.panel!
        try await until("Picker did not reopen") { plainModel.sources.count == 1 }
        plainModel.select(plainModel.sources[0])
        try await until("Retaken frame did not show updated source") { (sample(plainModel.image)?.greenComponent ?? 0) > 0.4 }
        try KeyboardBindings.shared.set(KeyBinding("r", modifiers: [.command, .option]), for: .annotateRegion)
        _ = key("r", code: 15, flags: [.command, .shift], panel: plainPanel)
        try require(plainModel.phase == .live, "Rebound annotation still accepted the old shortcut")
        try require(key("r", code: 15, flags: [.command, .option], panel: plainPanel), "Custom annotation shortcut was not handled")
        try require(plainModel.phase == .annotating, "Custom shortcut did not freeze the preview")
        plainPanel.cancelOperation(nil)
        try await until("Escape did not return to the live preview") { plainModel.canCapture }
        plainModel.capture()
        try require(saved.count == 2 && saved[1].attachment.annotation == nil && saved[1].source == nil, "Plain capture must save exactly one ordinary PNG")
        try require(service.excludedOwnPicker, "The source service did not exclude its picker window")
        controller.show(kind: .window, relativeTo: sourceWindow, service: service, save: save)
        let closingModel = controller.model!
        func closeButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == "Close Preview" { return button }
            return view.subviews.lazy.compactMap { closeButton(in: $0) }.first
        }
        guard let close = closeButton(in: controller.panel!.contentView!) else {
            throw ScreenCaptureFailure(message: "Capture utility is missing its preview close button")
        }
        close.performClick(nil)
        try require(controller.panel == nil && closingModel.phase == .closed, "Preview close button must end the capture session")
        sourceWindow.close()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("workspace"))
    }
}

/// AppKit normally moves titled windows back onto a display. The fixture needs
/// a truly offscreen window to verify desktop-independent capture.
@MainActor private final class CaptureFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct CaptureFixtureSource: View {
    let color: Color
    var body: some View {
        ZStack {
            color
            VStack(alignment: .leading, spacing: 12) {
                Text("A clearer way to share context").font(.system(size: 27, weight: .bold))
                Text("This window belongs to the capture test.").font(.system(size: 17))
                Spacer()
                Text("Live source · Local pixels only").font(.system(size: 13, weight: .medium))
            }.foregroundStyle(.white).padding(35).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

@MainActor private final class FixtureCaptureService: ScreenCaptureProviding {
    let window: NSWindow
    let production = ScreenCaptureService()
    var candidateIDs: Set<ScreenCaptureSource.ID> = []
    var hasPermission: Bool { true }
    var excludedOwnPicker = false
    init(window: NSWindow) { self.window = window }
    func requestPermission() { fatalError("Fixture must never request screen access") }
    func sources(kind: ScreenCaptureKind, excluding: [CGWindowID]) async throws -> [ScreenCaptureSource] {
        excludedOwnPicker = excluding.contains { id in NSApp.windows.contains { $0.windowNumber == Int(id) && $0.identifier?.rawValue == "NoodleScreenCapture" } }
        let sources = production.sources(kind: kind, excluding: excluding, in: try await SCShareableContent.currentProcess)
        candidateIDs = Set(sources.map(\.id))
        return sources
    }
    func filter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.currentProcess
        guard let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw ScreenCaptureFailure(message: "Fixture window unavailable")
        }
        return SCContentFilter(desktopIndependentWindow: source)
    }
    func thumbnail(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> CGImage {
        try await production.thumbnail(for: source, excluding: excluding)
    }
    func feed(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> any ScreenCaptureFeed {
        ScreenCaptureService().feed(filter: try await filter())
    }
}

@main struct CaptureFixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = CaptureFixture(); app.delegate = fixture; app.run()
    }
}
