import AppKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

@MainActor final class BackgroundDropTargetTests: XCTestCase {
    func testDecorativePreviewAcceptsFileDropsWithoutChangingItsSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundDropTargetTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("picture.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(deviceRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        for x in 0..<16 { for y in 0..<16 { bitmap.setColor(color, atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)

        // Computer uses 150 points; Noodle and Applet use 210 points.
        for height: CGFloat in [150, 210] {
            let state = DropState()
            let host = NSHostingView(rootView: PreviewFixture(state: state, height: height))
            let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 520, height: 640),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close(); window.contentView = nil }
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let preview = try XCTUnwrap(findView(host) { $0.identifier?.rawValue == "preview-frame" })
            let frame = preview.convert(preview.bounds, to: host)
            XCTAssertEqual(frame.height, height, accuracy: 0.5)
            XCTAssertEqual(frame.width, 472, accuracy: 0.5)
            let target = try XCTUnwrap(findView(host) { !$0.registeredDraggedTypes.isEmpty })
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
            let drag = PreviewDragInfo(pasteboard: pasteboard, window: window,
                location: preview.convert(NSPoint(x: 30, y: 30), to: nil), url: source)
            XCTAssertEqual(target.draggingEntered(drag), .copy)
            XCTAssertTrue(target.performDragOperation(drag))
            for _ in 0..<100 where state.file == nil && state.failure == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(state.file?.kind, .image, state.failure ?? "Drop did not reach preview")
            XCTAssertNil(state.failure)
            XCTAssertFalse(state.busy)
        }
    }

    /// ⌘V and the preview's Paste take what was copied while the sheet is open, ahead of the conversation behind it.
    func testPasteTakesACopiedPictureAndIsOffWithNothingUsable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundPasteTargetTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("picture.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<16 { for y in 0..<16 { bitmap.setColor(.systemTeal, atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let general = BackgroundPasteView.pasteboard
        BackgroundPasteView.pasteboard = pasteboard
        defer { BackgroundPasteView.pasteboard = general }

        let state = DropState()
        let host = NSHostingView(rootView: PreviewFixture(state: state, height: 210))
        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 520, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); window.contentView = nil }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(findView(host) { $0 is BackgroundPasteView } as? BackgroundPasteView)
        XCTAssertTrue(window.firstResponder === target, "Paste goes to the sheet, not to the conversation behind it")

        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)
        XCTAssertFalse(target.validateMenuItem(paste), "text can't be a background")
        let menu = try XCTUnwrap(target.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: .init(x: 30, y: 30),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Paste" })
        XCTAssertTrue(item.target === target)
        XCTAssertFalse(target.validateMenuItem(item))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
        XCTAssertTrue(target.validateMenuItem(paste))
        target.paste(nil)
        for _ in 0..<100 where state.file == nil && state.failure == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(state.file?.kind, .image, state.failure ?? "Paste did not reach the preview")
        XCTAssertFalse(state.busy)
    }

    private func findView(_ view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        for child in view.subviews {
            if let found = findView(child, matching: predicate) { return found }
        }
        return predicate(view) ? view : nil
    }
}

@MainActor private final class DropState: ObservableObject {
    @Published var busy = false
    @Published var failure: String?
    @Published var file: PreparedBackgroundFile?
}

private struct PreviewFixture: View {
    @ObservedObject var state: DropState
    let height: CGFloat
    var body: some View {
        VStack(spacing: 20) {
            ConversationBackgroundView(background: .init(preset: .ocean))
                .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 16))
                .backgroundDropTarget(isBusy: $state.busy, failure: $state.failure) { state.file = $0 }
                .background(FrameProbe())
            Spacer()
        }.padding(24).frame(width: 520)
    }
}

private struct FrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .init("preview-frame")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor private final class PreviewDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let url: URL
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, window: NSWindow, location: NSPoint, url: URL) {
        draggingPasteboard = pasteboard; draggingDestinationWindow = window
        draggingLocation = location; self.url = url
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        block(NSDraggingItem(pasteboardWriter: url as NSURL), 0, &stop)
    }
}
