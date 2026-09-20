import ComputerBridge
import XCTest
@testable import NoodleCore

final class ComputerAccessTests: XCTestCase {
    func testSavedWebPresentationDoesNotDependOnLiveCatalogue() throws {
        let root = try temporaryDirectory()
        let computer = RemoteComputer(id: UUID(), name: "Saved Desktop", kind: "Desktop", state: "Running", symbol: "desktopcomputer", icon: Data([1, 2]))
        let card = ComputerCard(computer: computer, agentID: UUID(), terminalPreview: "", view: "web", previewImage: Data([3, 4]))
        let attachment = ConversationAttachment(conversationID: UUID(), originalFilename: "Desktop.noodlecomputer",
            storedFilename: "card.noodlecomputer", mediaType: ComputerCard.mediaType, byteCount: 1, computer: card)
        let saved = try JSONEncoder().encode(attachment)
        var registry = ComputerAssignments()
        registry.computers = [computer]; registry.agents[card.agentID.uuidString] = [computer.id]
        try registry.save(root: root)
        registry.computers = []; registry.agents = [:]
        try registry.save(root: root)
        let restored = try JSONDecoder().decode(ConversationAttachment.self, from: saved)
        XCTAssertEqual(restored.computer, card)
        XCTAssertNil(restored.computer?.terminalID)
        XCTAssertFalse(try ComputerAssignments.load(root: root).permits(computer.id, agent: card.agentID))
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
    func testLegacyAttachmentRemainsReadableAndComputerRoundTrips() throws {
        let attachment = ConversationAttachment(conversationID: UUID(), originalFilename: "a.txt", storedFilename: "a.txt", mediaType: "text/plain", byteCount: 1)
        let old = try JSONEncoder().encode(attachment)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("computer"))
        XCTAssertNil(try JSONDecoder().decode(ConversationAttachment.self, from: old).computer)
        let card = ComputerCard(computer: .init(id: UUID(), name: "Shared", kind: "Shell", state: "Running", symbol: "terminal"),
            agentID: UUID(), terminalID: UUID(), terminalPreview: "$")
        let computerAttachment = ConversationAttachment(conversationID: UUID(), originalFilename: "Shell.noodlecomputer",
            storedFilename: "card.noodlecomputer", mediaType: ComputerCard.mediaType, byteCount: 1, computer: card)
        let wire = MessengerAttachment(attachment: computerAttachment, absolutePath: "/fixture/card.noodlecomputer")
        XCTAssertEqual(try JSONDecoder().decode(MessengerAttachment.self, from: JSONEncoder().encode(wire)).computer, card)
    }
    /// Earlier versions wrote a hand-written skill, its command link and a request mailbox.
    func testLegacySkillAndMailboxAreRemovedButGeneratedAndUserSkillsStay() throws {
        let root = try temporaryDirectory(), skill = root.appendingPathComponent(".agents/skills/computer")
        try WorkspaceMailbox.synchronizeSkill(workspace: root, name: "computer", enabled: true, instructions: "old",
                                              command: "computer", executable: URL(fileURLWithPath: "/fixture/computer"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".noodle/computer-bridge"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent(".noodle/computer-bridge/session.json"))
        ComputerAgentSkill.removeLegacy(workspace: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".noodle/computer-bridge").path))

        ToolProviderSkills.synchronize(workspace: root, providers: [(ToolProviderManifest(id: "computer", title: "Noodle Computer", summary: "Run commands."), [])])
        let generated = try String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8)
        ComputerAgentSkill.removeLegacy(workspace: root)
        XCTAssertEqual(try String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8), generated)

        try FileManager.default.removeItem(at: skill)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        let custom = skill.appendingPathComponent("SKILL.md")
        try Data("user skill".utf8).write(to: custom)
        ComputerAgentSkill.removeLegacy(workspace: root)
        XCTAssertEqual(try Data(contentsOf: custom), Data("user skill".utf8))
    }

    func testAssignmentsPublishedToTheBrokerFailClosed() throws {
        let agent = UUID(), computer = UUID()
        var registry = ComputerAssignments()
        registry.agents[agent.uuidString] = [computer]
        XCTAssertEqual(registry.toolAssignments(readable: true), [agent: [computer.uuidString]])
        XCTAssertEqual(registry.toolAssignments(readable: false), [:])
    }
}
