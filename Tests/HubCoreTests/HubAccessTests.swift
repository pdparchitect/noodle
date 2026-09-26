import Foundation
import HubCore
import NoodleCore
import XCTest

@MainActor final class HubAccessTests: XCTestCase {
    private func access() -> (HubAccess, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-access-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (HubAccess(url: url), url)
    }

    func testHubStartsWithAnEmptyDefaultPlanThatNewUsersGet() throws {
        let (access, _) = access()
        XCTAssertEqual(access.plans.map(\.name), ["Default"])
        XCTAssertEqual(access.plans.first?.harnesses, [])
        let user = try access.addUser(named: "Ada")
        XCTAssertEqual(user.plan, HubPlan.defaultID)
        XCTAssertEqual(access.harnesses(for: user), [])
    }

    func testUsersGetTheHarnessesOfTheirPlan() throws {
        let (access, _) = access()
        let codex = HubHarness(provider: .codex, profile: UUID())
        let family = try access.addPlan(named: "Family")
        access.set(codex, included: true, in: family)
        let user = try access.addUser(named: "Ada")
        XCTAssertEqual(access.harnesses(for: user), [])
        access.move(user, to: family)
        XCTAssertEqual(access.harnesses(for: access.users[0]), [codex])
    }

    func testDeletingAPlanMovesItsUsersToDefault() throws {
        let (access, _) = access()
        let family = try access.addPlan(named: "Family")
        let user = try access.addUser(named: "Ada")
        access.move(user, to: family)
        access.delete(family)
        XCTAssertEqual(access.plans.map(\.name), ["Default"])
        XCTAssertEqual(access.users.first?.plan, HubPlan.defaultID)
        access.delete(access.plans[0])
        XCTAssertEqual(access.plans.map(\.name), ["Default"])
    }

    func testDeletedProfilesLeaveEveryPlan() throws {
        let (access, _) = access()
        let profile = UUID()
        access.set(HubHarness(provider: .codex, profile: profile), included: true, in: access.plans[0])
        access.set(HubHarness(provider: .apple, profile: nil), included: true, in: access.plans[0])
        access.removeProfile(profile)
        XCTAssertEqual(access.plans[0].harnesses, [HubHarness(provider: .apple, profile: nil)])
    }

    func testUsersAndPlansSurviveARelaunch() throws {
        let (access, url) = access()
        let family = try access.addPlan(named: "Family")
        access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let user = try access.addUser(named: "Ada")
        access.move(user, to: family)
        let reopened = HubAccess(url: url)
        XCTAssertEqual(reopened.plans, access.plans)
        XCTAssertEqual(reopened.users, access.users)
    }
}
