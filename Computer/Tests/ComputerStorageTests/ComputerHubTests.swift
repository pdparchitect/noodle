import ComputerBridge
import ComputerCore
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

@MainActor final class ComputerHubTests: XCTestCase {
    func testComputersTheHubUsesAreListedAsHub() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root), identity = ComputerBuildIdentity.current
        let computer = Computer(name: "Shell", kind: .container)
        try FileManager.default.createDirectory(at: store.library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        let session = ComputerSession(try store.library.commit(computer))
        store.sessions = [session]
        store.note(session, usedBy: identity.noodleIDs[0])
        XCTAssertNil(session.computer.hub)
        store.note(session, usedBy: identity.hubID)
        XCTAssertEqual(session.computer.hub, true)
        XCTAssertEqual(try store.library.load().first?.hub, true)
    }

    /// A computer made through the provider, as the Hub makes its own, leaves the person's selection, and so their space, alone.
    func testComputersMadeForOthersLeaveTheSelectionAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let mine = Computer(name: "Mine", kind: .localMac)
        let created = await store.create(mine, source: nil)
        XCTAssertTrue(created)
        XCTAssertEqual(store.selection, mine.id)
        let made = await store.create(Computer(name: "Made", kind: .localMac), source: nil, selects: false)
        XCTAssertTrue(made)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.selection, mine.id)
    }

    func testOnlyTheHubSaysWhomAComputerIsKeptFor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root), identity = ComputerBuildIdentity.current
        let computer = Computer(name: "Shell", kind: .container)
        try FileManager.default.createDirectory(at: store.library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        let session = ComputerSession(try store.library.commit(computer))
        store.sessions = [session]
        XCTAssertThrowsError(try store.setHubOwner(session, HubOwner(id: UUID(), name: "Eve"), from: identity.noodleIDs[0]))
        XCTAssertNil(session.computer.hubOwner)
        let ada = HubOwner(id: UUID(), name: "Ada")
        try store.setHubOwner(session, ada, from: identity.hubID)
        XCTAssertEqual(session.computer.hubOwner, ada)
        XCTAssertEqual(session.computer.hub, true)
        XCTAssertEqual(try store.library.load().first?.hubOwner, ada)
        try store.setHubOwner(session, nil, from: identity.hubID)
        XCTAssertNil(try store.library.load().first?.hubOwner)
    }

    func testTheHubsComputersAreGroupedByPerson() {
        let ada = HubOwner(id: UUID(), name: "Ada"), bob = HubOwner(id: UUID(), name: "Bob")
        func session(_ name: String, _ owner: HubOwner?) -> ComputerSession {
            var computer = Computer(name: name, kind: .container)
            computer.hub = true
            computer.hubOwner = owner
            return ComputerSession(computer)
        }
        let sessions = [session("Build", bob), session("Shell", ada), session("Loose", nil), session("Lab", ada)]
        let groups = ComputerStore.hubGroups(sessions)
        XCTAssertEqual(groups.people.map(\.owner), [ada, bob])
        XCTAssertEqual(groups.people.first?.sessions.map(\.computer.name), ["Shell", "Lab"])
        XCTAssertEqual(groups.unowned.map(\.computer.name), ["Loose"])
    }

    /// The Hub's word arrives as a request, and every client sees the owner in the list.
    func testTheHubSaysWhomAComputerIsKeptForThroughItsRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root), identity = ComputerBuildIdentity.current
        let provider = try ComputerProvider(store: store, socket: root.appendingPathComponent("computer.sock"), listens: false)
        let computer = Computer(name: "Shell", kind: .container)
        try FileManager.default.createDirectory(at: store.library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        store.sessions = [ComputerSession(try store.library.commit(computer))]
        var request = ComputerRequest(.setOwner, computerID: computer.id)
        request.owner = ComputerOwner(id: UUID(), name: "Eve")
        do { _ = try await provider.handle(request, peer: identity.noodleIDs[0]); XCTFail("Noodle said whom a computer is for") } catch {}
        let ada = ComputerOwner(id: UUID(), name: "Ada")
        request.owner = ada
        _ = try await provider.handle(request, peer: identity.hubID)
        for peer in [identity.hubID, identity.noodleIDs[0]] {
            let listed = try await provider.handle(ComputerRequest(.list), peer: peer).computers
            XCTAssertEqual(listed?.first?.owner, ada)
        }
        request.owner = nil
        _ = try await provider.handle(request, peer: identity.hubID)
        let cleared = try await provider.handle(ComputerRequest(.list), peer: identity.hubID).computers
        XCTAssertNil(cleared?.first?.owner)
    }

    /// Records saved before computers kept their owner still load, with none.
    func testRecordsFromBeforeOwnersLoad() throws {
        var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Computer(name: "Old", kind: .container))) as! [String: Any]
        record["hub"] = true
        record.removeValue(forKey: "hubOwner")
        let decoded = try JSONDecoder().decode(Computer.self, from: JSONSerialization.data(withJSONObject: record))
        XCTAssertEqual(decoded.hub, true)
        XCTAssertNil(decoded.hubOwner)
    }
}
