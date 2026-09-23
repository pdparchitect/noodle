import SwiftUI
import XCTest

@testable import NoodleApplet

@MainActor final class ThumbnailTests: XCTestCase {
    private func image(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }
    /// A card in the library grid gets the width of its column. An aspect-fill preview is wider
    /// than it is tall, and if that width reaches the card the card grows past its column and
    /// draws over its neighbours.
    func testAWidePreviewDoesNotWidenTheCard() {
        let host = NSHostingView(rootView: NoodletThumbnail(image: image(width: 1600, height: 900)))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            host.fittingSize.width, 160,
            "A 16:9 preview must not ask for the 284pt its height implies")
    }
}
