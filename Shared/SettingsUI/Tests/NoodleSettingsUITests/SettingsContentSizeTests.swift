import AppKit
import SwiftUI
import XCTest
@testable import NoodleSettingsUI

@MainActor final class SettingsContentSizeTests: XCTestCase {
    func testTallContentIsCappedAndScrolls() throws {
        let host = NSHostingView(rootView: form(rows: 80).settingsContentSize(width: 400, maxHeight: 300))
        XCTAssertEqual(host.fittingSize.height, 300, accuracy: 0.5)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(find(host, type: NSScrollView.self))
        // The Form's own scroll view gets the capped height, so the rest scrolls.
        XCTAssertEqual(scroll.frame.height, 300, accuracy: 0.5)
    }

    func testShortContentKeepsItsOwnHeight() {
        let short = NSHostingView(rootView: form(rows: 2).settingsContentSize(width: 400, maxHeight: nil)).fittingSize
        let capped = NSHostingView(rootView: form(rows: 2).settingsContentSize(width: 400, maxHeight: 2000)).fittingSize
        XCTAssertLessThan(short.height, 300)
        XCTAssertEqual(capped, short)
        XCTAssertEqual(short.width, 400)
    }

    private func form(rows: Int) -> some View {
        Form { ForEach(0..<rows, id: \.self) { Text("Setting \($0)") } }.formStyle(.grouped)
    }

    private func find<V: NSView>(_ root: NSView, type: V.Type) -> V? {
        if let result = root as? V { return result }
        for child in root.subviews {
            if let result = find(child, type: type) { return result }
        }
        return nil
    }
}
