#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import HubLink

@MainActor final class ConversationIconGridTests: XCTestCase {
    func testTheListIsTheDefaultOfTwoStyles() {
        XCTAssertEqual(ConversationListStyle.standard, .list)
        XCTAssertEqual(ConversationListStyle.key, "sidebarStyle")
        XCTAssertEqual(ConversationListStyle.allCases.map(\.name), ["As List", "As Icons"])
    }

    /// As many columns of at least 96 points as fit, each row as tall as its tallest picture, every one laid out.
    func testPicturesFillAsManyColumnsAsFitAndEveryRowIsLaidOut() {
        func size(width: CGFloat, count: Int) -> CGSize {
            let grid = ConversationIconGrid {
                ForEach(0..<count, id: \.self) { index in Color.red.frame(height: index == 4 ? 140 : 100) }
            }
            return NSHostingController(rootView: grid).sizeThatFits(in: CGSize(width: width, height: .infinity))
        }
        // 320 points: three columns, so five pictures make two rows, the second as tall as its tallest.
        XCTAssertEqual(size(width: 320, count: 5).height, 100 + 8 + 140)
        // 200 points: two columns, three rows.
        XCTAssertEqual(size(width: 200, count: 5).height, 100 + 8 + 100 + 8 + 140)
        XCTAssertEqual(size(width: 320, count: 0).height, 0)
    }
}
#endif
