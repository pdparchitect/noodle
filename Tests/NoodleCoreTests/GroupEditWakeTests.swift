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

    /// Save in a group's sheet, in every app, waits for a change; spaces around the words and the members' order
    /// are not one.
    func testAGroupEditChangesItOnlyWhenSomethingDiffers() {
        let first = UUID(), second = UUID()
        var group = BotConversation(displayName: "Team", publicDescription: "Triage", kind: .group, participantIDs: [first, second])
        group.leadID = first
        func changed(name: String = "Team", description: String = "Triage", members: Set<UUID>? = nil,
                     folders: [AgentFolder] = [], lead: UUID?? = .none) -> Bool {
            group.editChanges(name: name, description: description, members: members ?? [first, second], folders: folders,
                              lead: lead ?? first)
        }
        XCTAssertFalse(changed())
        XCTAssertFalse(changed(name: " Team ", description: "Triage\n"))
        XCTAssertTrue(changed(name: "Crew"))
        XCTAssertTrue(changed(description: ""))
        XCTAssertTrue(changed(members: [first]))
        XCTAssertTrue(changed(folders: [AgentFolder(path: "/tmp")]))
        XCTAssertTrue(changed(lead: .some(nil)))
    }
}
