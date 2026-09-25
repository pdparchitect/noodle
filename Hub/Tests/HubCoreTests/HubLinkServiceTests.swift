import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// A device and the Hub talking over real QUIC on this Mac, as they do in the apps.
@MainActor final class HubLinkServiceTests: XCTestCase {
    private var clock = Date()

    private func fixture(router: (any RouterPortMapper)? = nil) async throws -> (Hub, HubLinkService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        // Loopback stands in for the Mac's own addresses, which a CI runner may not have.
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, port: 0, router: router,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] }, now: { [unowned self] in clock })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        return (hub, link, root.appendingPathComponent("Device"))
    }

    func testADeviceJoinsWithAnInvitationAndSeesItsPlan() async throws {
        let (hub, link, device) = try await fixture()
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)

        let pairing = HubPairing(directory: device, deviceName: "Ada’s MacBook")
        await pairing.join(link.invite(ada).url().absoluteString)

        XCTAssertNil(pairing.error)
        XCTAssertEqual(pairing.status?.hubName, "Mac mini")
        XCTAssertEqual(pairing.status?.userName, "Ada")
        XCTAssertEqual(pairing.status?.planName, "Family")
        XCTAssertEqual(pairing.status?.harnesses, [LinkHarness(provider: "codex", providerName: "Codex", profileName: nil)])
        XCTAssertEqual(hub.access.devices.map(\.name), ["Ada’s MacBook"])
        XCTAssertEqual(hub.access.devices.first?.user, ada.id)
        XCTAssertEqual(hub.access.devices.first?.key.fingerprint, pairing.keyFingerprint)
    }

    func testThePairedDeviceIsRecognisedByItsKeyAfterARelaunch() async throws {
        let (hub, link, device) = try await fixture()
        let ada = try hub.access.addUser(named: "Ada")
        await HubPairing(directory: device, deviceName: "Mac").join(link.invite(ada).url().absoluteString)

        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        hub.access.move(ada, to: family)
        let relaunched = HubPairing(directory: device, deviceName: "Mac")
        XCTAssertEqual(relaunched.hub?.name, "Mac mini")
        await relaunched.refresh()
        XCTAssertNil(relaunched.error)
        XCTAssertEqual(relaunched.status?.planName, "Family")
        XCTAssertEqual(relaunched.status?.harnesses.map(\.provider), ["claude-code"])
        XCTAssertEqual(relaunched.endpoint?.host, "::1")
        XCTAssertNotNil(hub.access.devices.first?.lastSeen)
    }

    func testAnInvitationWorksOnce() async throws {
        let (hub, link, device) = try await fixture()
        let invitation = link.invite(try hub.access.addUser(named: "Ada")).url().absoluteString
        await HubPairing(directory: device, deviceName: "One").join(invitation)
        let second = HubPairing(directory: device.appendingPathExtension("2"), deviceName: "Two")
        await second.join(invitation)
        XCTAssertNotNil(second.error)
        XCTAssertNil(second.hub)
        XCTAssertEqual(hub.access.devices.map(\.name), ["One"])
    }

    func testExpiredInvitationsAreRefusedByTheHub() async throws {
        let (hub, link, device) = try await fixture()
        let invitation = link.invite(try hub.access.addUser(named: "Ada"))
        clock = clock.addingTimeInterval(LinkInvitation.lifetime + 1)
        // The device's own clock may be wrong, so the Hub checks too.
        await HubPairing(directory: device, deviceName: "Mac").join(invitation.url().absoluteString, now: invitation.expires.addingTimeInterval(-1))
        XCTAssertTrue(hub.access.devices.isEmpty)
    }

    func testRemovedDevicesAndUsersAreRefused() async throws {
        let (hub, link, device) = try await fixture()
        let ada = try hub.access.addUser(named: "Ada")
        let pairing = HubPairing(directory: device, deviceName: "Mac")
        await pairing.join(link.invite(ada).url().absoluteString)
        hub.access.remove(try XCTUnwrap(hub.access.devices.first))
        await pairing.refresh()
        XCTAssertNotNil(pairing.error)

        await pairing.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(pairing.error)
        hub.access.remove(ada)
        XCTAssertTrue(hub.access.devices.isEmpty)
        await pairing.refresh()
        XCTAssertNotNil(pairing.error)
    }

    func testInvitationsCarryTheManualAddressAndTheKey() async throws {
        let (hub, link, _) = try await fixture()
        link.manualAddress = "hub.example.com:4000"
        let invitation = link.invite(try hub.access.addUser(named: "Ada"))
        XCTAssertEqual(invitation.endpoints.last, LinkEndpoint(host: "hub.example.com", port: 4000))
        XCTAssertEqual(invitation.hubKey, link.key)
        XCTAssertEqual(invitation.expires, clock.addingTimeInterval(LinkInvitation.lifetime))
    }

    /// Exactly what the apps do on one Mac: the invitation lists this Mac's own addresses.
    func testPairingThroughThisMacsOwnAddresses() async throws {
        guard !LinkEndpoint.local(port: 1).isEmpty else { throw XCTSkip("This Mac has no network addresses.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, port: 0)
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        let invitation = link.invite(try hub.access.addUser(named: "Ada"))
        XCTAssertFalse(invitation.endpoints.contains { ["127.0.0.1", "::1", "localhost"].contains($0.host) })

        let pairing = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await pairing.join(invitation.url().absoluteString)
        XCTAssertNil(pairing.error)
        XCTAssertEqual(pairing.status?.userName, "Ada")
        XCTAssertTrue(invitation.endpoints.contains(try XCTUnwrap(pairing.endpoint)))
    }

    /// A development Hub listens on its own port so it can run beside the released one.
    func testTheHubListensOnThePortItIsGiven() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil, linkPort: 38_416)
        hub.link.manualAddress = "hub.example.com"
        XCTAssertEqual(hub.link.manualEndpoint, LinkEndpoint(host: "hub.example.com", port: 38_416))
    }

    func testDevicesThatCheckedInRecentlyCountAsConnected() async throws {
        let (hub, link, device) = try await fixture()
        let ada = try hub.access.addUser(named: "Ada")
        _ = try hub.access.addUser(named: "Grace")
        let pairing = HubPairing(directory: device, deviceName: "Mac")
        await pairing.join(link.invite(ada).url().absoluteString)
        XCTAssertEqual(link.connectedDevices.map(\.name), ["Mac"])
        XCTAssertEqual(link.connectedUsers.map(\.name), ["Ada"])

        clock = clock.addingTimeInterval(HubLinkService.presenceWindow + 1)
        XCTAssertTrue(link.connectedDevices.isEmpty)
        await pairing.refresh()
        XCTAssertEqual(link.connectedUsers.map(\.name), ["Ada"])
    }

    func testADeviceJoinsSeveralHubsAndLeavesOne() async throws {
        let (home, homeLink, device) = try await fixture()
        let (friend, friendLink, _) = try await fixture()
        let hubs = HubMemberships(directory: device, deviceName: "Mac")
        await hubs.join(homeLink.invite(try home.access.addUser(named: "Ada")).url().absoluteString)
        await hubs.join(friendLink.invite(try friend.access.addUser(named: "Ada")).url().absoluteString)
        XCTAssertNil(hubs.joinError)
        XCTAssertEqual(hubs.hubs.map(\.hub?.key), [homeLink.key, friendLink.key])
        // Each Hub sees its own key for this device, so Hubs cannot tell they share it.
        XCTAssertNotEqual(home.access.devices.first?.key, friend.access.devices.first?.key)

        hubs.leave(hubs.hubs[0])
        let relaunched = HubMemberships(directory: device, deviceName: "Mac")
        XCTAssertEqual(relaunched.hubs.map(\.hub?.key), [friendLink.key])
        await relaunched.hubs[0].refresh()
        XCTAssertNil(relaunched.hubs[0].error)
    }

    func testJoiningAHubAgainReplacesItsEntry() async throws {
        let (hub, link, device) = try await fixture()
        let ada = try hub.access.addUser(named: "Ada")
        let hubs = HubMemberships(directory: device, deviceName: "Mac")
        await hubs.join(link.invite(ada).url().absoluteString)
        await hubs.join(link.invite(ada).url().absoluteString)
        XCTAssertEqual(hubs.hubs.count, 1)
        XCTAssertEqual(hub.access.devices.count, 1)
    }

    func testAFailedJoinLeavesNothingBehind() async throws {
        let (hub, link, device) = try await fixture()
        let invitation = link.invite(try hub.access.addUser(named: "Ada")).url().absoluteString
        let hubs = HubMemberships(directory: device, deviceName: "Mac")
        await hubs.join(invitation)
        hubs.leave(hubs.hubs[0])
        await hubs.join(invitation)
        XCTAssertNotNil(hubs.joinError)
        XCTAssertTrue(hubs.hubs.isEmpty)
        XCTAssertTrue(HubMemberships(directory: device, deviceName: "Mac").hubs.isEmpty)
    }

    func testTheRoutersOutsideAddressReachesInvitationsAndPairedDevices() async throws {
        let outside = LinkEndpoint(host: "203.0.113.9", port: 38_415)
        let router = StandInRouter(.success(RouterMapping(endpoint: outside, method: .natPMP, lifetime: 3600)))
        let (hub, link, device) = try await fixture(router: router)
        XCTAssertEqual(link.router, .open(RouterMapping(endpoint: outside, method: .natPMP, lifetime: 3600)))
        let invitation = link.invite(try hub.access.addUser(named: "Ada"))
        XCTAssertTrue(invitation.endpoints.contains(outside))

        let pairing = HubPairing(directory: device, deviceName: "Phone")
        await pairing.join(invitation.url().absoluteString)
        XCTAssertEqual(pairing.hub?.endpoints.contains(outside), true)
    }

    func testTurningTheRouterPortOffClosesIt() async throws {
        let outside = LinkEndpoint(host: "203.0.113.9", port: 38_415)
        let router = StandInRouter(.success(RouterMapping(endpoint: outside, method: .upnp, lifetime: 0)))
        let (_, link, _) = try await fixture(router: router)
        let closed = expectation(description: "The router port is closed")
        await router.onUnmap { closed.fulfill() }

        link.opensRouterPort = false
        XCTAssertEqual(link.router, .off)
        XCTAssertFalse(link.endpoints.contains(outside))
        await fulfillment(of: [closed], timeout: 10)
    }

    func testTheRouterChoiceIsRemembered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, port: 0)
        XCTAssertTrue(link.opensRouterPort)
        link.opensRouterPort = false
        let relaunched = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Link"),
                                        access: hub.access, profiles: hub.harnessProfiles, port: 0)
        XCTAssertFalse(relaunched.opensRouterPort)
    }

    func testARouterThatCannotOpenThePortSaysWhy() async throws {
        let router = StandInRouter(.failure(RouterMappingError("The router has no public address.")))
        let (_, link, _) = try await fixture(router: router)
        XCTAssertEqual(link.router, .failed("The router has no public address."))
        XCTAssertEqual(link.endpoints, [LinkEndpoint(host: "::1", port: link.endpoints[0].port)])
    }
}

/// A router that answers from a script, so no test touches the real one.
private actor StandInRouter: RouterPortMapper {
    private let result: Result<RouterMapping, Error>
    private var unmapped: (@Sendable () -> Void)?

    init(_ result: Result<RouterMapping, Error>) { self.result = result }

    func onUnmap(_ action: @escaping @Sendable () -> Void) { unmapped = action }

    func map(port: UInt16) async throws -> RouterMapping { try result.get() }

    func unmap(_ mapping: RouterMapping) async { unmapped?() }
}
