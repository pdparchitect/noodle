import AppKit
import LocalMacCore
import XCTest
@testable import NoodleComputer

@MainActor final class LocalMacWindowPreviewTests: XCTestCase {
    private static let window = LocalMacWindow(id: 42, pid: 100, title: "Document", application: "Editor")

    private func png(_ color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<10 { for x in 0..<20 { bitmap.setColor(color, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testPreviewFramesAndLateRepliesNeverReplaceTheDesktop() async throws {
        let desktop = try png(.blue), focused = try png(.red), old = try png(.green)
        let input = Pipe(), output = Pipe(), previewClosed = expectation(description: "preview stopped")
        let inputReceived = expectation(description: "input uses displayed geometry")
        let window = Self.window
        let helper = Task.detached { () throws -> [LocalMacRequest] in
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var requests: [LocalMacRequest] = []
            var activePreview: UUID?
            func send(_ reply: LocalMacReply) throws { try LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting) }
            while let data = try LocalMacWire.read(input.fileHandleForReading) {
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                try request.validate(); requests.append(request)
                var reply = LocalMacReply(id: request.id)
                if request.operation == .status || request.operation == .stream {
                    var status = LocalMacStatus(screenCapture: true, accessibility: true, postEvents: true, display: .init())
                    status.displayID = 99; status.focusedWindow = window; reply.status = status
                }
                if request.operation == .stream {
                    var frame = LocalMacReply(); frame.frame = true; frame.data = desktop
                    try send(frame)
                }
                if request.operation == .windowPreview, request.enabled == true {
                    activePreview = request.previewID
                    var frame = LocalMacReply(); frame.frame = true; frame.data = focused
                    frame.windowFrame = .init(previewID: request.previewID!, bounds: CGRect(x: 800, y: 300, width: 1000, height: 500), width: 2000, height: 1000)
                    try send(frame)
                    frame.windowFrame?.previewID = UUID(); frame.data = old
                    try send(frame)
                }
                if request.operation == .input, request.input?.previewID != nil { inputReceived.fulfill() }
                if request.operation == .terminalRead {
                    var ended = LocalMacReply(error: "Window closed"); ended.previewID = activePreview
                    try send(ended)
                }
                if request.operation == .windowPreview, request.enabled == false {
                    // Frames already queued on the wire can arrive after Close.
                    var frame = LocalMacReply(); frame.frame = true; frame.data = old
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
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        await runtime.openWindowPreview()
        XCTAssertEqual(runtime.latestFrame, desktop)
        XCTAssertEqual(runtime.windowPreview?.window, window)
        let geometry = try XCTUnwrap(runtime.windowPreview?.geometry)
        XCTAssertEqual(geometry.width, 2000)
        XCTAssertEqual(runtime.windowPreview?.image?.tiffRepresentation, NSImage(data: focused)?.tiffRepresentation)
        let surface = LocalMacImageView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        surface.runtime = runtime; surface.preview = true
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        // Arrival precedes the next draw: input must still refer to the pixels
        // actually presented, not to this newer geometry in the model.
        runtime.windowPreview?.geometry?.geometryID = UUID()
        surface.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)))
        await fulfillment(of: [inputReceived], timeout: 5)
        _ = try await runtime.call(.init(.terminalRead))
        XCTAssertEqual(runtime.windowPreview?.error, "Window closed")
        XCTAssertNil(runtime.windowPreview?.geometry)
        XCTAssertTrue(runtime.isConnected); XCTAssertEqual(runtime.latestFrame, desktop)
        runtime.closeWindowPreview()
        await fulfillment(of: [previewClosed], timeout: 5)
        _ = try await runtime.call(.init(.status)) // drain preceding frame/error messages
        XCTAssertNil(runtime.windowPreview); XCTAssertEqual(runtime.latestFrame, desktop)
        XCTAssertTrue(runtime.isConnected); XCTAssertNil(runtime.error)
        runtime.close()
        let requests = try await helper.value
        XCTAssertEqual(requests.filter { $0.operation == .windowPreview }.map(\.enabled), [true, false])
        XCTAssertEqual(requests.first { $0.input?.previewID != nil }?.input?.geometryID, geometry.geometryID)
        XCTAssertTrue(requests.contains { $0.operation == .input && $0.input?.kind == .reset })
    }
    func testMotionCoalescingDoesNotMixDesktopAndPanelGeometry() {
        var queue = LocalMacInputQueue()
        var first = LocalMacInput(.move); first.previewID = UUID(); first.geometryID = UUID()
        var second = first; second.geometryID = UUID()
        XCTAssertTrue(queue.append(first)); XCTAssertTrue(queue.append(second))
        XCTAssertTrue(queue.append(.init(.move)))
        XCTAssertEqual(queue.next()?.geometryID, first.geometryID)
        XCTAssertEqual(queue.next()?.geometryID, second.geometryID)
        XCTAssertNil(queue.next()?.previewID)
    }
    func testQueuedFocusDoesNotOpenDuringShutdown() async throws {
        let input = Pipe(), output = Pipe()
        let window = Self.window
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
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        runtime.expectDisconnect(true)
        await runtime.openWindowPreview()
        XCTAssertNil(runtime.windowPreview)
        runtime.close()
        let operations = try await helper.value
        XCTAssertEqual(operations, [.status, .stream])
    }
    func testPanelTracksItsViewerAndClosesWithoutChangingDesktopImage() throws {
        _ = NSApplication.shared
        let runtime = LocalMacComputer()
        let desktop = NSImage(data: try png(.blue))
        runtime.image = desktop
        runtime.windowPreview = .init(window: Self.window)
        let id = try XCTUnwrap(runtime.windowPreview?.id)
        runtime.windowPreview?.image = NSImage(data: try png(.red))
        runtime.windowPreview?.geometry = .init(previewID: id, bounds: CGRect(x: 300, y: 200, width: 700, height: 400), width: 1400, height: 800)
        let parent = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let coordinator = LocalMacWindowPreviewPresenter.Coordinator(runtime: runtime)
        coordinator.sync(parent: parent, active: true)
        let panel = try XCTUnwrap(coordinator.panel)
        XCTAssertTrue(panel.parent === parent)
        XCTAssertEqual(panel.title, "Document")
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertTrue(runtime.image === desktop)
        panel.close()
        XCTAssertNil(runtime.windowPreview)
        XCTAssertNil(coordinator.panel)
        XCTAssertTrue(runtime.image === desktop)
        runtime.windowPreview = .init(window: Self.window)
        coordinator.sync(parent: parent, active: true)
        parent.close()
        XCTAssertNil(runtime.windowPreview)
        XCTAssertNil(coordinator.panel)
    }
}
