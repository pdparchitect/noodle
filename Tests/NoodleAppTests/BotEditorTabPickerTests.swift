import AppKit
import SwiftUI
import XCTest
@testable import Noodle

@MainActor final class BotEditorTabPickerTests: HiddenViewTests {
    /// Every bot settings tab, Mail included, fits across the sheet without being cut off.
    func testEveryTabFitsTheSheet() {
        XCTAssertEqual(BotEditorTab.allCases.last, .mail)
        let picker = host(BotEditorTabPicker(selection: .constant(.general), harnessIdentifier: ""))
        let needed = picker.fittingSize.width
        XCTAssertLessThanOrEqual(needed, BotSheetLayout.width - 40, "The tabs need \(needed) points.")
    }
}
