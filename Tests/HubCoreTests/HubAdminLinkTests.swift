import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleHubClient
import NoodleRuntime
import XCTest

/// An admin managing the Hub's users from their own device, over real QUIC on this Mac.
@MainActor final class HubAdminLinkTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let link: HubLinkService
        let root: URL
        let grace: HubUser
        let ada: HubUser
        let family: HubPlan
        /// Grace's, an admin's.
        let admin: HubPairing
        /// Ada's, who is not an admin.
        let phone: HubPairing
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-admin-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let grace = try hub.access.addUser(named: "Grace")
        hub.access.setAdmin(true, for: grace)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)
        let admin = HubPairing(directory: root.appendingPathComponent("Admin"), deviceName: "Grace’s iPhone")
        await admin.join(link.invite(grace).url().absoluteString)
        let phone = HubPairing(directory: root.appendingPathComponent("Phone"), deviceName: "Ada’s iPhone")
        await phone.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(admin.error)
        XCTAssertNil(phone.error)
        return Fixture(hub: hub, link: link, root: root, grace: try XCTUnwrap(hub.access.users.first), ada: ada, family: family,
                       admin: admin, phone: phone)
    }

    /// Why the Hub refused the request, or nil when it did not.
    private func refusal(_ request: LinkRequest, from device: HubPairing) async -> String? {
        do {
            _ = try await device.request(request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func users(_ device: HubPairing) async throws -> LinkUsers {
        guard case .users(let users) = try await device.request(.users) else { throw LinkError("Not listed") }
        return users
    }

    func testDevicesKnowWhetherTheirUserIsAnAdmin() async throws {
        let f = try await fixture()
        XCTAssertEqual(f.admin.status?.isAdmin, true)
        XCTAssertEqual(f.phone.status?.isAdmin, false)
        f.hub.access.setAdmin(false, for: f.grace)
        await f.admin.refresh()
        XCTAssertEqual(f.admin.status?.isAdmin, false)
    }

    /// Every admin request, from a device whose user is not an admin, changes nothing.
    func testOnlyAnAdminsDevicesReachTheAdminRequests() async throws {
        let f = try await fixture()
        let graceDevice = try XCTUnwrap(f.hub.access.devices(of: f.grace).first)
        let before = (f.hub.access.users, f.hub.access.devices)
        let requests: [LinkRequest] = [
            .users,
            .addUser(LinkUserDraft(name: "Mallory")),
            .updateUser(id: f.ada.id, LinkUserDraft(plan: HubPlan.defaultID)),
            .updateUser(id: f.grace.id, LinkUserDraft(name: "Mallory")),
            .removeUser(id: f.grace.id),
            .removeDevice(id: graceDevice.id),
            .inviteUser(id: f.grace.id),
            .inviteUser(id: f.ada.id),
        ]
        for request in requests {
            let answer = await refusal(request, from: f.phone)
            XCTAssertEqual(answer, "Only an admin of this Hub can do that.", "\(request)")
        }
        XCTAssertEqual(f.hub.access.users, before.0)
        XCTAssertEqual(f.hub.access.devices.map(\.id), before.1.map(\.id))
    }

    /// The key an invitation carries only joins: it cannot act as the admin who made it.
    func testAnInvitationsKeyReachesNoAdminRequest() async throws {
        let f = try await fixture()
        let join = try f.link.invite(f.grace).joinIdentity()
        for request in [LinkRequest.users, .addUser(LinkUserDraft(name: "Mallory")), .removeUser(id: f.ada.id)] {
            let (answer, _) = try await LinkClient.exchange(try LinkProtocol.encode(request), identity: join, hubKey: f.link.key,
                                                            endpoints: f.link.endpoints, timeout: .seconds(5))
            XCTAssertEqual(try LinkProtocol.decodeResponse(answer), .failure("This device is not paired with Mac mini."))
        }
        XCTAssertEqual(f.hub.access.users.map(\.name), ["Grace", "Ada"])
        let refused = try XCTUnwrap(f.hub.access.log?.entries.suffix(3))
        XCTAssertEqual(refused.map(\.what), ["Tried to list the users", "Tried to add Mallory", "Tried to remove Ada"])
        XCTAssertEqual(Set(refused.map(\.who)), ["A device not paired"])
        XCTAssertEqual(Set(refused.compactMap(\.refusal)), ["This device is not paired with Mac mini."])
    }

    func testAnAdminAddsSomeoneAndPairsTheirDevice() async throws {
        let f = try await fixture()
        guard case .user(let bea) = try await f.admin.request(.addUser(LinkUserDraft(name: "Bea", plan: f.family.id))) else {
            return XCTFail("not added")
        }
        guard case .invitation(let invitation) = try await f.admin.request(.inviteUser(id: bea.id)) else {
            return XCTFail("no invitation")
        }
        XCTAssertEqual(invitation.userName, "Bea")
        let tablet = HubPairing(directory: f.root.appendingPathComponent("Bea"), deviceName: "Bea’s iPad")
        await tablet.join(invitation.url().absoluteString)
        XCTAssertNil(tablet.error)
        XCTAssertEqual(tablet.status?.userName, "Bea")
        XCTAssertEqual(tablet.status?.planName, "Family")
        XCTAssertEqual(tablet.status?.isAdmin, false)

        let listed = try await users(f.admin)
        XCTAssertEqual(listed.users.map(\.name), ["Grace", "Ada", "Bea"])
        XCTAssertEqual(listed.users.last?.devices.map(\.name), ["Bea’s iPad"])
        XCTAssertEqual(listed.users.last?.devices.first?.isConnected, true)
        XCTAssertEqual(listed.plans.map(\.name), ["Default", "Family"])
    }

    func testAnAdminChangesSomeonesPlanAndPairing() async throws {
        let f = try await fixture()
        guard case .user(let changed) = try await f.admin.request(.updateUser(id: f.ada.id, LinkUserDraft(plan: HubPlan.defaultID, canPairDevices: false))) else {
            return XCTFail("not changed")
        }
        XCTAssertEqual(changed.plan, HubPlan.defaultID)
        await f.phone.refresh()
        XCTAssertEqual(f.phone.status?.planName, "Default")
        XCTAssertEqual(f.phone.status?.canPairDevices, false)
        do {
            _ = try await f.phone.invite()
            XCTFail("Ada still made an invitation")
        } catch {}
    }

    func testAnAdminUnpairsSomeonesDevice() async throws {
        let f = try await fixture()
        let device = try XCTUnwrap(f.hub.access.devices(of: f.ada).first)
        let answer = try await f.admin.request(.removeDevice(id: device.id))
        XCTAssertEqual(answer, .done)
        XCTAssertEqual(f.hub.access.devices(of: f.ada), [])
        await f.phone.refresh()
        XCTAssertNotNil(f.phone.error)
        let again = await refusal(.removeDevice(id: device.id), from: f.admin)
        XCTAssertEqual(again, "That device is no longer paired with this Hub.")
    }

    /// Removing someone from a device removes as much as removing them on the Hub: their bots go too.
    func testAnAdminRemovesSomeoneWithTheirDevicesAndBots() async throws {
        let f = try await fixture()
        guard case .bot = try await f.phone.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        XCTAssertEqual(try f.hub.repository.loadAgents().count, 1)
        let answer = try await f.admin.request(.removeUser(id: f.ada.id))
        XCTAssertEqual(answer, .done)
        XCTAssertEqual(f.hub.access.users.map(\.name), ["Grace"])
        XCTAssertEqual(f.hub.access.devices.map(\.name), ["Grace’s iPhone"])
        XCTAssertEqual(try f.hub.repository.loadAgents(), [])
        await f.phone.refresh()
        XCTAssertNotNil(f.phone.error)
        let again = await refusal(.removeUser(id: f.ada.id), from: f.admin)
        XCTAssertEqual(again, "That user is no longer on this Hub.")
    }

    /// An invitation made for someone who is then removed lets nobody in.
    func testAnInvitationForSomeoneRemovedIsRefused() async throws {
        let f = try await fixture()
        guard case .invitation(let invitation) = try await f.admin.request(.inviteUser(id: f.ada.id)) else {
            return XCTFail("no invitation")
        }
        _ = try await f.admin.request(.removeUser(id: f.ada.id))
        let late = HubPairing(directory: f.root.appendingPathComponent("Late"), deviceName: "Ada’s iPad")
        await late.join(invitation.url().absoluteString)
        XCTAssertNotNil(late.error)
        XCTAssertEqual(f.hub.access.devices.map(\.name), ["Grace’s iPhone"])
    }

    /// An admin cannot remove, unpair or invite for themselves, nor another admin, from a device.
    func testAdminsAreManagedOnlyOnTheHub() async throws {
        let f = try await fixture()
        let linus = try f.hub.access.addUser(named: "Linus")
        f.hub.access.setAdmin(true, for: linus)
        let linusDevice = f.hub.access.addDevice(named: "Linus’s Mac", key: LinkIdentity().publicKey, for: linus, at: Date())
        let ownDevice = try XCTUnwrap(f.hub.access.devices(of: f.grace).first)
        let grace = "“Grace” is an admin. Admins are managed on the Hub itself."
        let other = "“Linus” is an admin. Admins are managed on the Hub itself."
        let attempts: [(LinkRequest, String)] = [
            (.removeUser(id: f.grace.id), grace), (.removeUser(id: linus.id), other),
            (.removeDevice(id: ownDevice.id), grace), (.removeDevice(id: linusDevice.id), other),
            (.inviteUser(id: f.grace.id), grace), (.inviteUser(id: linus.id), other),
            (.updateUser(id: f.grace.id, LinkUserDraft(plan: f.family.id)), grace),
            (.updateUser(id: linus.id, LinkUserDraft(canPairDevices: false)), other),
        ]
        for (request, message) in attempts {
            let answer = await refusal(request, from: f.admin)
            XCTAssertEqual(answer, message, "\(request)")
        }
        XCTAssertEqual(f.hub.access.users.map(\.name), ["Grace", "Ada", "Linus"])
        XCTAssertEqual(f.hub.access.users.map(\.plan), [HubPlan.defaultID, f.family.id, HubPlan.defaultID])
        XCTAssertEqual(f.hub.access.devices.count, 3)
    }

    /// This Mac as a Hub serves only its owner, even with an admin flag left in its file.
    func testThisMacAsAHubHasNoAdmins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-admin-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("access.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = UUID()
        try Data(#"{"users":[{"id":"\#(owner)","name":"Me","plan":"\#(HubPlan.defaultID)","isAdmin":true}],"plans":[]}"#.utf8).write(to: url)
        let access = HubAccess(url: url, personal: true)
        let profiles = HarnessProfilesController(store: WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle")).harnessProfiles)
        let link = HubLinkService(hubName: "Mac", directory: root.appendingPathComponent("Link"), access: access, profiles: profiles,
                                  port: 0, localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let phone = HubPairing(directory: root.appendingPathComponent("Phone"), deviceName: "iPhone")
        await phone.join(link.invite(try XCTUnwrap(access.users.first)).url().absoluteString)
        XCTAssertNil(phone.error)
        XCTAssertEqual(phone.status?.isAdmin, false)
        let refused = await refusal(.users, from: phone)
        XCTAssertEqual(refused, "Only an admin of this Hub can do that.")
    }

    /// Admins hear that users changed so their screens keep up; checking in is not a change, and others hear nothing.
    func testAdminsHearWhenUsersChange() async throws {
        let f = try await fixture()
        f.hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: f.hub.access.plans[0])
        let adminEvents = try await f.admin.subscribe()
        let phoneEvents = try await f.phone.subscribe()
        // Round trips, so the Hub has both subscriptions before anything changes; each also checks the device in.
        _ = try await f.admin.request(.users)
        await f.phone.refresh()

        _ = try await f.admin.request(.addUser(LinkUserDraft(name: "Bea")))
        var adminIterator = adminEvents.makeAsyncIterator()
        let answer = try await adminIterator.next()
        XCTAssertEqual(answer, .usersChanged)

        // A check-in alone pushes nothing: the next event is the bot Grace makes.
        await f.phone.refresh()
        _ = try await f.admin.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code")))
        let next = try await adminIterator.next()
        XCTAssertEqual(next, .botsChanged)

        // Ada heard nothing of the new user: the first thing she hears is her own bot.
        _ = try await f.phone.request(.createBot(LinkBotDraft(name: "Jeeves", provider: "claude-code")))
        var phoneIterator = phoneEvents.makeAsyncIterator()
        let heard = try await phoneIterator.next()
        XCTAssertEqual(heard, .botsChanged)
    }

    // MARK: The activity log

    private func entries(_ f: Fixture, after count: Int) -> [HubActivityEntry] {
        Array((f.hub.access.log?.entries ?? []).dropFirst(count))
    }

    /// Pairing is kept with whoever made the invitation, on the Hub or on a device.
    func testPairingIsLoggedWithWhoMadeTheInvitation() async throws {
        let f = try await fixture()
        let log = try XCTUnwrap(f.hub.access.log)
        XCTAssertEqual(log.entries.map(\.what), [
            "Added Grace", "Made Grace an admin", "Added Ada", "Moved Ada to the Family plan",
            "Invited a device for Grace", "Paired “Grace’s iPhone” for Grace",
            "Invited a device for Ada", "Paired “Ada’s iPhone” for Ada",
        ])
        XCTAssertEqual(log.entries.suffix(4).map(\.who), ["This Mac", "Invitation from This Mac", "This Mac", "Invitation from This Mac"])

        let before = log.entries.count
        let invitation = try await f.phone.invite()
        let tablet = HubPairing(directory: f.root.appendingPathComponent("Tablet"), deviceName: "Ada’s iPad")
        await tablet.join(invitation.url().absoluteString)
        let added = entries(f, after: before)
        XCTAssertEqual(added.map(\.what), ["Invited a device for Ada", "Paired “Ada’s iPad” for Ada"])
        XCTAssertEqual(added.map(\.who), ["Ada on Ada’s iPhone", "Invitation from Ada on Ada’s iPhone"])
        XCTAssertEqual(added.map(\.users), [[f.ada.id], [f.ada.id]])
    }

    func testAnAdminsChangesAreLoggedWithTheirDevice() async throws {
        let f = try await fixture()
        let before = try XCTUnwrap(f.hub.access.log).entries.count
        guard case .user(let bea) = try await f.admin.request(.addUser(LinkUserDraft(name: "Bea", plan: f.family.id, canPairDevices: false))) else {
            return XCTFail("not added")
        }
        _ = try await f.admin.request(.updateUser(id: bea.id, LinkUserDraft(name: "Bea L.")))
        _ = try await f.admin.request(.inviteUser(id: bea.id))
        let phone = try XCTUnwrap(f.hub.access.devices(of: f.ada).first)
        _ = try await f.admin.request(.removeDevice(id: phone.id))
        _ = try await f.admin.request(.removeUser(id: f.ada.id))
        let added = entries(f, after: before)
        XCTAssertEqual(added.map(\.what), [
            "Added Bea", "Moved Bea to the Family plan", "Stopped Bea pairing devices", "Renamed Bea to Bea L.",
            "Invited a device for Bea L.", "Unpaired “Ada’s iPhone” from Ada", "Removed Ada",
        ])
        XCTAssertEqual(Set(added.map(\.who)), ["Grace on Grace’s iPhone"])
        XCTAssertEqual(added.last?.users, [f.grace.id, f.ada.id])
        XCTAssertTrue(added.allSatisfy { $0.refusal == nil })
    }

    /// What the Hub refused is kept with its reason: someone trying what they may not is what an owner wants to see.
    func testRefusedAttemptsAreLogged() async throws {
        let f = try await fixture()
        let before = try XCTUnwrap(f.hub.access.log).entries.count
        let graceDevice = try XCTUnwrap(f.hub.access.devices(of: f.grace).first)
        for request: LinkRequest in [.users, .addUser(LinkUserDraft(name: "Mallory")), .updateUser(id: f.grace.id, LinkUserDraft(name: "M")),
                                     .removeUser(id: f.grace.id), .removeDevice(id: graceDevice.id), .inviteUser(id: f.grace.id)] {
            _ = await refusal(request, from: f.phone)
        }
        _ = await refusal(.removeUser(id: UUID()), from: f.admin)
        _ = await refusal(.removeDevice(id: UUID()), from: f.admin)
        _ = await refusal(.removeUser(id: f.grace.id), from: f.admin)
        f.hub.access.setCanPairDevices(false, for: f.ada)
        _ = await refusal(.invite, from: f.phone)

        let added = entries(f, after: before)
        let refused = added.filter { $0.refusal != nil }
        let notAdmin = "Only an admin of this Hub can do that."
        XCTAssertEqual(refused.map(\.what), [
            "Tried to list the users", "Tried to add Mallory", "Tried to change Grace", "Tried to remove Grace",
            "Tried to unpair “Grace’s iPhone”", "Tried to invite a device for Grace",
            "Tried to remove someone no longer on the Hub", "Tried to unpair a device no longer paired", "Tried to remove Grace",
            "Tried to invite a device for Ada",
        ])
        XCTAssertEqual(refused.map(\.refusal), [notAdmin, notAdmin, notAdmin, notAdmin, notAdmin, notAdmin,
                                                "That user is no longer on this Hub.", "That device is no longer paired with this Hub.",
                                                "“Grace” is an admin. Admins are managed on the Hub itself.",
                                                "You cannot pair devices with Mac mini. Ask whoever keeps it."])
        XCTAssertEqual(refused.map(\.who), Array(repeating: "Ada on Ada’s iPhone", count: 6) + Array(repeating: "Grace on Grace’s iPhone", count: 3)
                       + ["Ada on Ada’s iPhone"])
        XCTAssertEqual(refused.first?.users, [f.ada.id])
        XCTAssertEqual(refused[3].users, [f.ada.id, f.grace.id])
        // Nothing was changed, so the only other entry is the Hub's own.
        XCTAssertEqual(added.filter { $0.refusal == nil }.map(\.what), ["Stopped Ada pairing devices"])
    }

    /// A list that works is not news; only changes and refusals are kept.
    func testListingIsNotLogged() async throws {
        let f = try await fixture()
        let before = try XCTUnwrap(f.hub.access.log).entries.count
        _ = try await f.admin.request(.users)
        await f.phone.refresh()
        XCTAssertEqual(entries(f, after: before), [])
    }

    func testAFailedPairingIsLogged() async throws {
        let f = try await fixture()
        let before = try XCTUnwrap(f.hub.access.log).entries.count
        let victim = try XCTUnwrap(f.hub.access.devices(of: f.ada).first)
        let join = try f.link.invite(f.grace).joinIdentity()
        let forged = LinkRequest.enroll(deviceKey: victim.key, proof: try LinkIdentity().joinProof(for: join.publicKey), deviceName: "Mallory’s Mac")
        _ = try await LinkClient.exchange(try LinkProtocol.encode(forged), identity: join, hubKey: f.link.key,
                                          endpoints: f.link.endpoints, timeout: .seconds(5))
        let added = entries(f, after: before)
        XCTAssertEqual(added.map(\.what), ["Invited a device for Grace", "Tried to pair “Mallory’s Mac”"])
        XCTAssertEqual(added.last?.who, "Invitation from This Mac")
        XCTAssertEqual(added.last?.refusal, "This device could not prove its key.")
        XCTAssertEqual(added.last?.users, [f.grace.id])
    }
}

/// What Noodle and Noodle Mobile show an admin: the Hub's users, kept in step as they change them.
@MainActor final class HubUsersTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let root: URL
        let grace: HubUser
        let ada: HubUser
        let family: HubPlan
        let admin: HubPairing
        let phone: HubPairing
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-users-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let family = try hub.access.addPlan(named: "Family")
        let grace = try hub.access.addUser(named: "Grace")
        hub.access.setAdmin(true, for: grace)
        let ada = try hub.access.addUser(named: "Ada")
        let admin = HubPairing(directory: root.appendingPathComponent("Admin"), deviceName: "Grace’s Mac")
        await admin.join(link.invite(grace).url().absoluteString)
        let phone = HubPairing(directory: root.appendingPathComponent("Phone"), deviceName: "Ada’s iPhone")
        await phone.join(link.invite(ada).url().absoluteString)
        return Fixture(hub: hub, root: root, grace: grace, ada: ada, family: family, admin: admin, phone: phone)
    }

    private func user(_ users: HubUsers, _ name: String) throws -> LinkUser {
        try XCTUnwrap(users.users.first { $0.name == name })
    }

    func testAnAdminSeesTheUsersTheirDevicesAndThePlans() async throws {
        let f = try await fixture()
        let users = HubUsers(pairing: f.admin)
        XCTAssertFalse(users.isLoaded)
        await users.load()
        XCTAssertTrue(users.isLoaded)
        XCTAssertNil(users.error)
        XCTAssertEqual(users.users.map(\.name), ["Grace", "Ada"])
        XCTAssertEqual(users.users.map(\.isAdmin), [true, false])
        XCTAssertEqual(try user(users, "Ada").devices.map(\.name), ["Ada’s iPhone"])
        XCTAssertEqual(users.plans.map(\.name), ["Default", "Family"])
        XCTAssertEqual(users.planName(of: try user(users, "Ada")), "Default")
        XCTAssertNil(users.planName(of: LinkUser(id: UUID(), name: "X", plan: UUID(), canPairDevices: true, isAdmin: false, devices: [])))
    }

    /// An admin sees the picture each person chose, and initials for those who chose none.
    func testAnAdminSeesEveryonesPicture() async throws {
        let f = try await fixture()
        let photo = try smallJPEG()
        try await f.phone.setAvatar(LinkAvatar(colour: 3, image: photo))
        let users = HubUsers(pairing: f.admin)
        await users.load()
        XCTAssertEqual(try user(users, "Ada").avatar?.image, photo)
        XCTAssertEqual(try user(users, "Ada").avatar?.colour, 3)
        XCTAssertNil(try user(users, "Grace").avatar)
    }

    func testAnAdminChangesSomeoneAndSeesIt() async throws {
        let f = try await fixture()
        let users = HubUsers(pairing: f.admin)
        await users.load()
        let ada = try user(users, "Ada")
        await users.rename(ada, to: "Ada L.")
        await users.move(try user(users, "Ada L."), to: f.family.id)
        await users.setCanPairDevices(false, for: try user(users, "Ada L."))
        XCTAssertNil(users.error)
        XCTAssertEqual(try user(users, "Ada L.").plan, f.family.id)
        XCTAssertEqual(try user(users, "Ada L.").canPairDevices, false)
        XCTAssertEqual(f.hub.access.users.last, HubUser(id: f.ada.id, name: "Ada L.", plan: f.family.id, canPairDevices: false))
    }

    func testAnAdminAddsSomeoneAndInvitesThem() async throws {
        let f = try await fixture()
        let users = HubUsers(pairing: f.admin)
        await users.load()
        let added = await users.add(named: "Bea")
        let bea = try XCTUnwrap(added)
        XCTAssertEqual(bea.name, "Bea")
        XCTAssertEqual(users.users.map(\.name), ["Grace", "Ada", "Bea"])
        let invited = await users.invite(bea)
        let invitation = try XCTUnwrap(invited)
        XCTAssertEqual(invitation.userName, "Bea")
        XCTAssertNil(users.error)
    }

    func testAnAdminRemovesADeviceAndThenTheUser() async throws {
        let f = try await fixture()
        let users = HubUsers(pairing: f.admin)
        await users.load()
        await users.remove(try XCTUnwrap(try user(users, "Ada").devices.first))
        XCTAssertEqual(try user(users, "Ada").devices, [])
        await users.remove(try user(users, "Ada"))
        XCTAssertNil(users.error)
        XCTAssertEqual(users.users.map(\.name), ["Grace"])
        XCTAssertEqual(f.hub.access.users.map(\.name), ["Grace"])
    }

    /// What the Hub refuses is shown, and the list stays as the Hub has it.
    func testRefusalsAreShown() async throws {
        let f = try await fixture()
        let users = HubUsers(pairing: f.admin)
        await users.load()
        let blank = await users.add(named: " ")
        XCTAssertNil(blank)
        XCTAssertNotNil(users.error)
        await users.remove(try user(users, "Grace"))
        XCTAssertEqual(users.error, "“Grace” is an admin. Admins are managed on the Hub itself.")
        XCTAssertEqual(users.users.map(\.name), ["Grace", "Ada"])
        let invitedAdmin = await users.invite(try user(users, "Grace"))
        XCTAssertNil(invitedAdmin)

        // The next thing that works clears it.
        await users.load()
        XCTAssertNil(users.error)
    }

    func testSomeoneWhoIsNotAnAdminIsTold() async throws {
        let f = try await fixture()
        let users = HubUsers(pairing: f.phone)
        await users.load()
        XCTAssertEqual(users.error, "Only an admin of this Hub can do that.")
        XCTAssertEqual(users.users, [])
        XCTAssertTrue(users.isLoaded)
    }

    /// Changes made on the Hub or by another admin reach the Mac while it is connected.
    func testTheMirrorHearsWhenUsersChange() async throws {
        let f = try await fixture()
        let local = WorkspaceRepository(rootURL: f.root.appendingPathComponent("Noodle"))
        try local.prepare()
        let mirror = HubMirror(pairing: f.admin, repository: local, directory: f.root.appendingPathComponent("Admin"))
        let running = Task { await mirror.run() }
        addTeardownBlock { running.cancel() }
        for _ in 0..<50 where !mirror.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        // A round trip, so the Hub has the subscription before anything changes.
        _ = try await f.admin.request(.users)
        XCTAssertEqual(mirror.usersChanges, 0)
        _ = try f.hub.access.addUser(named: "Bea")
        for _ in 0..<50 where mirror.usersChanges == 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(mirror.usersChanges, 1)
    }
}
