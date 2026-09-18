import AppKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

private struct Marker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct Host: View {
    @State var selection = BackgroundSelection()
    @State var busy = false
    @State var failure: String?
    var body: some View {
        VStack(spacing: 20) {
            Color.clear.frame(height: 10).background(Marker(name: "above"))
            BackgroundPicker(selection: $selection, busy: $busy, failure: $failure)
            Color.clear.frame(height: 10).background(Marker(name: "below"))
        }
        .frame(width: 472)
    }
}

@MainActor final class BackgroundPickerTests: XCTestCase {
    func testImportedSelectionPreviewsTheFileAndMatchesNoPreset() throws {
        let file = try PreparedBackgroundFile.prepare(imageData: pngData())
        let selection = BackgroundSelection.imported(file)
        XCTAssertEqual(selection.file, file)
        XCTAssertEqual(selection.background.mediaKind, .image)
        XCTAssertNotNil(selection.background.imageFilename)
        XCTAssertNotEqual(selection.background, ConversationBackground())
        XCTAssertEqual(BackgroundSelection(), BackgroundSelection(background: ConversationBackground(), file: nil))
    }

    /// Editors place the picker directly in their stack: both rows must take the
    /// editor's own spacing, exactly as when each editor declared them inline.
    func testRowsJoinTheEnclosingStackWithItsSpacing() throws {
        let view = NSHostingView(rootView: Host())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 472, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()

        func frame(_ match: (NSView) -> Bool) throws -> NSRect {
            let found = try XCTUnwrap(find(view, matching: match))
            return found.convert(found.bounds, to: view)
        }
        // NSHostingView is flipped, so larger y is lower on screen.
        let above = try frame { $0.identifier?.rawValue == "above" }
        let below = try frame { $0.identifier?.rawValue == "below" }
        let buttons = try frame { $0 is ImageMenuAnchorView }
        // Swatch 48 + gap 6 + caption; the caption height is font-dependent, so bound it.
        let swatches = buttons.minY - 20 - (above.maxY + 20)
        XCTAssertEqual(below.minY, buttons.maxY + 20, accuracy: 0.5, "Buttons row must be a direct child of the stack")
        XCTAssertTrue((64...80).contains(swatches), "Swatch row should sit between two 20-point gaps, got \(swatches)")
        XCTAssertEqual(buttons.minX, 0, accuracy: 0.5)
        XCTAssertEqual(buttons.width, (472 - 8) / 2, accuracy: 0.5)
    }

    private func find(_ view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews { if let match = find(child, matching: predicate) { return match } }
        return nil
    }

    private func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
