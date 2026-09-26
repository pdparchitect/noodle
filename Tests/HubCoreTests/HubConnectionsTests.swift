import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// Tool connections belong to a user on the Hub and reach a bot only when assigned to it.
@MainActor final class HubConnectionsTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let ada: HubUser
        let bob: HubUser
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-connections-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        try hub.repository.prepare()
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada"), bob = try hub.access.addUser(named: "Bob")
        hub.access.move(ada, to: family)
        hub.access.move(bob, to: family)
        return Fixture(hub: hub, ada: ada, bob: bob)
    }

    private func connection(_ name: String) throws -> MCPConnectionRecord {
        try MCPConnectionRecord(name: name, endpoint: URL(string: "https://example.com/mcp")!, description: "Notes.")
    }

    private func skill(_ name: String, of bot: LinkBot, in hub: Hub) throws -> URL {
        let agent = try XCTUnwrap(try hub.repository.loadAgents().first { $0.id == bot.id })
        return hub.repository.directory(for: agent).appendingPathComponent(".agents/skills/\(name)/SKILL.md")
    }

    private func waitFor(_ exists: Bool, _ file: URL) async throws {
        for _ in 0..<50 where FileManager.default.fileExists(atPath: file.path) != exists {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testAConnectionReachesOnlyTheBotsItIsAssignedTo() async throws {
        let f = try fixture()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let jeeves = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.ada)
        try f.hub.bots.startTools()
        addTeardownBlock { await MainActor.run { f.hub.bots.stop() } }

        let notes = try f.hub.connections.add(try connection("Notes"), for: f.ada)
        XCTAssertEqual(f.hub.connections.connections(for: f.ada).map(\.id), [notes.id])
        let file = try skill(notes.skillName, of: alfred, in: f.hub)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Adding a connection gave it to a bot")

        try f.hub.connections.assign([notes.id], to: alfred.id, for: f.ada)
        try await waitFor(true, file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try skill(notes.skillName, of: jeeves, in: f.hub).path))
        XCTAssertEqual(f.hub.connections.assigned(to: alfred.id, for: f.ada), [notes.id])

        try f.hub.connections.assign([], to: alfred.id, for: f.ada)
        try await waitFor(false, file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testOtherUsersCannotSeeOrAssignAConnection() throws {
        let f = try fixture()
        let notes = try f.hub.connections.add(try connection("Notes"), for: f.ada)
        let bobs = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.bob)
        let adas = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        XCTAssertEqual(f.hub.connections.connections(for: f.bob), [])
        XCTAssertThrowsError(try f.hub.connections.assign([notes.id], to: bobs.id, for: f.bob))
        // Nor can Ada's connection go to Bob's bot, or Bob reach Ada's bot.
        XCTAssertThrowsError(try f.hub.connections.assign([notes.id], to: bobs.id, for: f.ada))
        XCTAssertThrowsError(try f.hub.connections.assign([], to: adas.id, for: f.bob))
    }

    func testRemovingAUserRemovesTheirConnections() throws {
        let f = try fixture()
        _ = try f.hub.connections.add(try connection("Notes"), for: f.ada)
        let kept = try f.hub.connections.add(try connection("Mail"), for: f.bob)
        f.hub.remove(f.ada)
        XCTAssertEqual(f.hub.connections.connections(for: f.bob).map(\.id), [kept.id])
        XCTAssertEqual(try MCPRegistry.load(root: f.hub.repository.rootURL).connections.map(\.id), [kept.id])
    }
}
