import Foundation
@testable import HubCore
import HubLink
import HubMac
import NoodleCore
import XCTest

@MainActor final class HubSuspensionTests: XCTestCase {
    func testSuspensionStopsOnlyTheUsersBotsAndPreventsRestartUntilRestored() throws {
        let (runtime, processes) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-suspension-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil, runtime: runtime)
        try hub.repository.prepare()
        let ada = try hub.access.addUser(named: "Ada")
        let grace = try hub.access.addUser(named: "Grace")
        let a = try hub.repository.createAgent(named: "Ada Bot", harnessIdentifier: "codex").agent
        let b = try hub.repository.createAgent(named: "Grace Bot", harnessIdentifier: "codex").agent
        hub.access.setOwner(ada, ofBot: a.id)
        hub.access.setOwner(grace, ofBot: b.id)
        runtime.startAll(agents: [a, b], repository: hub.repository)
        XCTAssertEqual(processes().count, 2)
        hub.access.setSuspended(true, for: ada)
        XCTAssertFalse(try XCTUnwrap(processes().first { $0.configuration.id == a.id }).isAlive)
        XCTAssertTrue(try XCTUnwrap(processes().first { $0.configuration.id == b.id }).isAlive)
        runtime.startAll(agents: [a, b], repository: hub.repository)
        runtime.reconcile(agents: [a, b], repository: hub.repository, immediately: true)
        XCTAssertEqual(processes().count, 2)
        XCTAssertEqual(try hub.repository.loadAgents().count, 2)
        let restored = Hub(root: root, messenger: nil, runtime: runtime)
        XCTAssertEqual(restored.runtime.suspendedAgentIDs, [a.id])
        hub.access.setSuspended(false, for: ada)
        runtime.startAll(agents: [a, b], repository: hub.repository)
        XCTAssertEqual(processes().count, 3)
    }

    func testSuspensionInvalidatesAnOutstandingInvitation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-suspension-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        let user = try hub.access.addUser(named: "Ada")
        let join = try hub.link.invite(user).joinIdentity()
        let device = LinkIdentity()
        hub.access.setSuspended(true, for: user)
        let request = LinkRequest.enroll(deviceKey: device.publicKey,
                                        proof: try device.joinProof(for: join.publicKey), deviceName: "Mac")
        let reply = await hub.link.reply(to: try LinkProtocol.encode(request), from: join.publicKey)
        guard case .response(let data) = reply else { return XCTFail("Expected response") }
        XCTAssertEqual(try LinkProtocol.decodeResponse(data), .failure("This invitation is no longer valid. Ask for a new one."))
        XCTAssertTrue(hub.access.devices.isEmpty)
    }

    func testSuspendedDevicesCannotRequestOrSubscribeAndKeepTheirPairing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-suspension-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        let user = try hub.access.addUser(named: "Ada")
        let identity = LinkIdentity()
        let device = hub.access.addDevice(named: "Mac", key: identity.publicKey, for: user, at: Date())
        hub.access.setSuspended(true, for: user)
        for request: LinkRequest in [.status, .subscribe, .invite, .users] {
            let reply = await hub.link.reply(to: try LinkProtocol.encode(request), from: identity.publicKey)
            guard case .response(let data) = reply,
                  case .failure(let message) = try LinkProtocol.decodeResponse(data) else {
                return XCTFail("Suspended request was allowed")
            }
            XCTAssertEqual(message, "Your access to this Hub is suspended.")
        }
        XCTAssertEqual(hub.access.devices, [device])
        hub.access.setSuspended(false, for: user)
        let reply = await hub.link.reply(to: try LinkProtocol.encode(LinkRequest.status), from: identity.publicKey)
        guard case .response(let data) = reply,
              case .status = try LinkProtocol.decodeResponse(data) else {
            return XCTFail("Restored device could not check in")
        }
    }
}
