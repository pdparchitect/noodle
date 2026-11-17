import AppKit
import NoodleCore
import SwiftUI
import XCTest
@testable import Noodle

@MainActor final class GroupMemberPickerLayoutTests: XCTestCase {
    /// Making a member the lead marks it without changing its cell's size, so the others in its row stay put.
    func testMakingALeadDoesNotChangeItsCellsSize() {
        let agent = AgentRecord(displayName: "Brisk Otter")
        func size(isLead: Bool) -> CGSize {
            let cell = GroupMemberCell(agent: agent, isLead: isLead, member: { _ in AnyView(Color.gray.frame(width: 48, height: 48)) },
                                       remove: {})
            return NSHostingView(rootView: cell).fittingSize
        }
        XCTAssertEqual(size(isLead: true), size(isLead: false))
    }
}
