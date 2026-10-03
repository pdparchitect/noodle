import Foundation
@testable import HubCore
import HubLink
import NoodleCore
import XCTest

/// What an admin may do from a device, checked rule by rule: every refusal here is a way in.
@MainActor final class HubAdminTests: XCTestCase {
    private struct Fixture {
        let access: HubAccess
        let url: URL
        let admin: HubUser
        let ada: HubUser
        let family: HubPlan
    }

    private func fixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-admin-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let access = HubAccess(url: url)
        let admin = try access.addUser(named: "Grace")
        access.setAdmin(true, for: admin)
        let ada = try access.addUser(named: "Ada")
        let family = try access.addPlan(named: "Family")
        return Fixture(access: access, url: url, admin: try XCTUnwrap(access.users.first { $0.id == admin.id }), ada: ada, family: family)
    }

    private func key() -> LinkPublicKey { LinkIdentity().publicKey }

    private func assertRefused(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }

    // MARK: Who is an admin

    func testUsersAreNotAdminsUntilTheHubMakesThem() throws {
        let f = try fixture()
        XCTAssertFalse(f.ada.isAdmin)
        XCTAssertTrue(f.admin.isAdmin)
        f.access.setAdmin(false, for: f.admin)
        XCTAssertEqual(f.access.users.first { $0.id == f.admin.id }?.isAdmin, false)
    }

    func testTheAdminRoleSurvivesARelaunch() throws {
        let f = try fixture()
        let reopened = HubAccess(url: f.url)
        XCTAssertEqual(reopened.users.map(\.isAdmin), [true, false])
    }

    /// Access files from before admins existed have nobody who is one.
    func testUsersSavedBeforeAdminsAreNotAdmins() throws {
        let user = try JSONDecoder().decode(HubUser.self, from: Data(#"""
        {"id":"00000000-0000-0000-0000-00000000000A","name":"Ada","plan":"00000000-0000-0000-0000-000000000000"}
        """#.utf8))
        XCTAssertFalse(user.isAdmin)
        XCTAssertTrue(user.canPairDevices)
    }

    func testOnlyAnAdminGetsIn() throws {
        let f = try fixture()
        XCTAssertNoThrow(try HubAdmin(f.admin, access: f.access))
        assertRefused("Only an admin of this Hub can do that.") { _ = try HubAdmin(f.ada, access: f.access) }
    }

    /// The role is read from the Hub's own record, never from the copy a request carried.
    func testTheRoleIsReadAfresh() throws {
        let f = try fixture()
        var forged = f.ada
        forged.isAdmin = true
        assertRefused("Only an admin of this Hub can do that.") { _ = try HubAdmin(forged, access: f.access) }

        let stale = f.admin
        f.access.setAdmin(false, for: f.admin)
        assertRefused("Only an admin of this Hub can do that.") { _ = try HubAdmin(stale, access: f.access) }
    }

    func testARemovedAdminGetsNothing() throws {
        let f = try fixture()
        f.access.remove(f.admin)
        assertRefused("Only an admin of this Hub can do that.") { _ = try HubAdmin(f.admin, access: f.access) }
    }

    /// This Mac as a Hub has only its owner, even with an admin flag left in its file.
    func testAPersonalMacHasNoAdmins() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-admin-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let owner = HubUser(name: "Me", isAdmin: true)
        let stored = #"{"users":[{"id":"\#(owner.id)","name":"Me","plan":"\#(HubPlan.defaultID)","isAdmin":true}],"plans":[]}"#
        try Data(stored.utf8).write(to: url)
        let personal = HubAccess(url: url, personal: true)
        let me = try XCTUnwrap(personal.users.first)
        assertRefused("Only an admin of this Hub can do that.") { _ = try HubAdmin(me, access: personal) }

        personal.setAdmin(true, for: me)
        assertRefused("Only an admin of this Hub can do that.") {
            _ = try HubAdmin(try XCTUnwrap(personal.users.first), access: personal)
        }
    }

    // MARK: Listing

    func testAdminsSeeEveryUserWithTheirDevicesAndThePlans() throws {
        let f = try fixture()
        f.access.move(f.ada, to: f.family)
        let paired = Date(timeIntervalSince1970: 1_800_000_000)
        let phone = f.access.addDevice(named: "Ada’s iPhone", key: key(), for: f.ada, at: paired)
        let mac = f.access.addDevice(named: "Grace’s Mac", key: key(), for: f.admin, at: paired)
        let admin = try HubAdmin(f.admin, access: f.access, isConnected: { $0.id == phone.id })

        let listed = admin.users()
        XCTAssertEqual(listed.plans, [LinkPlanChoice(id: HubPlan.defaultID, name: "Default"), LinkPlanChoice(id: f.family.id, name: "Family")])
        XCTAssertEqual(listed.users, [
            LinkUser(id: f.admin.id, name: "Grace", plan: HubPlan.defaultID, canPairDevices: true, isAdmin: true,
                     devices: [LinkUserDevice(id: mac.id, name: "Grace’s Mac", paired: paired, lastSeen: paired, isConnected: false)]),
            LinkUser(id: f.ada.id, name: "Ada", plan: f.family.id, canPairDevices: true, isAdmin: false,
                     devices: [LinkUserDevice(id: phone.id, name: "Ada’s iPhone", paired: paired, lastSeen: paired, isConnected: true)]),
        ])
        // Without the link to ask, no device counts as connected.
        XCTAssertEqual(try HubAdmin(f.admin, access: f.access).users().users.flatMap(\.devices).map(\.isConnected), [false, false])
    }

    // MARK: Adding

    func testAnAdminAddsAUserOnThePlanTheyChoose() throws {
        let f = try fixture()
        let admin = try HubAdmin(f.admin, access: f.access)
        let added = try admin.addUser(LinkUserDraft(name: "  Bea ", plan: f.family.id, canPairDevices: false))
        XCTAssertEqual(added.name, "Bea")
        XCTAssertEqual(added.plan, f.family.id)
        XCTAssertFalse(added.canPairDevices)
        XCTAssertFalse(added.isAdmin)
        XCTAssertEqual(added.devices, [])
        XCTAssertEqual(f.access.users.last, HubUser(id: added.id, name: "Bea", plan: f.family.id, canPairDevices: false))
    }

    func testAUserAddedWithoutChoicesGetsTheDefaults() throws {
        let f = try fixture()
        let added = try HubAdmin(f.admin, access: f.access).addUser(LinkUserDraft(name: "Bea"))
        XCTAssertEqual(added.plan, HubPlan.defaultID)
        XCTAssertTrue(added.canPairDevices)
        XCTAssertFalse(added.isAdmin)
    }

    /// Nothing is added when any part of the request is wrong.
    func testAUserIsNotAddedOnAPlanThatIsNotThere() throws {
        let f = try fixture()
        let admin = try HubAdmin(f.admin, access: f.access)
        assertRefused("That plan is no longer on this Hub.") { _ = try admin.addUser(LinkUserDraft(name: "Bea", plan: UUID())) }
        assertRefused(try nameError("")) { _ = try admin.addUser(LinkUserDraft(name: "")) }
        assertRefused(try nameError(" \n")) { _ = try admin.addUser(LinkUserDraft(name: " \n")) }
        assertRefused(try nameError("")) { _ = try admin.addUser(LinkUserDraft()) }
        XCTAssertEqual(f.access.users.map(\.name), ["Grace", "Ada"])
    }

    // MARK: Changing

    func testAnAdminRenamesMovesAndStopsAUserPairing() throws {
        let f = try fixture()
        let admin = try HubAdmin(f.admin, access: f.access)
        let changed = try admin.updateUser(f.ada.id, with: LinkUserDraft(name: "Ada L.", plan: f.family.id, canPairDevices: false))
        XCTAssertEqual(changed.name, "Ada L.")
        XCTAssertEqual(changed.plan, f.family.id)
        XCTAssertFalse(changed.canPairDevices)
        XCTAssertEqual(f.access.users.last, HubUser(id: f.ada.id, name: "Ada L.", plan: f.family.id, canPairDevices: false))
    }

    func testFieldsLeftOutStayAsTheyAre() throws {
        let f = try fixture()
        f.access.move(f.ada, to: f.family)
        f.access.setCanPairDevices(false, for: f.ada)
        let admin = try HubAdmin(f.admin, access: f.access)
        let renamed = try admin.updateUser(f.ada.id, with: LinkUserDraft(name: "Ada L."))
        XCTAssertEqual(renamed.plan, f.family.id)
        XCTAssertFalse(renamed.canPairDevices)
        let moved = try admin.updateUser(f.ada.id, with: LinkUserDraft(plan: HubPlan.defaultID))
        XCTAssertEqual(moved.name, "Ada L.")
        XCTAssertEqual(moved.plan, HubPlan.defaultID)
    }

    /// A change is checked whole before any of it is kept.
    func testABadChangeChangesNothing() throws {
        let f = try fixture()
        let admin = try HubAdmin(f.admin, access: f.access)
        assertRefused("That plan is no longer on this Hub.") {
            _ = try admin.updateUser(f.ada.id, with: LinkUserDraft(name: "Mallory", plan: UUID(), canPairDevices: false))
        }
        assertRefused(try nameError("")) {
            _ = try admin.updateUser(f.ada.id, with: LinkUserDraft(name: "", plan: f.family.id, canPairDevices: false))
        }
        XCTAssertEqual(f.access.users.last, f.ada)
    }

    func testChangingAUserWhoIsGoneSaysSo() throws {
        let f = try fixture()
        let admin = try HubAdmin(f.admin, access: f.access)
        assertRefused("That user is no longer on this Hub.") { _ = try admin.updateUser(UUID(), with: LinkUserDraft(name: "Bea")) }
        f.access.remove(f.ada)
        assertRefused("That user is no longer on this Hub.") { _ = try admin.updateUser(f.ada.id, with: LinkUserDraft(name: "Ada")) }
        XCTAssertEqual(f.access.users.map(\.name), ["Grace"])
    }

    // MARK: Admins are out of reach

    /// An admin cannot raise their own plan, keep themselves pairing, or touch another admin.
    func testAdminsCannotChangeThemselvesOrOtherAdmins() throws {
        let f = try fixture()
        let other = try f.access.addUser(named: "Linus")
        f.access.setAdmin(true, for: other)
        let admin = try HubAdmin(f.admin, access: f.access)
        for target in [f.admin, other] {
            let message = "“\(target.name)” is an admin. Admins are managed on the Hub itself."
            assertRefused(message) { _ = try admin.updateUser(target.id, with: LinkUserDraft(plan: f.family.id)) }
            assertRefused(message) { _ = try admin.updateUser(target.id, with: LinkUserDraft(name: "Mallory")) }
            assertRefused(message) { _ = try admin.updateUser(target.id, with: LinkUserDraft(canPairDevices: false)) }
            assertRefused(message) { _ = try admin.managedUser(target.id) }
        }
        XCTAssertEqual(f.access.users.map(\.plan), [HubPlan.defaultID, HubPlan.defaultID, HubPlan.defaultID])
        XCTAssertEqual(f.access.users.map(\.name), ["Grace", "Ada", "Linus"])
    }

    /// Nothing a device sends makes an admin: the draft has no such field, and an extra one is ignored.
    func testNoRequestMakesAnAdmin() throws {
        let f = try fixture()
        let admin = try HubAdmin(f.admin, access: f.access)
        let draft = try JSONDecoder().decode(LinkUserDraft.self, from: Data(#"{"name":"Mallory","isAdmin":true}"#.utf8))
        let added = try admin.addUser(draft)
        _ = try admin.updateUser(f.ada.id, with: draft)
        XCTAssertFalse(added.isAdmin)
        XCTAssertEqual(f.access.users.filter(\.isAdmin).map(\.id), [f.admin.id])
    }

    func testAdminsCannotTakeAnAdminsDevices() throws {
        let f = try fixture()
        let mine = f.access.addDevice(named: "Grace’s Mac", key: key(), for: f.admin, at: Date())
        let other = try f.access.addUser(named: "Linus")
        f.access.setAdmin(true, for: other)
        let theirs = f.access.addDevice(named: "Linus’s Mac", key: key(), for: other, at: Date())
        let admin = try HubAdmin(f.admin, access: f.access)
        assertRefused("“Grace” is an admin. Admins are managed on the Hub itself.") { _ = try admin.managedDevice(mine.id) }
        assertRefused("“Linus” is an admin. Admins are managed on the Hub itself.") { _ = try admin.managedDevice(theirs.id) }
    }

    // MARK: Removing and inviting

    func testAdminsReachTheUsersAndDevicesTheyManage() throws {
        let f = try fixture()
        let phone = f.access.addDevice(named: "Ada’s iPhone", key: key(), for: f.ada, at: Date())
        let admin = try HubAdmin(f.admin, access: f.access)
        XCTAssertEqual(try admin.managedUser(f.ada.id), f.ada)
        XCTAssertEqual(try admin.managedDevice(phone.id), phone)
    }

    func testUsersAndDevicesThatAreGoneSaySo() throws {
        let f = try fixture()
        let phone = f.access.addDevice(named: "Ada’s iPhone", key: key(), for: f.ada, at: Date())
        let admin = try HubAdmin(f.admin, access: f.access)
        f.access.remove(phone)
        assertRefused("That device is no longer paired with this Hub.") { _ = try admin.managedDevice(phone.id) }
        assertRefused("That device is no longer paired with this Hub.") { _ = try admin.managedDevice(UUID()) }
        assertRefused("That user is no longer on this Hub.") { _ = try admin.managedUser(UUID()) }
    }

    /// Revoking on the Hub stops an admin whose request was already under way.
    func testAnAdminDemotedMidwayIsStopped() throws {
        let f = try fixture()
        let admin = try HubAdmin(f.admin, access: f.access)
        f.access.setAdmin(false, for: f.admin)
        let refused = "Only an admin of this Hub can do that."
        assertRefused(refused) { _ = try admin.addUser(LinkUserDraft(name: "Bea")) }
        assertRefused(refused) { _ = try admin.updateUser(f.ada.id, with: LinkUserDraft(name: "Bea")) }
        assertRefused(refused) { _ = try admin.managedUser(f.ada.id) }
        assertRefused(refused) { _ = try admin.managedDevice(UUID()) }
        XCTAssertEqual(f.access.users.map(\.name), ["Grace", "Ada"])
    }

    private func nameError(_ name: String) throws -> String {
        do {
            _ = try ConversationName.validated(name)
            throw XCTSkip("“\(name)” is a valid name")
        } catch let error as XCTSkip {
            throw error
        } catch {
            return error.localizedDescription
        }
    }
}
