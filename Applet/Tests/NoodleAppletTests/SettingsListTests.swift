import SwiftUI
import XCTest
@testable import NoodleApplet

@MainActor final class SettingsListTests: XCTestCase {
    private func height(rows: Int) -> CGFloat {
        let panel = SettingsListPanel(empty: "None", isEmpty: rows == 0) {
            ForEach(0..<rows, id: \.self) { Text("Row \($0)").frame(height: 44) }
        }
        let host = NSHostingView(rootView: panel.frame(width: 580))
        host.frame = CGRect(x: 0, y: 0, width: 580, height: 2000)
        host.layoutSubtreeIfNeeded()
        // The panel measures its content, then settles on the next update.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
    func testLongListsScrollInsteadOfGrowingTheWindow() {
        XCTAssertEqual(height(rows: 2), 88 + 40, "A short list fits its rows plus the panel's padding")
        XCTAssertEqual(height(rows: 400), 430 + 40, "A long list stops at the panel's height and scrolls")
    }
}
