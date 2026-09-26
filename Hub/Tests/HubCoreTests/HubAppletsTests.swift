import AppletBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// Noodlets a Hub bot links to open live for its owner, and only those it made: a noodlet is the
/// bot's whose folder it came from. Applet keeps its own copy and does not decide this.
@MainActor final class HubAppletsTests: XCTestCase {
    /// Noodle Applet on the Hub's Mac, as far as the Hub can tell.
    final class FakeApplet: @unchecked Sendable {
        private let lock = NSLock()
        let session = UUID()
        private(set) var opened: [UUID] = []
        /// The folder each noodlet came from.
        var sources: [UUID: String] = [:]

        func call(_ request: AppletRequest) -> AppletResponse {
            lock.withLock {
                var response = AppletResponse()
                switch request.operation {
                case .open:
                    opened.append(request.noodletID ?? UUID())
                    response.sessionID = session
                case .info:
                    response.sourcePath = request.noodletID.flatMap { sources[$0] }
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
        let surfaces: FakeSurfaces
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-applets-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let applet = FakeApplet(), surfaces = FakeSurfaces(width: 640)
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil,
                      computer: { try HubComputersTests.FakeComputer().call($0) },
                      browser: { try HubBrowsersTests.FakeBrowser().call($0) }, applet: { applet.call($0) },
                      surfaces: SurfaceOpeners(applet: { surfaces.open($0.sessionID!.uuidString) }))
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
        return Fixture(hub: hub, ada: ada, device: device, applet: applet, surfaces: surfaces)
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

    /// A noodlet as a bot makes one: from a package in `folder`.
    private func made(in folder: URL, _ f: Fixture) -> UUID {
        let noodlet = UUID()
        f.applet.sources[noodlet] = folder.appendingPathComponent("Counter.noodlet").path
        return noodlet
    }

    private func folder(of bot: LinkBot, _ f: Fixture) -> URL { f.hub.repository.directory(forAgentID: bot.id) }

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
        let noodlet = made(in: folder(of: bot, f), f)
        let link = try post(noodlet, in: bot, byBot: true, hub: f.hub)

        let (channel, packets) = try await f.device.firstSurfacePackets(.openSurface(conversationID: bot.conversationID, attachmentID: link))
        defer { channel.cancel() }
        XCTAssertEqual(packets.first?.width, 640)
        XCTAssertEqual(f.applet.opened, [noodlet])
        channel.send(LinkSurface.control(.input(.text("go"))))
        await waitUntil { !f.surfaces.inputs.isEmpty }
        XCTAssertEqual(f.surfaces.inputs.map(\.view), [f.applet.session.uuidString])
        XCTAssertEqual(f.surfaces.inputs.map(\.input), [.text("go")])
    }

    /// A click is a press and a release; if the release overtook the press, the page would
    /// think the button stayed down and take no more clicks.
    func testInputReachesTheNoodletInTheOrderItWasSent() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let noodlet = made(in: folder(of: bot, f), f)
        let link = try post(noodlet, in: bot, byBot: true, hub: f.hub)
        let (channel, _) = try await f.device.firstSurfacePackets(.openSurface(conversationID: bot.conversationID, attachmentID: link))
        defer { channel.cancel() }
        let click: [SurfaceInput] = [.pointer(.down, x: 5, y: 5), .pointer(.up, x: 5, y: 5), .text("go")]
        click.forEach { channel.send(LinkSurface.control(.input($0))) }
        await waitUntil { f.surfaces.inputs.count == click.count }
        XCTAssertEqual(f.surfaces.inputs.map(\.input), click)
    }

    /// However the bot links to a noodlet from its folder, in its reply or by presenting it, it opens.
    func testANoodletFromItsBotsFolderOpensFromAPlainLink() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Kai", provider: "claude-code"), for: f.ada)
        let noodlet = made(in: folder(of: bot, f).appendingPathComponent("apps"), f)
        let link = try post(noodlet, in: bot, byBot: true, hub: f.hub)
        let opened = await opens(link, in: bot, f)
        XCTAssertTrue(opened, "a noodlet its bot made did not open")
    }

    func testNoodletsOfAnotherBotOrPostedByAPersonNeverOpen() async throws {
        let f = try await fixture()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let jeeves = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.ada)
        let theirs = made(in: folder(of: jeeves, f), f), unknown = UUID(), own = made(in: folder(of: alfred, f), f)
        let lookalike = made(in: URL(fileURLWithPath: folder(of: alfred, f).path + "-copy"), f)
        let borrowed = try post(theirs, in: alfred, byBot: true, hub: f.hub)
        let pasted = try post(unknown, in: alfred, byBot: true, hub: f.hub)
        let beside = try post(lookalike, in: alfred, byBot: true, hub: f.hub)
        let typed = try post(own, in: alfred, byBot: false, hub: f.hub)
        let isOpened = await opens(borrowed, in: alfred, f)
        XCTAssertFalse(isOpened, "another bot's noodlet opened")
        let isPasted = await opens(pasted, in: alfred, f)
        XCTAssertFalse(isPasted, "a noodlet from no bot's folder opened")
        let isBeside = await opens(beside, in: alfred, f)
        XCTAssertFalse(isBeside, "a folder named like the bot's counted as its")
        let isTyped = await opens(typed, in: alfred, f)
        XCTAssertFalse(isTyped, "a link the person posted opened")
        XCTAssertEqual(f.applet.opened, [])
    }
}
