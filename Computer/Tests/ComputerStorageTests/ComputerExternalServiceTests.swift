import ComputerBridge
import ComputerCore
import ComputerExternal
import XCTest
@testable import NoodleComputer

@MainActor private final class Answers: ExternalPrompting {
    var approve = true
    var pick: (([ExternalItem]) -> UUID?)?
    var confirm = false
    var asked: [String] = []
    func approve(_ launcher: ExternalLauncher) async -> Bool { asked.append("approve"); return approve }
    func pick(_ launcher: ExternalLauncher, from items: [ExternalItem]) async -> UUID? {
        asked.append("pick " + items.map(\.name).sorted().joined(separator: ",")); return pick?(items)
    }
    func confirm(_ launcher: ExternalLauncher, message: String, action: String) async -> Bool { asked.append("confirm " + message); return confirm }
}

private let claude = ExternalLauncher(key: "team:Q6L2SF6YDW:com.anthropic.claude-code", name: "Claude Code", path: "/c")
private let codex = ExternalLauncher(key: "team:2DC432GLL2:com.openai.codex", name: "Codex", path: "/x")

@MainActor final class ComputerExternalServiceTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func service(_ answers: Answers, enabled: Bool = true) throws -> (ComputerExternalService, ComputerStore) {
        let store = try ComputerStore(root: root)
        let provider = try ComputerProvider(store: store, socket: root.appendingPathComponent("computer.sock"), listens: false)
        let gate = ExternalGate(url: nil, prompter: answers)
        gate.enabled = enabled
        return (ComputerExternalService(store: store, provider: provider, gate: gate, stagingRoot: root), store)
    }

    @discardableResult private func add(_ store: ComputerStore, _ name: String, hub: Bool = false) throws -> ComputerSession {
        var computer = Computer(name: name, kind: .container)
        if hub { computer.hub = true }
        try FileManager.default.createDirectory(at: store.library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        let session = ComputerSession(try store.library.commit(computer))
        store.sessions.append(session)
        return session
    }

    func testNothingIsServedWhileExternalToolsAreOff() async throws {
        let answers = Answers()
        let (service, _) = try service(answers, enabled: false)
        do { _ = try await service.perform(.init(.list), launcher: claude); XCTFail("Served while off") } catch {}
        XCTAssertTrue(answers.asked.isEmpty)
    }

    func testCallersListOnlyWhatTheyMadeOrBorrowed() async throws {
        let answers = Answers()
        let (service, store) = try service(answers)
        let mine = try add(store, "Mine"), personal = try add(store, "Personal")
        try add(store, "Hub's", hub: true)
        let caller = try await service.gate.admit(claude)
        service.gate.recordCreated(mine.id, by: caller.id)
        let listed = try await service.perform(.init(.list), launcher: claude)
        XCTAssertEqual(listed.computers?.map(\.id), [mine.id])
        XCTAssertNil(listed.capabilities)
        let other = try await service.perform(.init(.list), launcher: codex)
        XCTAssertEqual(other.computers?.map(\.id), [])
        answers.pick = { items in items.first { $0.name == "Personal" }?.id }
        let lent = try await service.perform(.init(.borrow), launcher: claude)
        XCTAssertEqual(lent.computers?.map(\.id), [personal.id])
        // The Hub's computers are never offered; what the caller has is not offered again.
        XCTAssertEqual(answers.asked.last, "pick Personal")
    }

    func testComputersNotLentCannotBeUsed() async throws {
        let answers = Answers()
        let (service, store) = try service(answers)
        let personal = try add(store, "Personal"), hub = try add(store, "Hub's", hub: true)
        _ = try await service.perform(.init(.list), launcher: claude)
        for operation: ComputerOperation in [.start, .terminalOpen] {
            do { _ = try await service.perform(.init(operation, computerID: personal.id), launcher: claude); XCTFail("\(operation) on a computer not lent") } catch {}
        }
        service.gate.setAccess(true, to: hub.id, for: service.gate.grants.callers[0].id)
        do { _ = try await service.perform(.init(.start, computerID: hub.id), launcher: claude); XCTFail("Used the Hub's computer") } catch {}
    }

    func testMakingAComputerAlwaysAsks() async throws {
        let answers = Answers()
        let (service, store) = try service(answers)
        let template = try XCTUnwrap(ContainerRegistry.bundled.templates.first)
        var request = ComputerRequest(.create)
        request.computer = ComputerDraft(template: template.id, name: "Build box")
        do { _ = try await service.perform(request, launcher: claude); XCTFail("Made a computer without asking") } catch {}
        XCTAssertEqual(answers.asked.last, "confirm “Claude Code” wants to create a computer: \(template.name).")
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testOnlyComputersACallerMadeCanBeChangedOrDeleted() async throws {
        let answers = Answers()
        let (service, store) = try service(answers)
        let mine = try add(store, "Mine"), personal = try add(store, "Personal")
        let caller = try await service.gate.admit(claude)
        service.gate.recordCreated(mine.id, by: caller.id)
        service.gate.setAccess(true, to: personal.id, for: caller.id)
        var rename = ComputerRequest(.update, computerID: personal.id)
        rename.computer = ComputerDraft(name: "Taken")
        do { _ = try await service.perform(rename, launcher: claude); XCTFail("Renamed a lent computer") } catch {}
        do { _ = try await service.perform(.init(.delete, computerID: personal.id), launcher: claude); XCTFail("Deleted a lent computer") } catch {}
        XCTAssertEqual(personal.computer.name, "Personal")
        rename.computerID = mine.id
        _ = try await service.perform(rename, launcher: claude)
        XCTAssertEqual(mine.computer.name, "Taken")
        _ = try await service.perform(.init(.delete, computerID: mine.id), launcher: claude)
        XCTAssertFalse(store.sessions.contains { $0.id == mine.id })
        XCTAssertFalse(service.gate.allows(caller.id, mine.id))
    }

    func testWhatNoodleAndTheHubAloneDoIsRefused() async throws {
        let answers = Answers()
        let (service, store) = try service(answers)
        let mine = try add(store, "Mine")
        let caller = try await service.gate.admit(claude)
        service.gate.recordCreated(mine.id, by: caller.id)
        var owner = ComputerRequest(.setOwner, computerID: mine.id); owner.owner = ComputerOwner(id: UUID(), name: "Eve")
        for request in [owner, ComputerRequest(.surfaceStream, computerID: mine.id), ComputerRequest(.preview, computerID: mine.id),
                        ComputerRequest(.revoke, computerID: mine.id), ComputerRequest(.terminalResolve, terminalID: UUID())] {
            do { _ = try await service.perform(request, launcher: claude); XCTFail("\(request.operation) served") } catch {}
        }
    }

    /// Computers an outside app made are listed apart; ones it borrowed stay the person's own.
    func testComputersOutsideAppsMadeAreListedUnderExternalTools() {
        let own = ComputerSession(Computer(name: "Own", kind: .container)), made = ComputerSession(Computer(name: "Made", kind: .container))
        var hubComputer = Computer(name: "Hub's", kind: .container); hubComputer.hub = true
        let sections = ComputerExternalService.sections([own, made, ComputerSession(hubComputer)], created: [made.id])
        XCTAssertEqual(sections.own.map(\.computer.name), ["Own"])
        XCTAssertEqual(sections.external.map(\.computer.name), ["Made"])
        XCTAssertEqual(sections.hub.map(\.computer.name), ["Hub's"])
    }

    /// Switching a computer off for an app, or removing the app, closes the terminals it opened there.
    func testLosingAccessClosesTheCallersTerminals() async throws {
        let answers = Answers()
        let store = try ComputerStore(root: root)
        let provider = try ComputerProvider(store: store, socket: root.appendingPathComponent("computer.sock"), listens: false)
        let gate = ExternalGate(url: nil, prompter: answers)
        gate.enabled = true
        var closed: [(UUID?, String)] = []
        let service = ComputerExternalService(store: store, provider: provider, gate: gate, stagingRoot: root) { request, peer in
            XCTAssertEqual(request.operation, .revoke)
            closed.append((request.computerID, peer))
        }
        let lent = try add(store, "Lent"), made = try add(store, "Made")
        let caller = try await gate.admit(claude)
        gate.setAccess(true, to: lent.id, for: caller.id)
        gate.recordCreated(made.id, by: caller.id)
        gate.setAccess(false, to: lent.id, for: caller.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(closed.map(\.0), [lent.id])
        XCTAssertEqual(closed.first?.1, "external:" + caller.id.uuidString.lowercased())
        gate.remove(caller.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(closed.map(\.0), [lent.id, made.id])
        withExtendedLifetime(service) {}
    }

    func testComputersDeletedInTheAppAreForgotten() async throws {
        let answers = Answers()
        let (service, store) = try service(answers)
        let mine = try add(store, "Mine")
        let caller = try await service.gate.admit(claude)
        service.gate.recordCreated(mine.id, by: caller.id)
        store.sessions.removeAll()
        _ = try await service.perform(.init(.list), launcher: claude)
        XCTAssertTrue(service.gate.grants.callers[0].resources.isEmpty)
    }
}
