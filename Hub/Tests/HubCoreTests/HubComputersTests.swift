import ComputerBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// Computers made for a user on the Hub are theirs, and reach a bot only when assigned to it.
@MainActor final class HubComputersTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let ada: HubUser
        let bob: HubUser
        let computer: FakeComputer
        let surfaces: FakeSurfaces
    }

    /// Noodle Computer on the Hub's Mac, as far as the Hub can tell.
    final class FakeComputer: @unchecked Sendable {
        private let lock = NSLock()
        private var computers: [RemoteComputer] = []
        private(set) var revoked: [(UUID, UUID)] = []

        func call(_ request: ComputerRequest) throws -> ComputerResponse {
            try lock.withLock {
                var response = ComputerResponse(computers: computers)
                response.capabilities = ComputerCapabilities()
                switch request.operation {
                case .templates:
                    response.templates = [ComputerTemplateSummary(id: "ubuntu", name: "Ubuntu", description: "", symbol: "terminal")]
                case .create:
                    let draft = try XCTUnwrap(request.computer)
                    let made = RemoteComputer(id: UUID(), name: draft.name, kind: "Linux", state: "Stopped", symbol: draft.symbol ?? "terminal")
                    computers.append(made)
                    response.computers = [made]
                case .update:
                    let index = try XCTUnwrap(computers.firstIndex { $0.id == request.computerID })
                    computers[index].name = request.computer?.name ?? computers[index].name
                    response.computers = [computers[index]]
                case .delete:
                    computers.removeAll { $0.id == request.computerID }
                case .revoke:
                    revoked.append((try XCTUnwrap(request.computerID), try XCTUnwrap(request.agentID)))
                default:
                    break
                }
                return response
            }
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-computers-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let computer = FakeComputer(), surfaces = FakeSurfaces(width: 1024)
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil, computer: { try computer.call($0) },
                      surfaces: SurfaceOpeners(computer: { surfaces.open("\($0.computerID!) \($0.terminalID!) \($0.agentID!)") }))
        try hub.repository.prepare()
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada"), bob = try hub.access.addUser(named: "Bob")
        hub.access.move(ada, to: family)
        hub.access.move(bob, to: family)
        return Fixture(hub: hub, ada: ada, bob: bob, computer: computer, surfaces: surfaces)
    }

    func testAComputerMadeForAUserReachesOnlyTheBotsItIsAssignedTo() async throws {
        let f = try fixture()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        try f.hub.bots.startTools()
        addTeardownBlock { await MainActor.run { f.hub.bots.stop() } }

        let templates = try await f.hub.computers.templates()
        XCTAssertEqual(templates.map(\.id), ["ubuntu"])
        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        XCTAssertEqual(f.hub.computers.computers(for: f.ada).map(\.id), [made.id])
        XCTAssertEqual(f.hub.computers.computers(for: f.bob), [])

        let agent = try XCTUnwrap(try f.hub.repository.loadAgents().first { $0.id == alfred.id })
        let skill = f.hub.repository.directory(for: agent).appendingPathComponent(".agents/skills/computer/SKILL.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path), "Making a computer gave it to a bot")
        try f.hub.computers.assign([made.id], to: alfred.id, for: f.ada)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: skill.path) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.path))
        XCTAssertEqual(f.hub.computers.assigned(to: alfred.id, for: f.ada), [made.id])

        let renamed = try await f.hub.computers.update(made.id, with: ComputerDraft(name: "Bench"), for: f.ada)
        XCTAssertEqual(renamed.name, "Bench")
    }

    func testOtherUsersCannotUseOrChangeAComputer() async throws {
        let f = try fixture()
        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        let bobs = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.bob)
        XCTAssertThrowsError(try f.hub.computers.assign([made.id], to: bobs.id, for: f.bob))
        do {
            _ = try await f.hub.computers.update(made.id, with: ComputerDraft(name: "Mine"), for: f.bob)
            XCTFail("Bob changed Ada's computer")
        } catch {}
    }

    func testTakingAComputerAwayEndsTheBotsTerminals() async throws {
        let f = try fixture()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        try f.hub.computers.assign([made.id], to: alfred.id, for: f.ada)
        try f.hub.computers.assign([], to: alfred.id, for: f.ada)
        for _ in 0..<50 where f.computer.revoked.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(f.computer.revoked.map(\.0), [made.id])
        XCTAssertEqual(f.computer.revoked.map(\.1), [alfred.id])
    }

    func testOnlyItsOwnerDeletesAComputerAndItsBotsLoseIt() async throws {
        let f = try fixture()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        try f.hub.computers.assign([made.id], to: alfred.id, for: f.ada)
        do {
            try await f.hub.computers.delete(made.id, for: f.bob)
            XCTFail("Bob deleted Ada's computer")
        } catch {}
        try await f.hub.computers.delete(made.id, for: f.ada)
        XCTAssertEqual(f.hub.computers.computers(for: f.ada), [])
        XCTAssertEqual(f.hub.computers.assigned(to: alfred.id, for: f.ada), [])
        XCTAssertNil(f.hub.access.owner(ofComputer: made.id))
    }

    /// Clicking a computer card in a Hub bot's conversation shows it live and takes the person's input,
    /// on the terminal the card shows and as the bot that owns it.
    func testAPersonWatchesAndUsesTheComputerACardPointsAt() async throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-computer-surface-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Link"),
                                  access: f.hub.access, profiles: f.hub.harnessProfiles, bots: f.hub.bots,
                                  connections: f.hub.connections, computers: f.hub.computers, browsers: f.hub.browsers, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(link.invite(f.ada).url().absoluteString)

        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        let bot = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let terminal = UUID()
        let attachment = try f.hub.repository.importLinkAttachment(ComputerLink.url(computer: made.id, terminal: terminal, view: "terminal"),
                                                                 into: bot.conversationID, card: LinkCard(title: made.name, detail: "$ ls"))
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Workbench",
                                                   attachmentIDs: [attachment.id])

        let (channel, packets) = try await device.firstSurfacePackets(.openSurface(conversationID: bot.conversationID, attachmentID: attachment.id))
        defer { channel.cancel() }
        XCTAssertEqual(packets.first?.width, 1024)
        channel.send(LinkSurface.control(.input(.key(.enter))))
        await waitUntil { !f.surfaces.inputs.isEmpty }
        XCTAssertEqual(f.surfaces.inputs.map(\.view), ["\(made.id) \(terminal) \(bot.id)"])
        XCTAssertEqual(f.surfaces.inputs.map(\.input), [.key(.enter)])
    }
}
