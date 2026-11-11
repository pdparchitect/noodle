import Foundation
import HubCore
import NoodleCore
@testable import ServerCore
import XCTest

/// The file is what the server's users and plans are: starting makes the Hub's records match it.
@MainActor final class ServerAccessTests: XCTestCase {
    private var root: URL!
    private var profiles: HarnessProfileStore { HarnessProfileStore(root: root) }

    private func access() -> HubAccess {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        return HubAccess(url: root.appendingPathComponent("access.json"))
    }

    private func apply(_ configuration: ServerConfiguration, to access: HubAccess) throws {
        try ServerAccess.apply(configuration, to: access, profiles: profiles)
    }

    private let first = """
    plans:
      Family:
        harnesses: [claude-code, codex]
        models:
          claude-code: [sonnet]
        tokens:
          limit: 1000
          per: day
      Guests:
        harnesses: [codex]
    users:
      Ada:
        plan: Family
        admin: true
        pair-devices: true
      Bob:
        plan: Guests
    """

    func testStartingGivesTheHubTheFilesPlansAndUsers() throws {
        let access = access()
        try apply(try ServerConfiguration(yaml: first), to: access)

        let family = try XCTUnwrap(access.plans.first { $0.name == "Family" })
        let claude = HubHarness(provider: .claudeCode, profile: nil), codex = HubHarness(provider: .codex, profile: nil)
        XCTAssertEqual(family.harnesses, [claude, codex])
        XCTAssertEqual(family.models, [claude: ["sonnet"]])
        XCTAssertEqual(family.tokenLimit, TokenLimit(tokens: 1000, length: 1, unit: .days))
        let guests = try XCTUnwrap(access.plans.first { $0.name == "Guests" })
        XCTAssertEqual(guests.harnesses, [codex])
        XCTAssertNil(guests.tokenLimit)

        let ada = try XCTUnwrap(access.users.first { $0.name == "Ada" })
        XCTAssertEqual(ada.plan, family.id)
        XCTAssertTrue(ada.isAdmin)
        XCTAssertTrue(ada.canPairDevices)
        let bob = try XCTUnwrap(access.users.first { $0.name == "Bob" })
        XCTAssertEqual(bob.plan, guests.id)
        XCTAssertFalse(bob.isAdmin)
        XCTAssertFalse(bob.canPairDevices)
    }

    /// Editing the file and starting again changes the same records: users keep who they are and their
    /// devices, one left out is suspended with their data kept, and a plan left out is gone.
    func testStartingAgainFollowsTheEditedFile() throws {
        let access = access()
        try apply(try ServerConfiguration(yaml: first), to: access)
        let ada = try XCTUnwrap(access.users.first { $0.name == "Ada" })
        let bob = try XCTUnwrap(access.users.first { $0.name == "Bob" })

        try apply(try ServerConfiguration(yaml: """
        plans:
          Family:
            harnesses: [codex]
        users:
          Ada:
            plan: Family
        """), to: access)

        let family = try XCTUnwrap(access.plans.first { $0.name == "Family" })
        XCTAssertEqual(family.harnesses, [HubHarness(provider: .codex, profile: nil)])
        XCTAssertEqual(family.models, [:])
        XCTAssertNil(family.tokenLimit)
        XCTAssertNil(access.plans.first { $0.name == "Guests" })
        XCTAssertEqual(access.plans.count, 2, "only Default and Family")

        let adaNow = try XCTUnwrap(access.users.first { $0.id == ada.id })
        XCTAssertFalse(adaNow.isAdmin)
        XCTAssertFalse(adaNow.canPairDevices)
        XCTAssertFalse(adaNow.isSuspended)
        let bobNow = try XCTUnwrap(access.users.first { $0.id == bob.id })
        XCTAssertTrue(bobNow.isSuspended)
        XCTAssertEqual(bobNow.plan, HubPlan.defaultID)

        // Back in the file, Bob is the same user again.
        try apply(try ServerConfiguration(yaml: "users:\n  Bob: {}\n"), to: access)
        XCTAssertEqual(access.users.first { $0.name == "Bob" }?.id, bob.id)
        XCTAssertEqual(access.users.first { $0.id == bob.id }?.isSuspended, false)
    }

    func testTheDefaultPlanIsSetByItsName() throws {
        let access = access()
        try apply(try ServerConfiguration(yaml: "plans:\n  Default:\n    harnesses: [codex]\nusers:\n  Ada: {}\n"), to: access)
        let plan = try XCTUnwrap(access.plans.first(where: \.isDefault))
        XCTAssertEqual(plan.harnesses, [HubHarness(provider: .codex, profile: nil)])
        XCTAssertEqual(access.users.first?.plan, HubPlan.defaultID)
    }

    /// Starting with the file unchanged changes nothing.
    func testStartingTwiceChangesNothing() throws {
        let access = access()
        let configuration = try ServerConfiguration(yaml: first)
        try apply(configuration, to: access)
        let (plans, users) = (access.plans, access.users)
        try apply(configuration, to: access)
        XCTAssertEqual(access.plans, plans)
        XCTAssertEqual(access.users, users)
    }

    /// Each profile in the file is one of the Hub's harness profiles, with its own login, and plans lend
    /// it by name; starting again keeps the same profile, so its login stays signed in.
    func testPlansLendTheProfilesInTheFile() throws {
        let access = access()
        let configuration = try ServerConfiguration(yaml: """
        harnesses:
          claude-code:
            path: /opt/claude
            profiles: [Work, Family]
        plans:
          Family:
            harnesses: [claude-code, claude-code/Family]
            models:
              claude-code: [sonnet]
        """)
        try apply(configuration, to: access)
        let made = try profiles.load()
        XCTAssertEqual(Set(made.map(\.displayName)), ["Work", "Family"])
        XCTAssertEqual(Set(made.map(\.provider)), [.claudeCode])
        let family = try XCTUnwrap(made.first { $0.displayName == "Family" })
        let plan = try XCTUnwrap(access.plans.first { $0.name == "Family" })
        let own = HubHarness(provider: .claudeCode, profile: nil), lent = HubHarness(provider: .claudeCode, profile: family.id)
        XCTAssertEqual(plan.harnesses, [own, lent])
        XCTAssertEqual(plan.models, [own: ["sonnet"], lent: ["sonnet"]])

        try apply(configuration, to: access)
        XCTAssertEqual(try profiles.load(), made)
    }
}
