import AppKit
import SwiftUI
import XCTest
import NoodleRuntimeSettings
@testable import Noodle

@MainActor final class PreviewHeaderTests: XCTestCase {
    /// A link or switch in a preview's header takes its own clicks, whether AppKit or SwiftUI draws it; the rest of
    /// the header drags the window.
    func testWhatSitsInAHeaderTakesItsOwnClicks() throws {
        let link = NSHostingView(rootView: Button("Run on Hub") {}.buttonStyle(.plain).font(.system(size: 11, weight: .medium)))
        let frame = AnnotationPreviewFrame(content: NSView(), filename: "Orbit", kindLabel: "Noodlet", accessory: link)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.contentView = frame
        defer { window.close() }
        frame.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(link.frame.width, 0)

        let center = link.convert(NSPoint(x: link.bounds.midX, y: link.bounds.midY), to: frame.superview)
        let hit = try XCTUnwrap(frame.hitTest(center))
        XCTAssertTrue(hit === link || hit.isDescendant(of: link), "\(hit)")

        let title = try XCTUnwrap(frame.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Orbit" })
        let titleHit = frame.hitTest(title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: frame.superview))
        XCTAssertFalse(titleHit === title, "The title drags the window")
    }
}
