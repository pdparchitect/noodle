import BrowserBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// Browsers made for a user on the Hub are theirs, and reach a bot only when assigned to it.
@MainActor final class HubBrowsersTests: XCTestCase {
    /// Noodle Browser on the Hub's Mac, as far as the Hub can tell.
    final class FakeBrowser: @unchecked Sendable {
        private let lock = NSLock()
        private var browsers: [RemoteBrowser] = []

        func call(_ request: BrowserRequest) throws -> BrowserResponse {
            try lock.withLock {
                var response = BrowserResponse()
                switch request.operation {
                case .create:
                    let draft = try XCTUnwrap(request.profile)
                    let made = RemoteBrowser(id: UUID(), name: draft.name, description: draft.description)
                    browsers.append(made)
                    response.browser = made
                case .update:
                    let index = try XCTUnwrap(browsers.firstIndex { $0.id == request.browserID })
                    browsers[index].name = request.profile?.name ?? browsers[index].name
                    response.browser = browsers[index]
                case .delete:
                    browsers.removeAll { $0.id == request.browserID }
                default:
                    break
                }
                response.browsers = browsers
                return response
            }
        }
    }

    private func hub() throws -> (Hub, HubUser, HubUser) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-browsers-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let browser = FakeBrowser()
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil,
                      computer: { try HubComputersTests.FakeComputer().call($0) }, browser: { try browser.call($0) })
        try hub.repository.prepare()
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada"), bob = try hub.access.addUser(named: "Bob")
        hub.access.move(ada, to: family)
        hub.access.move(bob, to: family)
        return (hub, ada, bob)
    }

    func testABrowserMadeForAUserReachesOnlyTheBotsItIsAssignedTo() async throws {
        let (hub, ada, bob) = try hub()
        let alfred = try hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: ada)
        try hub.bots.startTools()
        addTeardownBlock { await MainActor.run { hub.bots.stop() } }

        let made = try await hub.browsers.create(BrowserDraft(name: "Work"), for: ada)
        XCTAssertEqual(hub.browsers.browsers(for: ada).map(\.id), [made.id])
        XCTAssertEqual(hub.browsers.browsers(for: bob), [])

        let agent = try XCTUnwrap(try hub.repository.loadAgents().first { $0.id == alfred.id })
        let skill = hub.repository.directory(for: agent).appendingPathComponent(".agents/skills/browser/SKILL.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path), "Making a browser gave it to a bot")
        try hub.browsers.assign([made.id], to: alfred.id, for: ada)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: skill.path) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.path))

        let renamed = try await hub.browsers.update(made.id, with: BrowserDraft(name: "Office"), for: ada)
        XCTAssertEqual(renamed.name, "Office")
    }

    func testOnlyItsOwnerUsesOrDeletesABrowser() async throws {
        let (hub, ada, bob) = try hub()
        let made = try await hub.browsers.create(BrowserDraft(name: "Work"), for: ada)
        let alfred = try hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: ada)
        let jeeves = try hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: bob)
        XCTAssertThrowsError(try hub.browsers.assign([made.id], to: jeeves.id, for: bob))
        try hub.browsers.assign([made.id], to: alfred.id, for: ada)
        do {
            try await hub.browsers.delete(made.id, for: bob)
            XCTFail("Bob deleted Ada's browser")
        } catch {}
        try await hub.browsers.delete(made.id, for: ada)
        XCTAssertEqual(hub.browsers.browsers(for: ada), [])
        XCTAssertEqual(hub.browsers.assigned(to: alfred.id, for: ada), [])
    }

    func testADeviceKeepsBrowsersOnTheHub() async throws {
        let (hub, ada, _) = try hub()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-browser-link-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, computers: hub.computers, browsers: hub.browsers, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(link.invite(ada).url().absoluteString)

        guard case .browser(let made) = try await device.request(.createBrowser(LinkBrowserDraft(name: "Work"))) else { return XCTFail("not made") }
        guard case .bot(let bot) = try await device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        _ = try await device.request(.assignBrowsers(botID: bot.id, browserIDs: [made.id]))
        guard case .browser(let renamed) = try await device.request(.updateBrowser(id: made.id, LinkBrowserDraft(name: "Office"))) else {
            return XCTFail("not renamed")
        }
        XCTAssertEqual(renamed.name, "Office")
        guard case .browsers(let listed) = try await device.request(.browsers) else { return XCTFail("not listed") }
        XCTAssertEqual(listed.map(\.id), [made.id])
        XCTAssertEqual(listed.first?.botIDs, [bot.id])
        _ = try await device.request(.deleteBrowser(id: made.id))
        guard case .browsers(let left) = try await device.request(.browsers) else { return XCTFail("not listed") }
        XCTAssertEqual(left, [])
    }
}
