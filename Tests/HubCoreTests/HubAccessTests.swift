import AppKit
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

@MainActor final class HubAccessTests: XCTestCase {
    private func access() -> (HubAccess, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-access-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (HubAccess(url: url), url)
    }

    func testSuspendedUserCannotBorrowHarnessesAfterRelaunch() throws {
        let (access, url) = access()
        let harness = HubHarness(provider: .codex, profile: nil)
        access.set(harness, included: true, in: access.plans[0])
        let user = try access.addUser(named: "Ada")
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var users = try XCTUnwrap(stored["users"] as? [[String: Any]])
        users[0]["isSuspended"] = true
        stored["users"] = users
        try JSONSerialization.data(withJSONObject: stored).write(to: url)
        let reopened = HubAccess(url: url)
        XCTAssertFalse(reopened.lends(harness, to: user))
        XCTAssertTrue(reopened.harnesses(for: reopened.users[0]).isEmpty)
        XCTAssertEqual(reopened.users[0].plan, user.plan)
        reopened.setSuspended(false, for: user)
        XCTAssertTrue(reopened.lends(harness, to: user))
        XCTAssertFalse(HubAccess(url: url).users[0].isSuspended)
        reopened.setSuspended(true, for: user)
        XCTAssertTrue(HubAccess(url: url).users[0].isSuspended)
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

    func testADuplicatedPlanKeepsEverySettingUnderANewIDAndName() throws {
        let (access, url) = access()
        let codex = HubHarness(provider: .codex, profile: UUID()), claude = HubHarness(provider: .claudeCode, profile: nil)
        let family = try access.addPlan(named: "Family")
        access.set(codex, included: true, in: family)
        access.set(claude, included: true, in: family)
        access.setModels(["gpt-5-mini"], for: codex, in: family)
        access.setComputerLimit(2, in: family)
        access.setBrowserLimit(3, in: family)
        access.setTokenLimit(HubTokenLimit(tokens: 1_000_000, length: 7, unit: .days), in: family)
        let ada = try access.addUser(named: "Ada"), grace = try access.addUser(named: "Grace")
        access.move(ada, to: family)
        access.move(grace, to: family)
        var changes = 0
        access.onTokenLimitsChange = { changes += 1 }

        let copy = try access.duplicate(family)
        let original = try XCTUnwrap(access.plans.first { $0.id == family.id })
        XCTAssertNotEqual(copy.id, family.id)
        XCTAssertFalse(copy.isDefault)
        XCTAssertEqual(copy.name, "Family Copy")
        XCTAssertEqual(copy.harnesses, [codex, claude])
        XCTAssertEqual(copy.models, [codex: ["gpt-5-mini"]])
        XCTAssertEqual(copy.computerLimit, 2)
        XCTAssertEqual(copy.browserLimit, 3)
        XCTAssertEqual(copy.tokenLimit, HubTokenLimit(tokens: 1_000_000, length: 7, unit: .days))
        XCTAssertEqual(access.plans.map(\.name), ["Default", "Family", "Family Copy"])
        XCTAssertEqual(HubAccess(url: url).plans, access.plans)
        // Nobody moves: everyone stays on the original, whose limits did not change.
        XCTAssertEqual(access.users.map(\.plan), [family.id, family.id])
        XCTAssertEqual(changes, 0)

        // Someone moved to the copy may use exactly what they could before.
        access.move(grace, to: copy)
        let moved = try XCTUnwrap(access.users.first { $0.id == grace.id })
        XCTAssertEqual(moved.plan, copy.id)
        XCTAssertEqual(access.harnesses(for: moved), original.harnesses)
        XCTAssertTrue(access.lends(codex, model: "gpt-5-mini", to: moved))
        XCTAssertFalse(access.lends(codex, model: "gpt-5", to: moved))
        XCTAssertTrue(access.lends(claude, model: "opus", to: moved))
        XCTAssertEqual(access.models(on: codex, for: moved), ["gpt-5-mini"])
        XCTAssertNil(access.models(on: claude, for: moved))
        XCTAssertEqual(access.computerLimit(for: moved), 2)
        XCTAssertEqual(access.browserLimit(for: moved), 3)
        XCTAssertEqual(access.tokenLimit(for: moved), access.tokenLimit(for: ada))
    }

    func testDuplicatingAgainGivesEachCopyItsOwnName() throws {
        let (access, _) = access()
        let family = try access.addPlan(named: "Family")
        XCTAssertEqual(try access.duplicate(family).name, "Family Copy")
        XCTAssertEqual(try access.duplicate(family).name, "Family Copy 2")
        XCTAssertEqual(try access.duplicate(family).name, "Family Copy 3")
        XCTAssertEqual(access.plans.map(\.name), ["Default", "Family", "Family Copy", "Family Copy 2", "Family Copy 3"])
        // The longest name still leaves room for the word.
        let long = try access.addPlan(named: String(repeating: "a", count: ConversationName.maximumLength))
        let copy = try access.duplicate(long)
        XCTAssertEqual(copy.name.count, ConversationName.maximumLength)
        XCTAssertTrue(copy.name.hasSuffix(" Copy"))
    }

    func testTheDefaultPlanCanBeDuplicatedButTheCopyIsNotTheDefault() throws {
        let (access, _) = access()
        let codex = HubHarness(provider: .codex, profile: nil)
        access.set(codex, included: true, in: access.plans[0])
        let user = try access.addUser(named: "Ada")
        let copy = try access.duplicate(access.plans[0])
        XCTAssertFalse(copy.isDefault)
        XCTAssertEqual(copy.name, "Default Copy")
        XCTAssertEqual(copy.harnesses, [codex])
        XCTAssertEqual(access.plans.filter(\.isDefault).count, 1)
        XCTAssertEqual(access.users.first?.plan, HubPlan.defaultID)
        XCTAssertEqual(try access.addUser(named: "Grace").plan, HubPlan.defaultID)
        access.delete(copy)
        XCTAssertEqual(access.plans.map(\.name), ["Default"])
        XCTAssertEqual(access.users.first?.id, user.id)
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

    /// A photo is kept beside the file every check-in rewrites, not in it, and goes with its user.
    func testPicturesSurviveARelaunchAndLeaveWithTheirUser() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-access-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("access.json")
        let access = HubAccess(url: url)
        let user = try access.addUser(named: "Ada")
        let photo = try smallJPEG()
        try access.setAvatar(LinkAvatar(colour: 3, image: photo), for: user)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(photo.base64EncodedString()))

        let reopened = HubAccess(url: url)
        XCTAssertEqual(reopened.avatar(of: user.id), LinkAvatar(colour: 3, imageDigest: LinkPicture.digest(photo)))
        XCTAssertEqual(reopened.picture(of: user.id), photo)

        reopened.remove(user)
        XCTAssertNil(reopened.picture(of: user.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("People").path), [])
    }

    func testAPlanCanLimitTheModelsOfAHarness() throws {
        let (access, url) = access()
        let codex = HubHarness(provider: .codex, profile: nil)
        let family = try access.addPlan(named: "Family")
        access.set(codex, included: true, in: family)
        let user = try access.addUser(named: "Ada")
        access.move(user, to: family)
        XCTAssertNil(access.models(on: codex, for: access.users[0]))
        XCTAssertTrue(access.lends(codex, model: nil, to: user))
        XCTAssertTrue(access.lends(codex, model: "gpt-5", to: user))

        access.setModels(["gpt-5-mini"], for: codex, in: family)
        XCTAssertEqual(access.models(on: codex, for: access.users[0]), ["gpt-5-mini"])
        XCTAssertTrue(access.lends(codex, model: "gpt-5-mini", to: user))
        XCTAssertFalse(access.lends(codex, model: "gpt-5", to: user))
        // A bot without a model runs on the harness default.
        XCTAssertTrue(access.lends(codex, model: nil, to: user))
        XCTAssertEqual(HubAccess(url: url).plans, access.plans)

        access.setModels(nil, for: codex, in: family)
        XCTAssertTrue(access.lends(codex, model: "gpt-5", to: user))
    }

    func testAPlanCanLimitHowManyComputersAndBrowsersEachUserKeeps() throws {
        let (access, url) = access()
        let family = try access.addPlan(named: "Family")
        let user = try access.addUser(named: "Ada")
        access.move(user, to: family)
        XCTAssertNil(access.computerLimit(for: user))
        XCTAssertNil(access.browserLimit(for: user))

        access.setComputerLimit(5, in: family)
        access.setBrowserLimit(10, in: family)
        XCTAssertEqual(access.computerLimit(for: user), 5)
        XCTAssertEqual(access.browserLimit(for: user), 10)
        XCTAssertEqual(HubAccess(url: url).plans, access.plans)

        access.setComputerLimit(nil, in: family)
        XCTAssertNil(access.computerLimit(for: user))
        XCTAssertEqual(access.browserLimit(for: user), 10)
    }

    func testAPlanCanLimitTheTokensEachUserUsesInAPeriod() throws {
        let (access, url) = access()
        let family = try access.addPlan(named: "Family")
        let user = try access.addUser(named: "Ada")
        access.move(user, to: family)
        XCTAssertNil(access.tokenLimit(for: user), "No limit by default")
        var changes = 0
        access.onTokenLimitsChange = { changes += 1 }

        access.setTokenLimit(HubTokenLimit(tokens: 2_000_000, length: 7, unit: .days), in: family)
        XCTAssertEqual(access.tokenLimit(for: user), HubTokenLimit(tokens: 2_000_000, length: 7, unit: .days))
        XCTAssertEqual(access.tokenLimit(for: user)?.period, 7 * 86_400)
        XCTAssertEqual(access.tokenLimit(for: user)?.periodName, "7 days")
        XCTAssertEqual(HubAccess(url: url).plans, access.plans)
        XCTAssertEqual(changes, 1)
        // Moving the user takes them off it at once.
        access.move(user, to: access.plans[0])
        XCTAssertNil(access.tokenLimit(for: user))
        XCTAssertEqual(changes, 2)
        access.move(user, to: family)

        // Nothing is limited to no tokens, or to no time.
        access.setTokenLimit(HubTokenLimit(tokens: 0, length: 0, unit: .months), in: family)
        XCTAssertEqual(access.tokenLimit(for: user), HubTokenLimit(tokens: 1, length: 1, unit: .months))
        XCTAssertEqual(access.tokenLimit(for: user)?.periodName, "month")
        access.setTokenLimit(nil, in: family)
        XCTAssertNil(access.tokenLimit(for: user))
    }

    /// Plans saved before token limits, or by a later Hub with a period this one does not know, have none.
    func testAPlanFromAnotherHubVersionDecodesWithoutATokenLimit() throws {
        let old = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Family","harnesses":[]}"#
        XCTAssertNil(try JSONDecoder().decode(HubPlan.self, from: Data(old.utf8)).tokenLimit)
        let later = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Family","harnesses":[],"tokenLimit":{"tokens":5,"length":1,"unit":"fortnights"}}"#
        let plan = try JSONDecoder().decode(HubPlan.self, from: Data(later.utf8))
        XCTAssertEqual(plan.name, "Family")
        XCTAssertNil(plan.tokenLimit)
    }

    func testAPlanCanLimitTheKindsOfComputerItsUsersMake() throws {
        let (access, url) = access()
        let family = try access.addPlan(named: "Family")
        let ada = try access.addUser(named: "Ada"), bob = try access.addUser(named: "Bob")
        access.move(ada, to: family)
        XCTAssertNil(family.computerTypes, "Every kind by default")
        XCTAssertNil(access.computerTypes(for: ada))
        XCTAssertTrue(access.allowsComputerType("desktop", for: ada))

        access.setComputerTypes(["shell"], in: family)
        XCTAssertEqual(access.computerTypes(for: ada), ["shell"])
        XCTAssertTrue(access.allowsComputerType("shell", for: ada))
        XCTAssertFalse(access.allowsComputerType("desktop", for: ada))
        XCTAssertFalse(access.allowsComputerType(nil, for: ada), "A computer of no named kind slipped past the plan")
        XCTAssertTrue(access.allowsComputerType("desktop", for: bob), "Another plan's users were limited too")
        XCTAssertEqual(HubAccess(url: url).plans, access.plans)
        XCTAssertEqual(try access.duplicate(family).computerTypes, ["shell"])

        access.setComputerTypes(nil, in: family)
        XCTAssertTrue(access.allowsComputerType("desktop", for: ada))
    }

    /// Plans saved before computer types let their users make every kind, so nothing changes until one is turned off.
    func testPlansSavedBeforeComputerTypesAllowEveryKind() throws {
        let old = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Family","harnesses":[],"computerLimit":2}"#
        let plan = try JSONDecoder().decode(HubPlan.self, from: Data(old.utf8))
        XCTAssertNil(plan.computerTypes)
        XCTAssertEqual(plan.computerLimit, 2)
    }

    func testThePersonalMacsOwnerHasNoLimits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-access-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let access = HubAccess(url: url, personal: true)
        access.setComputerLimit(0, in: access.plans[0])
        access.setBrowserLimit(0, in: access.plans[0])
        access.setTokenLimit(HubTokenLimit(tokens: 1), in: access.plans[0])
        access.setComputerTypes(["shell"], in: access.plans[0])
        XCTAssertNil(access.computerLimit(for: access.users[0]))
        XCTAssertNil(access.browserLimit(for: access.users[0]))
        XCTAssertNil(access.tokenLimit(for: access.users[0]))
        XCTAssertNil(access.computerTypes(for: access.users[0]))
        XCTAssertTrue(access.allowsComputerType("desktop", for: access.users[0]))
    }

    func testAHarnessLeavingAPlanTakesItsModelsWithIt() throws {
        let (access, _) = access()
        let profile = UUID()
        let codex = HubHarness(provider: .codex, profile: profile), claude = HubHarness(provider: .claudeCode, profile: nil)
        let plan = access.plans[0]
        access.set(codex, included: true, in: plan)
        access.set(claude, included: true, in: plan)
        access.setModels(["gpt-5"], for: codex, in: plan)
        access.setModels(["opus"], for: claude, in: plan)
        access.removeProfile(profile)
        access.set(claude, included: false, in: plan)
        XCTAssertEqual(access.plans[0].models, [:])
    }

    func testPlansSavedBeforeModelsStillRead() throws {
        let (_, url) = access()
        let json = #"{"users":[],"plans":[{"id":"00000000-0000-0000-0000-000000000000","name":"Default","harnesses":[{"provider":"codex"}]}]}"#
        try Data(json.utf8).write(to: url)
        let access = HubAccess(url: url)
        XCTAssertEqual(access.plans.first?.harnesses, [HubHarness(provider: .codex, profile: nil)])
        XCTAssertEqual(access.plans.first?.models, [:])
    }

    func testUsersCanPairTheirOwnDevicesUnlessTheOwnerTurnsItOff() throws {
        let (access, url) = access()
        let ada = try access.addUser(named: "Ada")
        XCTAssertTrue(ada.canPairDevices)
        access.setCanPairDevices(false, for: ada)
        XCTAssertEqual(HubAccess(url: url).users.first?.canPairDevices, false)
        access.setCanPairDevices(true, for: ada)
        XCTAssertEqual(HubAccess(url: url).users.first?.canPairDevices, true)
    }

    func testUsersSavedBeforePairingCanPairTheirOwnDevices() throws {
        let (_, url) = access()
        let json = #"{"users":[{"id":"\#(UUID())","name":"Ada","plan":"\#(HubPlan.defaultID)"}],"plans":[]}"#
        try Data(json.utf8).write(to: url)
        XCTAssertEqual(HubAccess(url: url).users.first?.canPairDevices, true)
        XCTAssertEqual(HubAccess(url: url).users.first?.isSuspended, false)
    }
}

/// A small JPEG, as devices send pictures.
func smallJPEG() throws -> Data {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
}
