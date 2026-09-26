import ComputerBridge
import XCTest
@testable import NoodleCore

final class ComputerAccessTests: XCTestCase {
    func testASavedComputerLinkDoesNotDependOnTheLiveCatalogue() throws {
        let root = try temporaryDirectory()
        let computer = RemoteComputer(id: UUID(), name: "Saved Desktop", kind: "Desktop", state: "Running", symbol: "desktopcomputer", icon: Data([1, 2]))
        let agent = UUID()
        let attachment = ConversationAttachment(conversationID: UUID(), originalFilename: "Saved Desktop.webloc",
            storedFilename: "link.webloc", mediaType: "application/x-webloc", byteCount: 1,
            url: ComputerLink.url(computer: computer.id, terminal: nil, view: "web"),
            card: LinkCard(title: computer.name, image: Data([3, 4]), symbol: computer.symbol, icon: computer.icon))
        let saved = try JSONEncoder().encode(attachment)
        var registry = ComputerAssignments()
        registry.computers = [computer]; registry.agents[agent.uuidString] = [computer.id]
        try registry.save(root: root)
        registry.computers = []; registry.agents = [:]
        try registry.save(root: root)
        let restored = try JSONDecoder().decode(ConversationAttachment.self, from: saved)
        XCTAssertEqual(restored, attachment)
        XCTAssertEqual(restored.companion, .computer(computer.id, terminal: nil, view: "web"))
        XCTAssertFalse(try ComputerAssignments.load(root: root).permits(computer.id, agent: agent))
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testManyToManyAssignmentsAndRevocationPersist() throws {
        let root = try temporaryDirectory(), a = UUID(), b = UUID(), computer = UUID(), other = UUID()
        var registry = ComputerAssignments()
        registry.agents[a.uuidString] = [computer, other]; registry.agents[b.uuidString] = [computer]
        try registry.save(root: root)
        registry = try ComputerAssignments.load(root: root)
        XCTAssertTrue(registry.permits(computer, agent: a)); XCTAssertTrue(registry.permits(computer, agent: b))
        XCTAssertFalse(registry.permits(other, agent: b)); XCTAssertFalse(registry.permits(computer, agent: UUID()))
        registry.agents[a.uuidString] = []; try registry.save(root: root)
        registry = try ComputerAssignments.load(root: root)
        XCTAssertFalse(registry.permits(computer, agent: a)); XCTAssertTrue(registry.permits(computer, agent: b))
        registry.version = 99; try registry.save(root: root)
        XCTAssertThrowsError(try ComputerAssignments.load(root: root))
    }
    func testAFileHasNoCardAndAComputerLinkReachesBotsWithItsCard() throws {
        let attachment = ConversationAttachment(conversationID: UUID(), originalFilename: "a.txt", storedFilename: "a.txt", mediaType: "text/plain", byteCount: 1)
        XCTAssertNil(try JSONDecoder().decode(ConversationAttachment.self, from: JSONEncoder().encode(attachment)).card)
        let card = LinkCard(title: "Shared", detail: "$", symbol: "terminal")
        let link = ConversationAttachment(conversationID: UUID(), originalFilename: "Shared.webloc", storedFilename: "link.webloc",
            mediaType: "application/x-webloc", byteCount: 1, url: ComputerLink.url(computer: UUID(), terminal: UUID(), view: "terminal"), card: card)
        let wire = MessengerAttachment(attachment: link, absolutePath: "/fixture/link.webloc")
        let decoded = try JSONDecoder().decode(MessengerAttachment.self, from: JSONEncoder().encode(wire))
        XCTAssertEqual(decoded.card, card)
        XCTAssertEqual(decoded.url, link.url)
    }
    func testAssignmentsPublishedToTheBrokerFailClosed() throws {
        let agent = UUID(), computer = UUID()
        var registry = ComputerAssignments()
        registry.agents[agent.uuidString] = [computer]
        XCTAssertEqual(registry.toolAssignments(readable: true), [agent: [computer.uuidString]])
        XCTAssertEqual(registry.toolAssignments(readable: false), [:])
    }
}
