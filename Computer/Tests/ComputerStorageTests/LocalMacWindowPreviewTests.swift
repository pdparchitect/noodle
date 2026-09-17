import AppKit
import LocalMacCore
import XCTest
@testable import NoodleComputer

@MainActor final class LocalMacWindowPreviewTests: XCTestCase {
    private static let window = LocalMacWindow(id: 42, pid: 100, title: "Document", application: "Editor")
    private static let second = LocalMacWindow(id: 43, pid: 100, title: "Another Document", application: "Editor")

    private func png(_ color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<10 { for x in 0..<20 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8((rgb.redComponent * 255).rounded())
            pixels[offset + 1] = UInt8((rgb.greenComponent * 255).rounded())
            pixels[offset + 2] = UInt8((rgb.blueComponent * 255).rounded())
            pixels[offset + 3] = 255
        } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testMultiplePreviewsRouteFramesInputAndClosureIndependently() async throws {
        let desktop = try png(.blue), focused = try png(.red), sibling = try png(.green)
        let input = Pipe(), output = Pipe(), previewClosed = expectation(description: "preview stopped")
        let inputReceived = expectation(description: "input uses displayed geometry")
        let siblingInput = expectation(description: "sibling input survives another preview's failure")
        let window = Self.window, second = Self.second
        let helper = Task.detached { () throws -> [LocalMacRequest] in
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var requests: [LocalMacRequest] = [], active: [UInt32: UUID] = [:]
            func send(_ reply: LocalMacReply) throws { try LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting) }
            while let data = try LocalMacWire.read(input.fileHandleForReading) {
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                try request.validate(); requests.append(request)
                var reply = LocalMacReply(id: request.id)
                if request.operation == .status || request.operation == .stream {
                    var status = LocalMacStatus(screenCapture: true, accessibility: true, postEvents: true, display: .init())
                    status.displayID = 99; status.focusedWindow = window; reply.status = status
                }
                if request.operation == .windowList { reply.windows = [window, second] }
                if request.operation == .stream {
                    var frame = LocalMacReply(); frame.frame = true; frame.data = desktop
                    try send(frame)
                }
                if request.operation == .windowPreview, request.enabled == true {
                    let target = request.window!, previous = active[target.id]
                    active[target.id] = request.previewID
                    var frame = LocalMacReply(); frame.frame = true; frame.data = target.id == window.id ? focused : sibling
                    frame.windowFrame = .init(previewID: request.previewID!, bounds: CGRect(x: 800, y: 300, width: 1000, height: 500), width: 2000, height: 1000)
                    try send(frame)
                    frame.windowFrame?.previewID = UUID(); frame.data = desktop
                    try send(frame)
                    if let previous {
                        frame.windowFrame?.previewID = previous
                        try send(frame)
                        var ended = LocalMacReply(error: "Old stream ended"); ended.previewID = previous
                        try send(ended)
                    }
                }
                if let event = request.input, event.kind == .keyDown {
                    if event.key == 0 { inputReceived.fulfill() }
                    else if event.key == 1 { reply.error = "First window lost focus" }
                    else if event.key == 2 { siblingInput.fulfill() }
                }
                if request.operation == .terminalRead {
                    var ended = LocalMacReply(error: "Window closed"); ended.previewID = active[window.id]
                    try send(ended)
                }
                if request.operation == .windowPreview, request.enabled == false {
                    // Frames and end messages already on the wire cannot affect siblings.
                    var frame = LocalMacReply(); frame.frame = true; frame.data = desktop
                    frame.windowFrame = .init(previewID: request.previewID!, bounds: .zero, width: 20, height: 10)
                    try send(frame)
                    var ended = LocalMacReply(error: "Old stream ended"); ended.previewID = request.previewID
                    try send(ended)
                    previewClosed.fulfill()
                }
                try send(reply)
            }
            return requests
        }
        let runtime = LocalMacComputer(displayIDs: { [2] }, presentsWindows: false)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        await runtime.openWindowPreview()
        let first = try XCTUnwrap(runtime.windowPreviews.values.first)
        await runtime.openWindowPreview(window: second)
        let other = try XCTUnwrap(runtime.windowPreviews.values.first { $0.window.id == second.id })
        XCTAssertEqual(runtime.windowPreviews.count, 2)
        XCTAssertEqual(runtime.latestFrame, desktop)
        XCTAssertNotEqual(first.image?.tiffRepresentation, other.image?.tiffRepresentation)
        let geometry = try XCTUnwrap(first.geometry)
        XCTAssertEqual(geometry.width, 2000)
        XCTAssertEqual(first.image?.tiffRepresentation, NSImage(data: focused)?.tiffRepresentation)
        XCTAssertEqual(other.image?.tiffRepresentation, NSImage(data: sibling)?.tiffRepresentation)
        // Reopening, renaming, and Open All must reuse both identities.
        var renamed = window; renamed.title = "Renamed document"
        await runtime.openWindowPreview(window: renamed)
        await runtime.openAllWindowPreviews()
        XCTAssertEqual(Set(runtime.windowPreviews.keys), [first.id, other.id])
        let surface = LocalMacImageView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        surface.runtime = runtime; surface.previewID = first.id
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        runtime.windowPreviews[first.id]?.geometry?.geometryID = UUID()
        surface.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)))
        await fulfillment(of: [inputReceived], timeout: 5)
        var failing = LocalMacInput(.keyDown); failing.key = 1
        failing.previewID = first.id; failing.geometryID = geometry.geometryID
        var succeeding = LocalMacInput(.keyDown); succeeding.key = 2
        succeeding.previewID = other.id; succeeding.geometryID = other.geometry?.geometryID
        runtime.send(failing); runtime.send(succeeding)
        await fulfillment(of: [siblingInput], timeout: 5)
        XCTAssertNil(runtime.error)
        _ = try await runtime.call(.init(.terminalRead))
        XCTAssertNil(runtime.windowPreviews[first.id])
        XCTAssertNotNil(runtime.windowPreviews[other.id])
        await fulfillment(of: [previewClosed], timeout: 5)
        _ = try await runtime.call(.init(.status))
        XCTAssertEqual(runtime.windowPreviews.count, 1)
        XCTAssertEqual(runtime.windowPreviews[other.id]?.image?.tiffRepresentation, other.image?.tiffRepresentation)
        XCTAssertTrue(runtime.isConnected); XCTAssertNil(runtime.error)
        await runtime.openAllWindowPreviews()
        XCTAssertEqual(runtime.windowPreviews.count, 2)
        let reopened = try XCTUnwrap(runtime.windowPreviews.values.first { $0.window.id == window.id })
        XCTAssertNotEqual(reopened.id, first.id)
        XCTAssertNotNil(reopened.geometry); XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.image?.tiffRepresentation, first.image?.tiffRepresentation)
        XCTAssertEqual(runtime.latestFrame, desktop)
        runtime.close()
        XCTAssertTrue(runtime.windowPreviews.isEmpty)
        let requests = try await helper.value
        XCTAssertEqual(requests.filter { $0.operation == .windowPreview }.map(\.enabled), [true, true, false, true])
        let key = requests.first { $0.input?.kind == .keyDown }?.input
        XCTAssertEqual(key?.geometryID, geometry.geometryID)
        XCTAssertEqual(key?.previewID, first.id)
        XCTAssertTrue(requests.contains { $0.input?.kind == .reset && $0.input?.previewID == first.id })
    }
    func testMotionAndScopedResetsKeepOtherWindowsQueuedInput() {
        var queue = LocalMacInputQueue()
        var first = LocalMacInput(.move); first.previewID = UUID(); first.geometryID = UUID()
        var second = first; second.previewID = UUID(); second.geometryID = UUID()
        XCTAssertTrue(queue.append(first)); XCTAssertTrue(queue.append(second))
        XCTAssertTrue(queue.append(.init(.keyDown)))
        var reset = LocalMacInput(.reset); reset.previewID = first.previewID
        XCTAssertTrue(queue.append(reset))
        XCTAssertEqual(queue.next()?.previewID, second.previewID)
        XCTAssertEqual(queue.next()?.kind, .keyDown)
        XCTAssertEqual(queue.next()?.previewID, first.previewID)
        XCTAssertNil(queue.next())
        XCTAssertTrue(queue.append(first))
        var newGeometry = first; newGeometry.geometryID = UUID()
        XCTAssertTrue(queue.append(newGeometry))
        XCTAssertEqual(queue.next()?.geometryID, first.geometryID)
        XCTAssertEqual(queue.next()?.geometryID, newGeometry.geometryID)
    }
    func testQueuedFocusAndBulkOpenDoNotRunDuringShutdown() async throws {
        let input = Pipe(), output = Pipe(), window = Self.window
        let helper = Task.detached { () throws -> [LocalMacOperation] in
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var operations: [LocalMacOperation] = []
            while let data = try LocalMacWire.read(input.fileHandleForReading) {
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                operations.append(request.operation)
                var reply = LocalMacReply(id: request.id)
                var status = LocalMacStatus(screenCapture: true, accessibility: true, postEvents: true, display: .init())
                status.displayID = 99; status.focusedWindow = window; reply.status = status
                try LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting)
            }
            return operations
        }
        let runtime = LocalMacComputer(displayIDs: { [2] }, presentsWindows: false)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        runtime.expectDisconnect(true)
        await runtime.openWindowPreview()
        await runtime.openAllWindowPreviews()
        XCTAssertTrue(runtime.windowPreviews.isEmpty)
        runtime.close()
        let operations = try await helper.value
        XCTAssertEqual(operations, [.status, .stream])
    }
    func testIndependentNativeWindowsCloseOnlyTheirOwnPreviews() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let runtime = LocalMacComputer()
        let desktop = NSImage(data: try png(.blue))
        runtime.image = desktop
        var first = LocalMacWindowPreview(window: Self.window)
        first.image = NSImage(data: try png(.red))
        first.geometry = .init(previewID: first.id, bounds: CGRect(x: 300, y: 200, width: 700, height: 400), width: 1400, height: 800)
        let second = LocalMacWindowPreview(window: Self.second)
        runtime.windowPreviews = [first.id: first, second.id: second]
        let presenter = runtime.windowPresenter
        presenter.show(first.id, bringToFront: false)
        presenter.show(second.id, bringToFront: false)
        let firstWindow = try XCTUnwrap(presenter.windows[first.id])
        let secondWindow = try XCTUnwrap(presenter.windows[second.id])
        XCTAssertNil(firstWindow.parent)
        XCTAssertFalse(firstWindow is NSPanel)
        XCTAssertEqual(firstWindow.title, "Document")
        XCTAssertTrue(firstWindow.styleMask.contains(.resizable))
        presenter.show(first.id, bringToFront: false)
        XCTAssertEqual(presenter.windows.count, 2)
        XCTAssertTrue(presenter.windows[first.id] === firstWindow)
        firstWindow.close()
        XCTAssertNil(runtime.windowPreviews[first.id])
        XCTAssertNotNil(runtime.windowPreviews[second.id])
        XCTAssertNil(presenter.windows[first.id])
        XCTAssertTrue(secondWindow.isVisible)
        XCTAssertTrue(runtime.image === desktop)
        runtime.close()
        XCTAssertTrue(runtime.windowPreviews.isEmpty)
        XCTAssertTrue(presenter.windows.isEmpty)
        XCTAssertFalse(secondWindow.isVisible)
    }
    func testTilesFitWithoutOverlapOnOffsetLandscapeAndPortraitScreens() {
        let screens = [CGRect(x: 0, y: 40, width: 1024, height: 700),
                       CGRect(x: -3440, y: 30, width: 3440, height: 1370),
                       CGRect(x: 1440, y: -500, width: 900, height: 1540)]
        for screen in screens {
            for count in 1...LocalMacWindowCaptureLimits.maximumWindows {
                let frames = LocalMacWindowLayout.frames(count: count, in: screen)
                XCTAssertEqual(frames.count, count)
                for (index, frame) in frames.enumerated() {
                    XCTAssertTrue(screen.contains(frame), "\(count) tiles: \(frame) outside \(screen)")
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                    for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
                }
            }
        }
        XCTAssertTrue(LocalMacWindowLayout.frames(count: 0, in: screens[0]).isEmpty)
    }
    func testNativeTilesSurviveDelayedFramesAndCanBeArrangedAgain() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let runtime = LocalMacComputer()
        defer { runtime.close() }
        let first = LocalMacWindowPreview(window: Self.window)
        let second = LocalMacWindowPreview(window: Self.second)
        runtime.windowPreviews = [first.id: first, second.id: second]
        let presenter = runtime.windowPresenter
        presenter.show(first.id, bringToFront: false)
        presenter.show(second.id, bringToFront: false)
        let firstWindow = try XCTUnwrap(presenter.windows[first.id])
        let secondWindow = try XCTUnwrap(presenter.windows[second.id])
        let firstFrame = firstWindow.frame, secondFrame = secondWindow.frame
        XCTAssertFalse(firstFrame.intersects(secondFrame))
        let screen = try XCTUnwrap(firstWindow.screen?.visibleFrame)
        XCTAssertTrue(screen.contains(firstFrame)); XCTAssertTrue(screen.contains(secondFrame))
        // Both first frames can arrive after the entire batch has been opened.
        for id in [second.id, first.id] {
            runtime.windowPreviews[id]?.geometry = .init(previewID: id,
                bounds: CGRect(x: 0, y: 0, width: 2400, height: 1600), width: 2400, height: 1600)
            presenter.sync(id)
        }
        XCTAssertEqual(firstWindow.frame, firstFrame); XCTAssertEqual(secondWindow.frame, secondFrame)
        // A repeat individual open preserves a manual arrangement; bulk open restores tiles.
        firstWindow.setFrame(secondFrame, display: false)
        presenter.show(first.id, bringToFront: false)
        XCTAssertEqual(firstWindow.frame, secondFrame)
        presenter.arrange(restoreMinimized: true)
        XCTAssertEqual(firstWindow.frame, firstFrame); XCTAssertEqual(secondWindow.frame, secondFrame)
        firstWindow.close()
        let replacement = LocalMacWindowPreview(window: Self.window)
        runtime.windowPreviews[replacement.id] = replacement
        presenter.show(replacement.id, bringToFront: false)
        XCTAssertEqual(presenter.windows.count, 2)
        XCTAssertFalse(try XCTUnwrap(presenter.windows[replacement.id]).frame.intersects(secondWindow.frame))
    }
    func testSingleWindowMovedBeforeFirstFrameKeepsItsFrame() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let runtime = LocalMacComputer()
        defer { runtime.close() }
        let preview = LocalMacWindowPreview(window: Self.window)
        runtime.windowPreviews[preview.id] = preview
        let presenter = runtime.windowPresenter
        presenter.show(preview.id, bringToFront: false)
        let window = try XCTUnwrap(presenter.windows[preview.id])
        window.setFrame(window.frame.offsetBy(dx: 24, dy: -24), display: false)
        let moved = window.frame
        runtime.windowPreviews[preview.id]?.geometry = .init(previewID: preview.id,
            bounds: CGRect(x: 0, y: 0, width: 2400, height: 1600), width: 2400, height: 1600)
        presenter.sync(preview.id)
        XCTAssertEqual(window.frame, moved)
    }
}
