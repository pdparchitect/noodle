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
                    response.templates = offered
                case .create:
                    let draft = try XCTUnwrap(request.computer)
                    let made = RemoteComputer(id: UUID(), name: draft.name, kind: "Linux", state: "Stopped", symbol: draft.symbol ?? "terminal")
                    computers.append(made)
                    response.computers = [made]
                case .update:
                    let index = try XCTUnwrap(computers.firstIndex { $0.id == request.computerID })
                    computers[index].name = request.computer?.name ?? computers[index].name
                    // As Noodle Computer does: no description keeps the one it has, and an empty one clears it.
                    if let description = request.computer?.description { computers[index].description = description.isEmpty ? nil : description }
                    response.computers = [computers[index]]
                case .delete:
                    computers.removeAll { $0.id == request.computerID }
                case .revoke:
                    revoked.append((try XCTUnwrap(request.computerID), try XCTUnwrap(request.agentID)))
                case .idle:
                    response.idle = pendingIdle; pendingIdle = []
                case .setOwner:
                    guard knowsOwners else { throw ComputerBridgeError("This needs a newer app. Update it.") }
                    // Deleted before the Hub's word arrived, as can happen.
                    guard let index = computers.firstIndex(where: { $0.id == request.computerID }) else { throw ComputerBridgeError("No such computer.") }
                    computers[index].owner = request.owner
                default:
                    break
                }
                return response
            }
        }

        /// Whom Noodle Computer was last told a computer is kept for.
        func owner(of id: UUID) -> ComputerOwner? { lock.withLock { computers.first { $0.id == id }?.owner } }

        /// What Noodle Computer reports next as left running unused.
        var idle: [ComputerIdleNotice] {
            get { lock.withLock { pendingIdle } }
            set { lock.withLock { pendingIdle = newValue } }
        }
        private var pendingIdle: [ComputerIdleNotice] = []

        /// The kinds of computer it offers.
        var templates: [ComputerTemplateSummary] {
            get { lock.withLock { offered } }
            set { lock.withLock { offered = newValue } }
        }
        private var offered = [ComputerTemplateSummary(id: "ubuntu", name: "Ubuntu", description: "", symbol: "terminal")]

        /// False for one from before owners, which cannot read the request.
        var knowsOwners = true

        /// As a Noodle Computer from before it kept owners.
        func forgetOwners() { lock.withLock { for index in computers.indices { computers[index].owner = nil } } }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-computers-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let computer = FakeComputer(), surfaces = FakeSurfaces(width: 1024)
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil, computer: { try computer.call($0) },
                      surfaces: SurfaceOpeners(computer: { try surfaces.open("\($0.computerID!) \($0.terminalID!) \($0.agentID!)") }))
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

    func testAPlanLimitsHowManyComputersEachUserKeeps() async throws {
        let f = try fixture()
        let family = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.setComputerLimit(2, in: family)
        let first = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "One"), for: f.ada)
        _ = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Two"), for: f.ada)
        do {
            _ = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Three"), for: f.ada)
            XCTFail("Ada made more computers than the plan allows")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Your plan allows up to 2 computers. Delete one to make another.")
        }
        XCTAssertEqual(f.hub.computers.computers(for: f.ada).count, 2)
        // The limit is each user's own.
        _ = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Bob's"), for: f.bob)

        try await f.hub.computers.delete(first.id, for: f.ada)
        _ = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Three"), for: f.ada)
        XCTAssertEqual(f.hub.computers.computers(for: f.ada).count, 2)
    }

    /// A plan can let its users make only some kinds of computer. The Hub offers them only those and refuses
    /// the others, whatever a device asks for; computers they already have keep working.
    func testAPlanLimitsTheKindsOfComputerEachUserMakes() async throws {
        let f = try fixture()
        f.computer.templates = [ComputerTemplateSummary(id: "desktop", name: "Desktop", description: "", symbol: "desktopcomputer"),
                                ComputerTemplateSummary(id: "shell", name: "Shell", description: "", symbol: "terminal")]
        let family = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        let desk = try await f.hub.computers.create(ComputerDraft(template: "desktop", name: "Desk"), for: f.ada)
        f.hub.access.setComputerTypes(["shell"], in: family)

        let offered = try await f.hub.computers.templates(for: f.ada)
        XCTAssertEqual(offered.map(\.id), ["shell"])
        let all = try await f.hub.computers.templates()
        XCTAssertEqual(all.map(\.id), ["desktop", "shell"])
        for draft in [ComputerDraft(template: "desktop", name: "Another Desk"), ComputerDraft(name: "No Kind")] {
            do {
                _ = try await f.hub.computers.create(draft, for: f.ada)
                XCTFail("Ada made \(draft.name), a kind of computer her plan does not include")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Your plan does not include this kind of computer.")
            }
        }
        _ = try await f.hub.computers.create(ComputerDraft(template: "shell", name: "Shell"), for: f.ada)
        XCTAssertEqual(f.hub.computers.computers(for: f.ada).count, 2)

        // The one made before the plan changed is still hers to use and change.
        let renamed = try await f.hub.computers.update(desk.id, with: ComputerDraft(name: "Old Desk"), for: f.ada)
        XCTAssertEqual(renamed.name, "Old Desk")

        // Someone on another plan makes any kind.
        let carol = try f.hub.access.addUser(named: "Carol")
        let carols = try await f.hub.computers.templates(for: carol)
        XCTAssertEqual(carols.map(\.id), ["desktop", "shell"])
        _ = try await f.hub.computers.create(ComputerDraft(template: "desktop", name: "Carol's"), for: carol)

        // A plan none of whose kinds this Mac offers says so, rather than offer nothing.
        f.hub.access.setComputerTypes(["windows"], in: family)
        do {
            _ = try await f.hub.computers.templates(for: f.ada)
            XCTFail("Ada was offered no kind of computer without a reason")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Your plan does not include any kind of computer this Hub offers.")
        }
    }

    /// Computers asked for at once count those still being made.
    func testComputersMadeAtOnceKeepToThePlan() async throws {
        let f = try fixture()
        let family = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.setComputerLimit(1, in: family)
        let computers = f.hub.computers, ada = f.ada
        async let one = try? computers.create(ComputerDraft(template: "ubuntu", name: "One"), for: ada)
        async let two = try? computers.create(ComputerDraft(template: "ubuntu", name: "Two"), for: ada)
        let made = await [one, two].compactMap { $0 }
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(f.hub.computers.computers(for: f.ada).count, 1)
    }

    func testABotIsToldOfAComputerItLeftRunningUnused() async throws {
        let f = try fixture()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        f.computer.idle = [ComputerIdleNotice(computerID: UUID(), agentID: alfred.id, note: "Workbench is unused"),
                           ComputerIdleNotice(computerID: UUID(), agentID: UUID(), note: "Not a bot here")]
        await f.hub.bots.checkIdleComputers()
        var notes: [String] = []
        for _ in 0..<50 where notes.isEmpty {
            notes += try f.hub.repository.listWakes(agentID: alfred.id).due.map(\.note)
            if notes.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(notes, ["Workbench is unused"])
    }

    /// Noodle Computer lists the Hub's computers under the people they are kept for.
    func testNoodleComputerIsToldWhomEachComputerIsFor() async throws {
        let f = try fixture()
        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        func owner(_ expected: ComputerOwner?) async throws {
            for _ in 0..<50 where f.computer.owner(of: made.id) != expected { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(f.computer.owner(of: made.id), expected)
        }
        try await owner(ComputerOwner(id: f.ada.id, name: "Ada"))
        try f.hub.access.rename(f.ada, to: "Ada Lovelace")
        try await owner(ComputerOwner(id: f.ada.id, name: "Ada Lovelace"))
        // One that lost it, as when it was made before Noodle Computer kept owners, gets it back.
        f.computer.forgetOwners()
        await f.hub.computers.refresh()
        try await owner(ComputerOwner(id: f.ada.id, name: "Ada Lovelace"))
        f.hub.remove(f.ada)
        try await owner(nil)
    }

    /// A Noodle Computer from before owners refuses the Hub's word; its computers still work, under Hub alone.
    func testAComputerAppFromBeforeOwnersStillWorks() async throws {
        let f = try fixture()
        f.computer.knowsOwners = false
        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        await f.hub.computers.refresh()
        XCTAssertEqual(f.hub.computers.computers(for: f.ada).map(\.id), [made.id])
        XCTAssertNil(f.computer.owner(of: made.id))
        // Once updated, the next refresh names the owner.
        f.computer.knowsOwners = true
        await f.hub.computers.refresh()
        XCTAssertEqual(f.computer.owner(of: made.id), ComputerOwner(id: f.ada.id, name: "Ada"))
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

    /// Its owner renames and describes a computer; no description keeps the one it has, and an empty one clears it.
    func testOnlyItsOwnerRenamesOrDescribesAComputer() async throws {
        let f = try fixture()
        let made = try await f.hub.computers.create(ComputerDraft(template: "ubuntu", name: "Workbench"), for: f.ada)
        let described = try await f.hub.computers.update(made.id, with: ComputerDraft(name: "Bench", description: "For builds"), for: f.ada)
        XCTAssertEqual(f.hub.computers.link(described, for: f.ada).description, "For builds")
        do {
            _ = try await f.hub.computers.update(made.id, with: ComputerDraft(name: "Mine", description: ""), for: f.bob)
            XCTFail("Bob changed Ada's computer")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That computer is not yours or no longer exists.")
        }
        XCTAssertEqual(f.hub.computers.link(for: f.ada).map(\.name), ["Bench"])
        XCTAssertEqual(f.hub.computers.link(for: f.ada).first?.description, "For builds")

        _ = try await f.hub.computers.update(made.id, with: ComputerDraft(name: "Builds"), for: f.ada)
        XCTAssertEqual(f.hub.computers.link(for: f.ada).first?.description, "For builds")
        _ = try await f.hub.computers.update(made.id, with: ComputerDraft(name: "Builds", description: ""), for: f.ada)
        XCTAssertEqual(f.hub.computers.link(for: f.ada).map(\.name), ["Builds"])
        XCTAssertNil(f.hub.computers.link(for: f.ada).first?.description)
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
