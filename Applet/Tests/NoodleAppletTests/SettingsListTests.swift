import SwiftUI
import XCTest
@testable import NoodleApplet

@MainActor final class SettingsListTests: XCTestCase {
    private func height(rows: Int) -> CGFloat {
        let form = Form { Section { ForEach(0..<rows, id: \.self) { LabeledContent("Row \($0)") { Button("Remove") {} } } } }
            .formStyle(.grouped)
        return NSHostingView(rootView: form.settingsList()).fittingSize.height
    }
    func testLongListsScrollInsteadOfGrowingTheWindow() {
        XCTAssertLessThan(height(rows: 3), 300, "A short list still fits its content")
        XCTAssertEqual(height(rows: 400), 520, "A long list is capped and scrolls")
    }
}
