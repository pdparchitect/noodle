import Foundation
import NoodleCore
import XCTest

/// Editing a group wakes its bots, in every app, when who is in it or what it is for changed; a new name alone
/// does not.
final class GroupEditWakeTests: XCTestCase {
    func testMembersOrDescriptionWakeAndANameDoesNot() {
        let first = UUID(), second = UUID()
        let group = BotConversation(displayName: "Team", publicDescription: "Triage", kind: .group, participantIDs: [first, second])
        var renamed = group
        renamed.displayName = "Crew"
        XCTAssertFalse(BotConversation.editWakesMembers(from: group, to: renamed))
        XCTAssertFalse(BotConversation.editWakesMembers(
            from: group, to: BotConversation(id: group.id, displayName: "Team", publicDescription: "Triage", kind: .group,
                                             participantIDs: [second, first])), "Same members in another order")
        var described = group
        described.publicDescription = nil
        XCTAssertTrue(BotConversation.editWakesMembers(from: group, to: described))
        XCTAssertTrue(BotConversation.editWakesMembers(
            from: group, to: BotConversation(id: group.id, displayName: "Team", publicDescription: "Triage", kind: .group,
                                             participantIDs: [first])))
    }
}
