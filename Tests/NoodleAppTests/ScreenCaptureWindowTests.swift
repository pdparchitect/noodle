import AppKit
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ScreenCaptureWindowTests: XCTestCase {
    private let source = ScreenCaptureSource(id: .window(123), title: "Fixture window", subtitle: "Fixture app")
    private func image() -> CGImage {
        let context = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.blue.cgColor); context.fill(.init(x: 0, y: 0, width: 160, height: 120))
        return context.makeImage()!
    }
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in host.close() }; return host
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < end else { XCTFail("Capture window did not settle"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func preview(_ service: CaptureTestService, save: @escaping (CGImage, String, AttachmentAnnotation.Region?, String) throws -> Void = { _, _, _, _ in }) -> ScreenCapturePreviewController {
        let host = window(), c = ScreenCapturePreviewController()
        addTeardownBlock { @MainActor in
            c.close()
            for feed in service.feeds { feed.startWaiter?.resume(); feed.startWaiter = nil; feed.continuation.finish() }
            for waiter in service.thumbnailWaiters.values { waiter.resume(throwing: CancellationError()) }
            service.thumbnailWaiters.removeAll()
        }
        c.show(kind: .window, relativeTo: host, service: service, present: false, save: save)
        let suite = "capture-window-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        c.panel?.bindings = KeyboardBindings(defaults: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return c
    }
    private func live(_ c: ScreenCapturePreviewController, service: CaptureTestService) async throws -> ScreenCaptureModel {
        let model = try XCTUnwrap(c.model)
        model.select(source)
        try await wait { service.feeds.last?.started == true }
        service.feeds.last?.send(image())
        try await wait { model.canCapture }
        return model
    }
    private func key(_ panel: NSWindow, code: UInt16, text: String, flags: NSEvent.ModifierFlags = .command, repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeatKey, keyCode: code)!
    }

    func testReopeningPickerPreservesOriginalSaveDestinationAndLiveSession() async throws {
        let service = CaptureTestService(); var first = 0, second = 0
        let c = preview(service) { _, _, _, _ in first += 1 }
        let model = try await live(c, service: service), panel = c.panel
        c.show(kind: .screen, relativeTo: window(), service: CaptureTestService(), present: false) { _, _, _, _ in second += 1 }
        XCTAssertTrue(c.panel === panel); XCTAssertTrue(c.model === model)
        XCTAssertEqual(service.feeds.count, 1)
        model.capture()
        XCTAssertEqual(first, 1); XCTAssertEqual(second, 0); XCTAssertNil(c.panel)
        try await wait { service.feeds[0].stops == 1 }
    }

    func testClosingDuringStreamStartupRetiresCallbacksAndStopsLateFeed() async throws {
        let service = CaptureTestService(); service.delayStart = true
        var saves = 0
        let c = preview(service) { _, _, _, _ in saves += 1 }
        let panel = try XCTUnwrap(c.panel), model = try XCTUnwrap(c.model)
        model.select(source)
        try await wait { service.feeds.first?.startWaiter != nil }
        XCTAssertTrue(service.exclusions.contains([CGWindowID(panel.windowNumber)]))
        AnnotationCommandsState.shared.owner = c; AnnotationCommandsState.shared.enabled = true
        c.close()
        service.feeds[0].startWaiter?.resume(); service.feeds[0].startWaiter = nil
        service.feeds[0].send(image())
        try await wait { service.feeds[0].stops == 1 }
        XCTAssertEqual(model.phase, .closed); XCTAssertNil(model.onSave); XCTAssertNil(model.onFinish)
        XCTAssertNil(c.panel); XCTAssertNil(c.model); XCTAssertEqual(saves, 0)
        XCTAssertFalse(AnnotationCommandsState.shared.owner === c)
    }

    func testEscapeRetakesAnnotationThenClosesLiveCapture() async throws {
        let service = CaptureTestService(), c = preview(service)
        let model = try await live(c, service: service), panel = try XCTUnwrap(c.panel)
        c.annotate(); model.region = .init(x: 0, y: 0, width: 0.5, height: 0.5); model.comment = "Draft"
        panel.cancelOperation(nil)
        XCTAssertEqual(model.phase, .loading); XCTAssertNil(model.region); XCTAssertEqual(model.comment, "")
        try await wait { service.feeds.count == 2 && service.feeds[1].started }
        panel.cancelOperation(nil)
        XCTAssertNil(c.panel); XCTAssertEqual(model.phase, .closed)
        try await wait { service.feeds.allSatisfy { $0.stops == 1 } }
    }

    func testKeyboardSaveFailureRetainsAnnotationAndRetryPublishesOnce() async throws {
        let service = CaptureTestService(); var fail = true, saves = 0
        let c = preview(service) { _, _, _, comment in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            XCTAssertEqual(comment, "Keep this draft"); saves += 1
        }
        let model = try await live(c, service: service), panel = try XCTUnwrap(c.panel)
        c.startRegion(); model.region = .init(x: 0.1, y: 0.2, width: 0.4, height: 0.3); model.comment = "Keep this draft"
        let frame = model.image
        XCTAssertTrue(panel.performKeyEquivalent(with: key(panel, code: 36, text: "\r", repeatKey: true)))
        XCTAssertNil(model.error)
        XCTAssertTrue(panel.performKeyEquivalent(with: key(panel, code: 36, text: "\r")))
        XCTAssertNotNil(model.error); XCTAssertTrue(model.image === frame); XCTAssertTrue(model.canSaveAnnotation)
        XCTAssertTrue(c.panel === panel); XCTAssertEqual(saves, 0)
        fail = false
        XCTAssertTrue(panel.performKeyEquivalent(with: key(panel, code: 36, text: "\r")))
        XCTAssertEqual(saves, 1); XCTAssertNil(c.panel)
        model.saveAnnotation(); XCTAssertEqual(saves, 1)
    }

    func testPermissionRetryUsesInjectedServiceAndKeepsPanelOpen() async throws {
        let service = CaptureTestService(); service.hasPermission = false; service.list = [source]; service.preview = image()
        let c = preview(service), model = try XCTUnwrap(c.model)
        XCTAssertTrue(model.needsPermission); XCTAssertEqual(service.sourceRequests, 0)
        model.requestPermission()
        try await wait { !model.loadingSources }
        XCTAssertEqual(service.permissionRequests, 1); XCTAssertEqual(model.sources, [source]); XCTAssertNotNil(c.panel)
    }

    func testDisappearingSourceReturnsToPickerWithoutAcceptingStaleFrame() async throws {
        let service = CaptureTestService(); service.list = [source]; service.preview = image()
        var saves = 0
        let c = preview(service) { _, _, _, _ in saves += 1 }
        let model = try await live(c, service: service)
        service.feeds[0].continuation.finish(throwing: ScreenCaptureFailure(message: "Closed window"))
        try await wait { model.phase == .choosing && !model.loadingSources }
        model.capture()
        XCTAssertFalse(model.canCapture); XCTAssertEqual(saves, 0); XCTAssertEqual(model.sources, [])
        XCTAssertNotNil(c.panel); XCTAssertTrue(model.error?.contains("removed") == true)
    }

    func testCapturePersistsIntoOriginalConversationAfterSelectionChanges() async throws {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        let destination = f.directA.id
        let service = CaptureTestService(), c = preview(service) { image, title, region, comment in
            try f.store.importCapture(image: image, title: title, region: region, comment: comment, into: destination)
        }
        let model = try await live(c, service: service)
        f.store.selectedConversationID = f.directB.id
        model.capture()
        XCTAssertEqual(f.store.pendingAttachments(for: destination).count, 1)
        XCTAssertTrue(f.store.pendingAttachments(for: f.directB.id).isEmpty)
        XCTAssertEqual(try f.repository.loadAttachments(conversationID: destination).count, 1)
        XCTAssertTrue(try f.repository.loadMessages(conversationID: destination).isEmpty)
        XCTAssertNil(c.panel)
    }

    func testDeletedDestinationPreservesCaptureWithoutRecreatingConversation() async throws {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        let destination = f.directA.id
        let service = CaptureTestService(), c = preview(service) { image, title, region, comment in
            try f.store.importCapture(image: image, title: title, region: region, comment: comment, into: destination)
        }
        let model = try await live(c, service: service), frame = model.image
        try f.repository.deleteAgent(f.a)
        model.capture()
        XCTAssertNotNil(model.error); XCTAssertTrue(model.image === frame); XCTAssertNotNil(c.panel)
        XCTAssertTrue(f.store.pendingAttachments(for: destination).isEmpty)
        XCTAssertFalse(try f.repository.loadConversations().contains { $0.id == destination })
    }

    func testNewCaptureIgnoresCloseNotificationFromRetiredPanel() async throws {
        let service = CaptureTestService(), c = preview(service), first = try XCTUnwrap(c.panel)
        c.close()
        c.show(kind: .screen, relativeTo: window(), service: service, present: false) { _, _, _, _ in }
        let current = c.panel
        c.windowWillClose(.init(name: NSWindow.willCloseNotification, object: first))
        XCTAssertTrue(c.panel === current); XCTAssertEqual(c.model?.phase, .choosing)
    }

    func testCanvasDiscardsDragWhenSelectionOrImageChanges() {
        for replaceImage in [false, true] {
            let host = window(), canvas = ScreenCaptureCanvas(frame: .init(x: 0, y: 0, width: 400, height: 300))
            host.contentView = canvas; canvas.image = image(); canvas.selecting = true
            var commits = 0; canvas.onRegion = { _ in commits += 1 }
            func mouse(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: mouse(.leftMouseDown, point: .init(x: 100, y: 100)))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, point: .init(x: 200, y: 200)))
            if replaceImage { canvas.image = image() } else { canvas.selecting = false; canvas.selecting = true }
            canvas.mouseUp(with: mouse(.leftMouseUp, point: .init(x: 200, y: 200)))
            XCTAssertEqual(commits, 0)
            XCTAssertNil(canvas.region)
        }
    }

    func testCanvasCommitsValidDragAndCommandWClosesPicker() throws {
        let host = window(), canvas = ScreenCaptureCanvas(frame: .init(x: 0, y: 0, width: 400, height: 300))
        host.contentView = canvas; canvas.image = image(); canvas.selecting = true
        let rect = canvas.imageRect
        func mouse(_ type: NSEvent.EventType, fraction: CGFloat) -> NSEvent {
            let point = canvas.convert(NSPoint(x: rect.minX + rect.width * fraction, y: rect.minY + rect.height * fraction), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var region: AttachmentAnnotation.Region?
        canvas.onRegion = { region = $0 }
        canvas.mouseDown(with: mouse(.leftMouseDown, fraction: 0.25))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, fraction: 0.75))
        canvas.mouseUp(with: mouse(.leftMouseUp, fraction: 0.75))
        XCTAssertEqual(region?.x ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(region?.width ?? -1, 0.5, accuracy: 0.0001)
        let c = preview(CaptureTestService()), panel = try XCTUnwrap(c.panel)
        XCTAssertTrue(panel.performKeyEquivalent(with: key(panel, code: 13, text: "w")))
        XCTAssertNil(c.panel)
    }
}
