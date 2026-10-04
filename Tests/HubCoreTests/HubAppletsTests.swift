import AppletBridge
import BrowserBridge
import ComputerBridge
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
        var controls: Gamepad?
        private(set) var opened: [UUID] = []
        /// The folder each noodlet came from.
        var sources: [UUID: String] = [:]
        /// What each noodlet's manifest asks for.
        var permissions: [UUID: [String: String]] = [:]
        /// What a noodlet's files archive to, larger than one piece.
        let archive = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0) })
        private(set) var calls: [(UUID?, NoodletStoreCall)] = []
        /// Whom each request was made for, in order.
        private(set) var asked: [(AppletOperation, String?)] = []

        func call(_ request: AppletRequest) -> AppletResponse {
            lock.withLock {
                asked.append((request.operation, request.owner))
                var response = AppletResponse()
                switch request.operation {
                case .archive:
                    response.artifactID = session
                    response.revision = "r1"
                    response.byteCount = archive.count
                    response.manifest = NoodletManifest(title: "Counter")
                case .artifact:
                    let offset = request.offset ?? 0
                    response.data = archive.subdata(in: offset..<min(archive.count, offset + 1_048_576))
                    response.done = offset + (response.data?.count ?? 0) >= archive.count
                case .store:
                    calls.append((request.noodletID, request.store!))
                    response.stored = .text("kept")
                case .open:
                    opened.append(request.noodletID ?? UUID())
                    response.sessionID = session
                    response.controls = controls
                case .list:
                    response.features = [SurfaceSocket.feature]
                case .info:
                    response.title = "Counter"
                    response.sourcePath = request.noodletID.flatMap { sources[$0] }
                    response.permissions = request.noodletID.flatMap { permissions[$0] }
                    if request.includePreview == true { response.data = Data("picture".utf8); response.mediaType = "image/png" }
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
        let link: HubLinkService
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-applets-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let applet = FakeApplet(), surfaces = FakeSurfaces(width: 640)
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil,
                      computer: { try HubComputersTests.FakeComputer().call($0) },
                      browser: { try HubBrowsersTests.FakeBrowser().call($0) }, applet: { applet.call($0) },
                      surfaces: SurfaceOpeners(applet: { try surfaces.open($0.sessionID!.uuidString) }))
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
        return Fixture(hub: hub, ada: ada, device: device, applet: applet, surfaces: surfaces, link: link)
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

    /// Someone a bot is shared with opens the noodlets it shares with them, but never the owner's
    /// computers or browsers, even through a link the bot posted in their conversation.
    func testSomeoneABotIsSharedWithOpensItsNoodletsButNotItsComputersOrBrowsers() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let grace = try f.hub.access.addUser(named: "Grace")
        _ = try f.hub.bots.share(bot.id, with: [grace.id], for: f.ada)
        let graces = try XCTUnwrap(try f.hub.bots.bots(for: grace).first)
        let device = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-grace-\(UUID())"),
                                deviceName: "Grace")
        addTeardownBlock { try? FileManager.default.removeItem(at: device.directory) }
        await device.join(f.link.invite(grace).url().absoluteString)

        let noodlet = try post(made(in: folder(of: bot, f), f), in: graces, byBot: true, hub: f.hub)
        let (channel, packets) = try await device.firstSurfacePackets(.openSurface(conversationID: graces.conversationID, attachmentID: noodlet))
        channel.cancel()
        XCTAssertEqual(packets.first?.width, 640)

        let computer = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        try f.hub.computers.assign([computer.id], to: bot.id, for: f.ada)
        let browser = try await f.hub.browsers.create(BrowserDraft(name: "Work"), for: f.ada)
        try f.hub.browsers.assign([browser.id], to: bot.id, for: f.ada)
        for url in [ComputerLink.url(computer: computer.id, terminal: UUID(), view: "terminal"),
                    BrowserLink.url(browser: browser.id, tab: UUID())] {
            let link = try f.hub.repository.importLinkAttachment(url, into: graces.conversationID, card: LinkCard(title: "Live"))
            _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: graces.conversationID, body: "Look",
                                                       attachmentIDs: [link.id])
            let opened = try? await device.firstSurfacePackets(.openSurface(conversationID: graces.conversationID, attachmentID: link.id))
            opened?.0.cancel()
            XCTAssertNil(opened, "\(url)")
        }
    }

    /// A game's controls come down before its video, so the phone shows them from the start.
    func testANoodletsControlsReachThePhone() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let controls = Gamepad(pads: [Gamepad.Pad(left: "left", right: "right")], buttons: [Gamepad.Button(key: "space")])
        f.applet.controls = controls
        let link = try post(made(in: folder(of: bot, f), f), in: bot, byBot: true, hub: f.hub)
        let channel = try await f.device.channel(.openSurface(conversationID: bot.conversationID, attachmentID: link))
        defer { channel.cancel() }
        var received: [Gamepad] = []
        for try await frame in channel.frames {
            if case .controls(let gamepad)? = LinkSurface.message(frame) { received.append(gamepad) }
            if case .packets? = LinkSurface.message(frame) { break }
        }
        XCTAssertEqual(received, [controls])
        channel.send(LinkSurface.control(.input(.hold(key: "space", pressed: true))))
        await waitUntil { !f.surfaces.inputs.isEmpty }
        XCTAssertEqual(f.surfaces.inputs.map(\.input), [.hold(key: "space", pressed: true)])
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

    /// Starting what a view shows can take longer than a request may wait, so the view opens at
    /// once; if what it shows then cannot start, the device still hears why.
    func testAViewThatCannotStartSaysWhy() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Kai", provider: "claude-code"), for: f.ada)
        let link = try post(made(in: folder(of: bot, f), f), in: bot, byBot: true, hub: f.hub)
        f.surfaces.refusal = "The noodlet stopped."
        let channel = try await f.device.channel(.openSurface(conversationID: bot.conversationID, attachmentID: link))
        defer { channel.cancel() }
        var reason: String?
        for try await frame in channel.frames {
            if case .failed(let why)? = LinkSurface.message(frame) { reason = why; break }
        }
        XCTAssertEqual(reason, "The noodlet stopped.")
    }

    /// A phone has no Applet of its own, so a noodlet's card asks the Hub for its picture, with
    /// the same rule as opening it.
    func testANoodletCardGetsItsPictureFromTheHub() async throws {
        let f = try await fixture()
        let kai = try f.hub.bots.create(LinkBotDraft(name: "Kai", provider: "claude-code"), for: f.ada)
        let eli = try f.hub.bots.create(LinkBotDraft(name: "Eli", provider: "claude-code"), for: f.ada)
        let own = try post(made(in: folder(of: kai, f), f), in: kai, byBot: true, hub: f.hub)
        let borrowed = try post(made(in: folder(of: eli, f), f), in: kai, byBot: true, hub: f.hub)
        let picture = try await f.device.request(.linkPreview(conversationID: kai.conversationID, attachmentID: own))
        XCTAssertEqual(picture, .picture(Data("picture".utf8)))
        do {
            _ = try await f.device.request(.linkPreview(conversationID: kai.conversationID, attachmentID: borrowed))
            XCTFail("another bot's noodlet showed its picture")
        } catch { XCTAssertEqual(error.localizedDescription, "That noodlet is not this bot's.") }
    }

    func testSharedNoodletCardResolvesTitleAndPreviewWithoutOpening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let applet = FakeApplet()
        let hub = Hub(root: root, messenger: nil, applet: { applet.call($0) })
        try hub.repository.prepare()
        let plan = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: plan)
        let user = try hub.access.addUser(named: "Ada")
        hub.access.move(user, to: plan)
        let bot = try hub.bots.create(LinkBotDraft(name: "Kai", provider: "claude-code"), for: user)
        let noodlet = UUID()
        applet.sources[noodlet] = hub.repository.directory(forAgentID: bot.id).appendingPathComponent("Counter.noodlet").path
        let attachment = try post(noodlet, in: bot, byBot: true, hub: hub)
        let card = try await hub.bots.card(of: attachment, in: bot.conversationID, for: user)
        XCTAssertEqual(card?.title, "Counter")
        XCTAssertEqual(card?.image, Data("picture".utf8))
        XCTAssertTrue(applet.opened.isEmpty)
        applet.sources[noodlet] = root.appendingPathComponent("SomeoneElse/Counter.noodlet").path
        do {
            _ = try await hub.bots.card(of: attachment, in: bot.conversationID, for: user)
            XCTFail("another bot's noodlet exposed its card")
        } catch { XCTAssertEqual(error.localizedDescription, "That noodlet is not this bot's.") }
    }

    /// A device running a noodlet itself fetches its files, and its page's calls on data and
    /// secrets come back to the noodlet here, a large one in pieces.
    func testANoodletItsBotSharedRunsOnTheDevice() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let noodlet = made(in: folder(of: bot, f), f)
        let link = try post(noodlet, in: bot, byBot: true, hub: f.hub)
        guard case .noodlet(let readied) = try await f.device.request(.noodlet(conversationID: bot.conversationID, attachmentID: link))
        else { return XCTFail("no noodlet") }
        XCTAssertEqual(readied.noodletID, noodlet)
        XCTAssertEqual(readied.revision, "r1")
        XCTAssertEqual(try JSONDecoder().decode(NoodletManifest.self, from: readied.manifest).title, "Counter")
        var files = Data()
        while files.count < readied.byteCount {
            guard case .chunk(let data, let total) = try await f.device.request(.noodletArchive(grant: readied.grant, offset: files.count))
            else { return XCTFail("no piece") }
            XCTAssertEqual(total, readied.byteCount)
            files.append(data)
        }
        XCTAssertEqual(files, f.applet.archive)

        let call = try JSONEncoder().encode(NoodletStoreCall(operation: "write", path: "a.txt", data: String(repeating: "x", count: 10)))
        let id = UUID(), half = call.count / 2
        let first = try await f.device.request(.noodletCall(LinkNoodletCall(grant: readied.grant, id: id, offset: 0, total: call.count,
                                                                            data: call.prefix(half))))
        XCTAssertEqual(first, .done)
        let last = try await f.device.request(.noodletCall(LinkNoodletCall(grant: readied.grant, id: id, offset: half, total: call.count,
                                                                           data: call.suffix(from: half))))
        guard case .noodletAnswer(let answer) = last else { return XCTFail("no answer") }
        XCTAssertEqual(try JSONDecoder().decode(NoodletValue.self, from: answer), .text("kept"))
        XCTAssertEqual(f.applet.calls.map(\.0), [noodlet])
        XCTAssertEqual(f.applet.calls.map(\.1), [NoodletStoreCall(operation: "write", path: "a.txt", data: String(repeating: "x", count: 10))])
    }

    /// Watching live, too, Applet checks the noodlet is the bot's as it starts it.
    func testTheHubStartsALiveNoodletAsTheBotThatSharedIt() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let link = try post(made(in: folder(of: bot, f), f), in: bot, byBot: true, hub: f.hub)
        let (channel, _) = try await f.device.firstSurfacePackets(.openSurface(conversationID: bot.conversationID, attachmentID: link))
        channel.cancel()
        let asked = f.applet.asked.filter { [.info, .open].contains($0.0) }
        XCTAssertEqual(asked.map(\.0), [.info, .info, .open])
        XCTAssertEqual(asked.map(\.1), Array(repeating: bot.id.uuidString.lowercased(), count: 3))
    }

    /// Applet checks too that the noodlet is the bot's, as it reads it: the Hub asks for its files
    /// and data as the bot that shared it, never as the Mac's own person.
    func testTheHubAsksForANoodletAsTheBotThatSharedIt() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let link = try post(made(in: folder(of: bot, f), f), in: bot, byBot: true, hub: f.hub)
        guard case .noodlet(let readied) = try await f.device.request(.noodlet(conversationID: bot.conversationID, attachmentID: link))
        else { return XCTFail("no noodlet") }
        _ = try await f.device.request(.noodletArchive(grant: readied.grant, offset: 0))
        let call = try JSONEncoder().encode(NoodletStoreCall(operation: "read", path: "a.txt"))
        _ = try await f.device.request(.noodletCall(LinkNoodletCall(grant: readied.grant, id: UUID(), offset: 0, total: call.count, data: call)))
        let asked = f.applet.asked.filter { [.info, .archive, .artifact, .store].contains($0.0) }
        XCTAssertEqual(asked.map(\.0), [.info, .archive, .artifact, .store])
        XCTAssertEqual(asked.map(\.1), Array(repeating: bot.id.uuidString.lowercased(), count: 4))
    }

    /// What one person's device readied is theirs alone; another user's device holding its grant gets nothing.
    func testAGrantIsItsUsersAlone() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let link = try post(made(in: folder(of: bot, f), f), in: bot, byBot: true, hub: f.hub)
        guard case .noodlet(let readied) = try await f.device.request(.noodlet(conversationID: bot.conversationID, attachmentID: link))
        else { return XCTFail("no noodlet") }
        let bob = try f.hub.access.addUser(named: "Bob")
        let other = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-bob-\(UUID())"), deviceName: "Phone")
        await other.join(f.link.invite(bob).url().absoluteString)
        for request: LinkRequest in [.noodletArchive(grant: readied.grant, offset: 0),
                                     .noodletCall(LinkNoodletCall(grant: readied.grant, id: UUID(), offset: 0, total: 2, data: Data("{}".utf8)))] {
            do {
                _ = try await other.request(request)
                XCTFail("another user used the grant")
            } catch { XCTAssertEqual(error.localizedDescription, "Open this noodlet again.") }
        }
        XCTAssertTrue(f.applet.calls.isEmpty)
    }

    /// The same rule as watching it live: only a noodlet from the bot's own folder runs on a device.
    func testAnotherBotsNoodletDoesNotRunOnTheDevice() async throws {
        let f = try await fixture()
        let kai = try f.hub.bots.create(LinkBotDraft(name: "Kai", provider: "claude-code"), for: f.ada)
        let eli = try f.hub.bots.create(LinkBotDraft(name: "Eli", provider: "claude-code"), for: f.ada)
        let borrowed = try post(made(in: folder(of: eli, f), f), in: kai, byBot: true, hub: f.hub)
        do {
            _ = try await f.device.request(.noodlet(conversationID: kai.conversationID, attachmentID: borrowed))
            XCTFail("another bot's noodlet was readied")
        } catch { XCTAssertEqual(error.localizedDescription, "That noodlet is not this bot's.") }
    }

    /// A noodlet that uses the camera, microphone or screen would get the Hub's if streamed, so
    /// the Hub never streams it, even to a device that cannot run it itself.
    func testANoodletThatSensesIsNeverStreamed() async throws {
        let f = try await fixture()
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let noodlet = made(in: folder(of: bot, f), f)
        f.applet.permissions[noodlet] = ["microphone": "not-requested"]
        let link = try post(noodlet, in: bot, byBot: true, hub: f.hub)
        let channel = try await f.device.channel(.openSurface(conversationID: bot.conversationID, attachmentID: link))
        defer { channel.cancel() }
        var refusal: String?
        do {
            for try await frame in channel.frames { if case .packets? = LinkSurface.message(frame) { break } }
        } catch { refusal = error.localizedDescription }
        XCTAssertEqual(refusal, "This noodlet uses the camera, microphone or screen, so it runs on your device. Update Noodle to open it.")
        XCTAssertEqual(f.applet.opened, [])
        guard case .noodlet = try await f.device.request(.noodlet(conversationID: bot.conversationID, attachmentID: link))
        else { return XCTFail("it did not open to run on the device") }
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
