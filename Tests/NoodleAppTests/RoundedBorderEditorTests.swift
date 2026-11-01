import AppKit
import XCTest
@testable import NoodleRuntimeSettings

@MainActor final class RoundedBorderEditorTests: XCTestCase {
    /// A multi-line editor's bezel never takes first responder, so it must ring itself while the editor has focus.
    func testBezelShowsAFocusRingOnlyWhileFocused() throws {
        _ = NSApplication.shared
        let view = RoundedBorderBezel.BezelView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.layoutSubtreeIfNeeded()
        let ring = try XCTUnwrap(view.subviews.compactMap { $0 as? RoundedBorderBezel.FocusRingView }.first)
        let shape = try XCTUnwrap(ring.layer?.sublayers?.first as? CAShapeLayer)

        XCTAssertEqual(shape.opacity, 0)
        view.focused = true
        XCTAssertEqual(shape.opacity, 1)
        XCTAssertNotNil(shape.animation(forKey: "focus"), "the ring animates in like AppKit's")
        view.focused = false
        XCTAssertEqual(shape.opacity, 0)
    }
}
