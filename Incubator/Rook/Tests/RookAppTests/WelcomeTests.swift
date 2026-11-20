import NoodleCore
import RookCore
import XCTest

/// Rook's first launch, as Noodle's: the welcome is offered to someone with no agents until they leave it,
/// and an account made ready there brings a starter team in a group they share, led by the lead operator.
@MainActor final class WelcomeTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RookWelcome-\(UUID())")
        suite = "RookWelcomeTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testTheWelcomeIsOfferedUntilLeftAndOnlyWithoutAgents() throws {
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        model.offerWelcome(defaults: defaults)
        XCTAssertTrue(model.showsWelcome)
        model.finishWelcome(defaults: defaults)
        XCTAssertFalse(model.showsWelcome)
        model.offerWelcome(defaults: defaults)
        XCTAssertFalse(model.showsWelcome, "Left once, it waits for Help > Welcome")
        model.showWelcome()
        XCTAssertTrue(model.showsWelcome)

        let fresh = UserDefaults(suiteName: suite + "-fresh")!
        defer { fresh.removePersistentDomain(forName: suite + "-fresh") }
        model.finishWelcome(defaults: fresh)
        fresh.removeObject(forKey: RookModel.welcomeDismissedKey)
        _ = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        model.offerWelcome(defaults: fresh)
        XCTAssertFalse(model.showsWelcome, "Someone with agents is not welcomed again")
    }

    func testTheStarterTeamIsMadeOnceInAGroupLedByTheLeadOperator() throws {
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let (team, group) = try XCTUnwrap(model.createStarterTeamIfFirst(on: .codex))
        XCTAssertEqual(team.count, RookStarterTeam.members.count)
        XCTAssertEqual(team.map(\.publicDescription), RookStarterTeam.members.map(\.publicDescription))
        XCTAssertTrue(team.allSatisfy { $0.harnessIdentifier == HarnessProvider.codex.rawValue })
        XCTAssertEqual(Set(team.map(\.displayName)).count, team.count)
        XCTAssertEqual(group.displayName, RookStarterTeam.groupName)
        XCTAssertEqual(Set(group.participantIDs), Set(team.map(\.id)))
        XCTAssertEqual(group.lead, team.first?.id)
        XCTAssertNil(model.mission(group.id), "A group, not an Mission")
        XCTAssertNil(try model.createStarterTeamIfFirst(on: .codex), "Only for someone with no agents yet")
    }
}
