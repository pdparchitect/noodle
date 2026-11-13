import NoodleBrand
import NoodleCore
import PionCore
import XCTest

@MainActor final class AgentEditingTests: XCTestCase {
    private var root: URL!
    private var model: PionModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PionEditing-\(UUID())")
        model = PionModel(root: root, messenger: nil, isScripted: true)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func agent(_ name: String = "Avery") throws -> AgentRecord {
        try model.createAgent(name: name, description: "Analyst", instructions: "Check evidence.",
                              provider: .codex, model: "original", effort: "high", symbol: "shield", color: 3)
    }

    func testGeneratedNamesAreTheDefaultAndHumanNamesRemainAvailable() throws {
        XCTAssertEqual(PionModel.defaultAgentNameStyle, .playful)
        let generated = model.suggestedAgentName()
        XCTAssertEqual(generated.split(separator: " ").count, 2)
        _ = try agent(generated)
        let next = model.suggestedAgentName(excluding: generated)
        XCTAssertFalse(next.isEmpty)
        XCTAssertNotEqual(next.lowercased(), generated.lowercased())
        let human = model.suggestedAgentName(style: .real)
        XCTAssertFalse(human.isEmpty)
        XCTAssertFalse(human.contains(" "))
        let created = try agent("   ")
        XCTAssertEqual(created.displayName.split(separator: " ").count, 2)
    }

    func testEditingAnAgentPersistsItsIdentityInstructionsAndConversationName() throws {
        let original = try agent()
        let conversation = try XCTUnwrap(model.directConversation(of: original))
        let directory = model.repository.directory(for: original)
        try model.send("Keep this conversation.", in: conversation.id)
        XCTAssertEqual(try model.agentInstructions(original), "Check evidence.")
        let updated = try model.updateAgent(original, name: "Morgan", description: "Responder", instructions: "Follow leads.",
                                             provider: .claudeCode, model: "replacement")
        model.refresh()
        let saved = try XCTUnwrap(model.agent(original.id))
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(saved.displayName, "Morgan")
        XCTAssertEqual(saved.publicDescription, "Responder")
        XCTAssertEqual(saved.harnessIdentifier, HarnessProvider.claudeCode.rawValue)
        XCTAssertEqual(saved.modelIdentifier, "replacement")
        XCTAssertEqual(saved.reasoningEffort, "high")
        XCTAssertEqual(saved.avatarSymbolName, "shield")
        XCTAssertEqual(saved.avatarColorIndex, 3)
        XCTAssertEqual(model.repository.directory(for: saved), directory)
        XCTAssertEqual(model.directConversation(of: saved)?.id, conversation.id)
        XCTAssertEqual(model.directConversation(of: saved)?.displayName, "Morgan")
        XCTAssertTrue(model.messages(in: conversation.id).contains { $0.body == "Keep this conversation." })
        XCTAssertEqual(try model.agentInstructions(saved), "Follow leads.")
        let backstory = try model.repository.loadAgentBackstory(saved)
        XCTAssertEqual(backstory.components(separatedBy: AgentRole.principles).count, 2)
    }

    func testEditingAGroupKeepsItsHistoryAndSavesItsMembers() throws {
        let first = try agent(), second = try agent("Morgan")
        let group = try model.createGroup(name: "Triage", description: "Before", members: [first.id])
        try model.send("Keep the evidence.", in: group.id)
        _ = try model.updateGroup(group, name: "Response", description: "After", members: [first.id, second.id])
        model.refresh()
        let saved = try XCTUnwrap(model.conversation(group.id))
        XCTAssertEqual(saved.displayName, "Response")
        XCTAssertEqual(saved.publicDescription, "After")
        XCTAssertEqual(Set(saved.participantIDs), [first.id, second.id])
        XCTAssertTrue(model.messages(in: group.id).contains { $0.body == "Keep the evidence." })
    }

    func testAnAgentWithNoCustomInstructionsDoesNotDuplicatePionsRulesOnSave() throws {
        let original = try model.createAgent(name: "Morgan", description: nil, instructions: "", provider: nil, model: nil)
        XCTAssertEqual(try model.agentInstructions(original), "")
        let updated = try model.updateAgent(original, name: "Morgan", description: nil,
                                             instructions: try model.agentInstructions(original), provider: nil, model: nil)
        XCTAssertEqual(try model.repository.loadAgentBackstory(updated), AgentRole.principles)
    }

    func testEditRoutesToTheClickedRowWithoutChangingTheSelection() throws {
        let agent = try agent()
        let direct = try XCTUnwrap(model.directConversation(of: agent))
        let group = try model.createGroup(name: "Triage", description: nil, members: [agent.id])
        let window = WindowState()
        model.selection = group.id
        window.edit(direct, in: model)
        if case .editAgent(let target) = window.sheet { XCTAssertEqual(target.id, agent.id) }
        else { XCTFail("The agent row must open its editor") }
        XCTAssertEqual(model.selection, group.id)
        window.edit(group, in: model)
        if case .editGroup(let target) = window.sheet { XCTAssertEqual(target.id, group.id) }
        else { XCTFail("The group row must open its editor") }
    }

    func testInvalidEditsLeaveSavedValuesIntact() throws {
        let original = try agent()
        XCTAssertThrowsError(try model.updateAgent(original, name: " ", description: "Changed", instructions: "Changed",
                                                   provider: nil, model: nil))
        XCTAssertEqual(try model.repository.loadAgents().first?.displayName, original.displayName)
        XCTAssertEqual(try model.agentInstructions(original), "Check evidence.")
        let group = try model.createGroup(name: "Triage", description: nil, members: [original.id])
        XCTAssertThrowsError(try model.updateGroup(group, name: "Changed", description: nil, members: []))
        XCTAssertEqual(model.conversation(group.id)?.displayName, "Triage")
    }
}
