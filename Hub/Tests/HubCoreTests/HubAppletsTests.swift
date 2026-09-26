import AppletBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// Noodlets a Hub bot shares open live for its owner, and only those: Applet does not know whose
/// a noodlet is, so the Hub decides from which bot shared it.
@MainActor final class HubAppletsTests: XCTestCase {
    /// Noodle Applet on the Hub's Mac, as far as the Hub can tell.
    final class FakeApplet: @unchecked Sendable {
        private let lock = NSLock()
        let session = UUID()
        private(set) var opened: [UUID] = []
        private(set) var inputs: [(UUID?, SurfaceInput)] = []

        func call(_ request: AppletRequest) -> AppletResponse {
            lock.withLock {
                var response = AppletResponse()
                switch request.operation {
                case .open:
                    opened.append(request.noodletID ?? UUID())
                    response.sessionID = session
                case .surfaceFrame:
                    response.surfacePackets = SurfacePacket.encode([SurfacePacket(sequence: 1, keyFrame: true, width: 640, height: 480, parameterSets: [Data([1]), Data([2])], sample: Data([3]))])
                case .surfaceInput:
                    if let input = request.surfaceInput { inputs.append((request.sessionID, input)) }
                default:
                    break
                }
                return response
            }
        }
    }

    private struct Fixture {
        let hub: Hub
        let ada: HubUser
        let device: HubPairing
        let applet: FakeApplet
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-applets-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let applet = FakeApplet()
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil,
                      computer: { try HubComputersTests.FakeComputer().call($0) },
                      browser: { try HubBrowsersTests.FakeBrowser().call($0) }, applet: { applet.call($0) })
        try hub.repository.prepare()
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, computers: hub.computers, browsers: hub.browsers, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(link.invite(ada).url().absoluteString)
        return Fixture(hub: hub, ada: ada, device: device, applet: applet)
    }

    /// Posts a noodlet link into a conversation, as the bot or as its owner.
    private func post(_ noodlet: UUID, in bot: LinkBot, byBot: Bool, hub: Hub) throws -> UUID {
        let link = try hub.repository.importLinkAttachment(NoodletLink.url(for: noodlet), into: bot.conversationID)
        if byBot {
            _ = try hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Game", attachmentIDs: [link.id])
        } else {
            _ = try hub.repository.sendUserMessage(conversationID: bot.conversationID, body: "Game", attachmentIDs: [link.id])
        }
        return link.id
    }

    private func opens(_ attachment: UUID, in bot: LinkBot, _ f: Fixture) async -> Bool {
        guard let channel = try? await f.device.channel(.openSurface(conversationID: bot.conversationID, attachmentID: attachment)) else { return false }
        defer { channel.cancel() }
        do {
            for try await frame in channel.frames { if case .packets? = LinkSurface.message(frame) { return true } }
        } catch {}
        return false
    }

    func testANoodletItsBotSharedOpensLiveAndTakesInput() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let noodlet = UUID()
        f.hub.bots.applets.onShared?(noodlet, bot.id, bot.conversationID)
        let link = try post(noodlet, in: bot, byBot: true, hub: f.hub)

        let (channel, packets) = try await f.device.firstSurfacePackets(.openSurface(conversationID: bot.conversationID, attachmentID: link))
        defer { channel.cancel() }
        XCTAssertEqual(packets.first?.width, 640)
        XCTAssertEqual(f.applet.opened, [noodlet])
        channel.send(LinkSurface.input(.text("go")))
        await waitUntil { !f.applet.inputs.isEmpty }
        XCTAssertEqual(f.applet.inputs.map(\.0), [f.applet.session])
        XCTAssertEqual(f.applet.inputs.map(\.1), [.text("go")])
    }

    func testNoodletsOfAnotherBotOrPostedByAPersonNeverOpen() async throws {
        let f = try await fixture()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let jeeves = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.ada)
        let theirs = UUID(), unknown = UUID(), own = UUID()
        f.hub.bots.applets.onShared?(theirs, jeeves.id, jeeves.conversationID)
        f.hub.bots.applets.onShared?(own, alfred.id, alfred.conversationID)
        let borrowed = try post(theirs, in: alfred, byBot: true, hub: f.hub)
        let pasted = try post(unknown, in: alfred, byBot: true, hub: f.hub)
        let typed = try post(own, in: alfred, byBot: false, hub: f.hub)
        let isOpened = await opens(borrowed, in: alfred, f)
        XCTAssertFalse(isOpened, "another bot's noodlet opened")
        let isPasted = await opens(pasted, in: alfred, f)
        XCTAssertFalse(isPasted, "a noodlet no bot shared opened")
        let isTyped = await opens(typed, in: alfred, f)
        XCTAssertFalse(isTyped, "a link the person posted opened")
        XCTAssertEqual(f.applet.opened, [])
    }
}
