import ComputerBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// A paired device making and assigning computers on the Hub, over real QUIC on this Mac.
@MainActor final class HubComputerLinkTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let ada: HubUser
        let device: HubPairing
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-computer-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let computer = HubComputersTests.FakeComputer()
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil, computer: { try computer.call($0) })
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, computers: hub.computers, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(device.error)
        return Fixture(hub: hub, ada: ada, device: device)
    }

    func testADeviceMakesAndAssignsComputersOnTheHub() async throws {
        let f = try await fixture()
        guard case .computerTemplates(let templates) = try await f.device.request(.computerTemplates) else { return XCTFail("no templates") }
        XCTAssertEqual(templates.map(\.id), ["ubuntu"])

        let events = try await f.device.subscribe()
        let requestID = UUID()
        _ = try await f.device.request(.createComputer(requestID: requestID, LinkComputerDraft(template: "ubuntu", name: "Workbench")))
        var made: LinkComputer?
        for try await event in events {
            if case .computerCreated(let id, let computer, let error) = event, id == requestID {
                XCTAssertNil(error)
                made = computer
                break
            }
        }
        let computer = try XCTUnwrap(made)
        XCTAssertEqual(computer.name, "Workbench")

        guard case .bot(let bot) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        _ = try await f.device.request(.assignComputers(botID: bot.id, computerIDs: [computer.id]))
        guard case .computer(let renamed) = try await f.device.request(.updateComputer(id: computer.id, LinkComputerDraft(name: "Bench"))) else {
            return XCTFail("not renamed")
        }
        XCTAssertEqual(renamed.name, "Bench")
        guard case .computers(let listed) = try await f.device.request(.computers) else { return XCTFail("not listed") }
        XCTAssertEqual(listed.map(\.id), [computer.id])
        XCTAssertEqual(listed.first?.botIDs, [bot.id])
        XCTAssertEqual(listed.first?.name, "Bench")
    }
}
