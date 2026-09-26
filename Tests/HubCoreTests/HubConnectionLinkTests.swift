import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// A paired device keeping tool connections on the Hub, over real QUIC on this Mac.
@MainActor final class HubConnectionLinkTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let link: HubLinkService
        let ada: HubUser
        let device: HubPairing
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-connection-link-\(UUID())")
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
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(device.error)
        return Fixture(hub: hub, link: link, ada: ada, device: device)
    }

    private let draft = LinkConnectionDraft(name: "Notes", endpoint: URL(string: "https://example.com/mcp")!, description: "Notes.")

    func testADeviceKeepsItsConnectionsOnTheHub() async throws {
        let f = try await fixture()
        guard case .connection(let saved) = try await f.device.request(.saveConnection(draft)) else { return XCTFail("not saved") }
        XCTAssertEqual(saved.draft, draft)
        XCTAssertFalse(saved.signedIn)
        guard case .bot(let bot) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        _ = try await f.device.request(.assignConnections(botID: bot.id, connectionIDs: [saved.id]))
        guard case .connections(let listed) = try await f.device.request(.connections) else { return XCTFail("not listed") }
        XCTAssertEqual(listed.map(\.id), [saved.id])
        XCTAssertEqual(listed.first?.botIDs, [bot.id])

        _ = try await f.device.request(.deleteConnection(id: saved.id))
        guard case .connections(let left) = try await f.device.request(.connections) else { return XCTFail("not listed") }
        XCTAssertEqual(left, [])
    }

    func testSigningInUsesTheDevicesBrowserAndKeepsTheSignInOnTheHub() async throws {
        let f = try await fixture()
        guard case .connection(let saved) = try await f.device.request(.saveConnection(draft)) else { return XCTFail("not saved") }
        let page = URL(string: "https://auth.example.com/authorize?state=s1")!
        let redirect = URL(string: "noodle://mcp/oauth/callback")!
        let callback = URL(string: "noodle://mcp/oauth/callback?code=c1&state=s1")!
        f.hub.connections.signInFlow = { record, redirectURI, browser in
            XCTAssertEqual(record.id, saved.id)
            XCTAssertEqual(redirectURI, redirect)
            let returned = try await browser(page)
            XCTAssertEqual(returned, callback)
            return nil
        }
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.signIn(connectionID: saved.id, redirect: redirect))
        var signedIn = false
        for try await event in events {
            switch event {
            case .signInPage(let id, let url):
                XCTAssertEqual(id, saved.id)
                XCTAssertEqual(url, page)
                _ = try await f.device.request(.finishSignIn(connectionID: id, callback: callback))
            case .connectionsChanged:
                guard case .connections(let listed) = try await f.device.request(.connections) else { return XCTFail("not listed") }
                signedIn = listed.first?.signedIn == true
            default:
                break
            }
            if signedIn { break }
        }
        XCTAssertTrue(signedIn)
    }
}
