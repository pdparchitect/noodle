import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntimeSettings
@testable import NoodleRuntime

@MainActor final class StoreAgentTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func create(_ f: StoreFixture, name: String = "New bot", harness: String = HarnessProvider.codex.rawValue,
                        mcp: Set<UUID> = [], computers: Set<UUID> = []) -> Bool {
        f.store.createAgent(named: name, harnessIdentifier: harness, modelIdentifier: "fixture-model", reasoningEffort: "high",
            avatarSymbolName: "sparkles", avatarColorIndex: 2, avatarImageData: nil,
            publicDescription: "  Research assistant  ", backstory: "  Remember the project.  ", mcpConnectionIDs: mcp, computerIDs: computers)
    }
    private func update(_ f: StoreFixture, name: String = "Renamed bot", harness: HarnessProvider = .codex,
                        backstory: String = "Updated backstory", mcp: Set<UUID>? = nil, computers: Set<UUID>? = nil) -> Bool {
        f.store.updateAgent(f.a, name: name, harnessIdentifier: harness.rawValue, modelIdentifier: "new-model", reasoningEffort: "high",
            avatarSymbolName: "sparkles", avatarColorIndex: 3, avatarImageData: nil,
            publicDescription: "Updated public description", backstory: backstory, mcpConnectionIDs: mcp, computerIDs: computers)
    }
    private func makeReadOnly(_ directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    }

    func testCreationPersistsConfigurationAndSelectsOnlyTheNewConversation() throws {
        let f = try fixture(); f.store.creationSheet = .bot
        f.store.setDraft("Existing draft", for: f.directA.id)
        XCTAssertTrue(create(f), f.store.errorMessage ?? "")
        let agent = try XCTUnwrap(f.store.agents.last), conversation = try XCTUnwrap(f.store.selectedConversation)
        XCTAssertEqual(agent.displayName, "New bot")
        XCTAssertEqual(agent.publicDescription, "Research assistant")
        XCTAssertEqual(agent.modelIdentifier, "fixture-model")
        XCTAssertEqual(conversation.participantIDs, [agent.id])
        XCTAssertEqual(try f.repository.loadAgentBackstory(agent), "Remember the project.")
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == agent.id }?.modelIdentifier, "fixture-model")
        XCTAssertEqual(f.runtime.factory.processes.first { $0.configuration.id == agent.id }?.configuration.id, agent.id)
        XCTAssertNil(f.store.creationSheet)
        XCTAssertEqual(f.store.draft(for: f.directA.id), "Existing draft")
    }

    func testHarnessProfileSavesWithSettingsAndDeletingItReturnsBotsToSystem() throws {
        let f = try fixture()
        let profile = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        func save(_ selection: UUID??, harness: HarnessProvider = .codex) -> Bool {
            f.store.updateAgent(f.a, name: "Profile bot", harnessIdentifier: harness.rawValue, modelIdentifier: nil,
                reasoningEffort: nil, avatarSymbolName: "sparkles", avatarColorIndex: 3, avatarImageData: nil,
                publicDescription: "", backstory: "Backstory", harnessProfile: selection)
        }
        XCTAssertTrue(save(.some(profile.id)), f.store.errorMessage ?? "")
        XCTAssertEqual(try f.repository.loadAgentHarnessProfile(f.a), profile.id)
        // A save that does not mention the profile keeps it.
        XCTAssertTrue(save(nil), f.store.errorMessage ?? "")
        XCTAssertEqual(f.store.harnessProfile(for: try XCTUnwrap(f.store.agents.first { $0.id == f.a.id })), profile.id)
        // A profile never follows the bot to another harness.
        XCTAssertTrue(save(nil, harness: .claudeCode), f.store.errorMessage ?? "")
        XCTAssertNil(try f.repository.loadAgentHarnessProfile(f.a))

        XCTAssertTrue(save(.some(profile.id)), f.store.errorMessage ?? "")
        f.store.deleteHarnessProfile(profile)
        XCTAssertNil(f.store.errorMessage)
        XCTAssertNil(try f.repository.loadAgentHarnessProfile(f.a))
        XCTAssertEqual(f.store.harnessProfiles.profiles, [])
    }

    func testSharedFoldersSaveWithSettingsAndInvalidOnesRollBackTheWholeSave() throws {
        let f = try fixture()
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-shared-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: shared) }
        let folder = AgentFolder(path: shared.standardizedFileURL.path, writable: false, description: "Reference material")
        func save(_ folders: [AgentFolder]?, name: String) -> Bool {
            f.store.updateAgent(f.a, name: name, harnessIdentifier: HarnessProvider.codex.rawValue, modelIdentifier: nil,
                reasoningEffort: nil, avatarSymbolName: "sparkles", avatarColorIndex: 3, avatarImageData: nil,
                publicDescription: "", backstory: "Backstory", folders: folders)
        }
        XCTAssertTrue(save([folder], name: "Shared"), f.store.errorMessage ?? "")
        XCTAssertEqual(f.store.folders(for: f.a), [folder])
        let instructions = f.repository.directory(for: f.a).appendingPathComponent("AGENTS.md")
        XCTAssertTrue(try String(contentsOf: instructions, encoding: .utf8).contains("` (read only): Reference material"))

        XCTAssertFalse(save([AgentFolder(path: f.repository.rootURL.path)], name: "Greedy"))
        XCTAssertEqual(f.store.folders(for: f.a), [folder])
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, "Shared")
        // Saves from callers that do not edit folders leave them alone.
        XCTAssertTrue(save(nil, name: "Renamed"), f.store.errorMessage ?? "")
        XCTAssertEqual(f.store.folders(for: f.a), [folder])
    }

    func testCreationValidationDoesNotCreateOrAuthorizeAnything() throws {
        let f = try fixture(), before = try f.repository.loadAgents()
        for (name, harness, mcp, computers) in [
            ("", HarnessProvider.codex.rawValue, Set<UUID>(), Set<UUID>()),
            ("Valid", "unavailable-harness", [], []),
            ("Valid", HarnessProvider.codex.rawValue, [UUID()], []),
            ("Valid", HarnessProvider.codex.rawValue, [], [UUID()])
        ] {
            XCTAssertFalse(create(f, name: name, harness: harness, mcp: mcp, computers: computers))
            XCTAssertEqual(try f.repository.loadAgents(), before)
            XCTAssertEqual(f.store.agents, before)
            XCTAssertTrue(f.runtime.factory.processes.isEmpty)
        }
    }

    func testFailedConversationCreationLeavesNoOrphanAgentAndCanRetry() throws {
        let f = try fixture(), before = try f.repository.loadAgents()
        let folder = f.repository.conversationsURL
        try makeReadOnly(folder)
        f.store.creationSheet = .bot
        XCTAssertFalse(create(f))
        XCTAssertEqual(try f.repository.loadAgents(), before)
        XCTAssertEqual(f.store.agents, before)
        XCTAssertNotNil(f.store.creationSheet)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertTrue(create(f), f.store.errorMessage ?? "")
        XCTAssertEqual(try f.repository.loadAgents().count, before.count + 1)
    }

    func testFailedWorkspaceRefreshRollsBackConfigurationBackstoryConversationAndAccess() throws {
        let f = try fixture(), before = try Data(contentsOf: f.repository.storage(for: f.a.id).configuration)
        let previousBackstory = try f.repository.loadAgentBackstory(f.a)
        f.store.agentBeingEdited = f.a
        try makeReadOnly(f.repository.directory(for: f.a))
        XCTAssertFalse(update(f, harness: .claudeCode))
        XCTAssertEqual(try Data(contentsOf: f.repository.storage(for: f.a.id).configuration), before)
        XCTAssertEqual(f.store.agents.first { $0.id == f.a.id }?.displayName, f.a.displayName)
        XCTAssertEqual(f.store.conversations.first { $0.id == f.directA.id }, f.directA)
        XCTAssertEqual(try f.repository.loadConversations().first { $0.id == f.directA.id }, f.directA)
        XCTAssertEqual(try f.repository.loadAgentBackstory(f.a), previousBackstory)
        XCTAssertFalse(AgentAccessConfiguration.load(from: f.runtime.defaults).requiredHarnessGrants[f.a.id.uuidString]?.contains(HarnessProvider.claudeCode.rawValue) == true)
        XCTAssertEqual(f.store.agentBeingEdited?.id, f.a.id)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
    }

    func testSettingsSaveRepairsRedirectedGeneratedGuideWithoutReadingIt() throws {
        let f = try fixture()
        let target = f.repository.directory(for: f.b).appendingPathComponent("AGENTS.md")
        let original = try Data(contentsOf: target)
        let guide = f.repository.directory(for: f.a).appendingPathComponent("AGENTS.md")
        try FileManager.default.removeItem(at: guide)
        try FileManager.default.createSymbolicLink(at: guide, withDestinationURL: target)
        XCTAssertTrue(update(f, backstory: "Saved privately"), f.store.errorMessage ?? "")
        XCTAssertEqual(try f.repository.loadAgentBackstory(f.a), "Saved privately")
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(try String(contentsOf: guide, encoding: .utf8).contains("Saved privately"))
    }

    func testFailedDirectConversationWriteRestoresAgentAndLeavesDrafts() throws {
        let f = try fixture(), before = try Data(contentsOf: f.repository.storage(for: f.a.id).configuration)
        f.store.setDraft("Keep composing", for: f.directA.id)
        try makeReadOnly(f.repository.conversationDirectory(id: f.directA.id))
        XCTAssertFalse(update(f))
        XCTAssertEqual(try Data(contentsOf: f.repository.storage(for: f.a.id).configuration), before)
        XCTAssertEqual(f.store.conversations.first { $0.id == f.directA.id }, f.directA)
        XCTAssertEqual(f.store.draft(for: f.directA.id), "Keep composing")
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
    }

    func testInvalidAssignmentsLeaveExistingAgentAndEditorUnchanged() throws {
        let f = try fixture(); f.store.agentBeingEdited = f.a
        XCTAssertFalse(update(f, mcp: [UUID()]))
        XCTAssertFalse(update(f, computers: [UUID()]))
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, f.a.displayName)
        XCTAssertEqual(f.store.agentBeingEdited?.id, f.a.id)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
    }

    func testBackstoryChangesResetSessionsButWhitespaceOnlyChangesPreserveThem() throws {
        for changes in [false, true] {
            let f = try fixture()
            try f.repository.updateAgentBackstory(f.a, backstory: "Original backstory")
            let state = f.repository.storage(for: f.a.id).sessionState(provider: .codex, extendedAccess: false)
            let bytes = Data("saved session".utf8); try bytes.write(to: state)
            let old = try f.runtime.start(f.a)
            XCTAssertTrue(update(f, backstory: changes ? "Changed backstory" : "  Original backstory\n"), f.store.errorMessage ?? "")
            XCTAssertEqual(old.stops, 1)
            XCTAssertEqual(FileManager.default.fileExists(atPath: state.path), !changes)
            if !changes { XCTAssertEqual(try Data(contentsOf: state), bytes) }
            XCTAssertNil(f.store.agentBeingEdited)
            XCTAssertEqual(f.runtime.factory.processes.last?.configuration.modelIdentifier, "new-model")
        }
    }

    func testFailedDeletionPreservesConversationWorkspaceDraftAndAccess() throws {
        let f = try fixture(), group = try f.group()
        f.store.setDraft("Unsent text", for: f.directA.id)
        f.runtime.runtime.setExtendedAccess(true, agent: f.a, repository: f.repository)
        try makeReadOnly(f.repository.agentsURL)
        XCTAssertFalse(f.store.delete(f.directA))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repository.storage(for: f.a.id).configuration.path))
        XCTAssertTrue(try f.repository.loadConversations().contains { $0.id == f.directA.id })
        XCTAssertEqual(try f.repository.loadConversations().first { $0.id == group.id }?.participantIDs, group.participantIDs)
        XCTAssertEqual(f.store.draft(for: f.directA.id), "Unsent text")
        XCTAssertTrue(AgentAccessConfiguration.load(from: f.runtime.defaults).isExtended(for: f.a))
    }
    func testLateWorkspaceFailureRestoresAssignmentsAndKeepsRuntimeRunning() throws {
        let f = try fixture()
        let account = try MCPConnectionRecord(name: "Fixture account", endpoint: URL(string: "https://example.com/mcp")!)
        try f.store.mcp.save(account)
        try f.store.mcp.assign([account.id], to: f.a)
        let old = try f.runtime.start(f.a)
        let registryURL = f.repository.rootURL.appendingPathComponent("MCP/connections.json")
        let before = try Data(contentsOf: registryURL)
        let config = try Data(contentsOf: f.repository.storage(for: f.a.id).configuration)
        let instructions = f.repository.directory(for: f.a).appendingPathComponent(".agents/skills/messenger/SKILL.md")
        try FileManager.default.removeItem(at: instructions)
        try FileManager.default.createDirectory(at: instructions, withIntermediateDirectories: false)
        XCTAssertFalse(update(f, mcp: [], computers: []))
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
        XCTAssertEqual(try Data(contentsOf: f.repository.storage(for: f.a.id).configuration), config)
        XCTAssertEqual(f.store.mcp.selectedIDs(for: f.a), [account.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repository.rootURL.appendingPathComponent("computers.json").path))
        XCTAssertEqual(old.stops, 0)
        XCTAssertTrue(old.isAlive)
        XCTAssertTrue(f.store.errorMessage?.contains("repair") == true)
    }

    func testFailedAssignmentDuringCreationRemovesNewBotAndAllowsRetry() throws {
        let f = try fixture()
        let account = try MCPConnectionRecord(name: "Fixture account", endpoint: URL(string: "https://example.com/mcp")!)
        try f.store.mcp.save(account)
        let before = try f.repository.loadAgents().map(\.id)
        let conversations = try f.repository.loadConversations().map(\.id).sorted { $0.uuidString < $1.uuidString }
        let directory = f.repository.rootURL.appendingPathComponent("MCP")
        try makeReadOnly(directory)
        XCTAssertFalse(create(f, mcp: [account.id]))
        XCTAssertEqual(try f.repository.loadAgents().map(\.id), before)
        XCTAssertEqual(try f.repository.loadConversations().map(\.id).sorted { $0.uuidString < $1.uuidString }, conversations)
        XCTAssertTrue(f.store.mcp.registry.assignments.isEmpty)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertTrue(create(f, mcp: [account.id]), f.store.errorMessage ?? "")
        XCTAssertEqual(try f.repository.loadAgents().count, before.count + 1)
    }

    func testFailedGroupUpdateDuringDeletionRestoresAllMovedDirectories() throws {
        let f = try fixture(), group = try f.group()
        _ = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "Retain this history")
        let transcript = f.repository.conversationDirectory(id: f.directA.id).appendingPathComponent("messages.json")
        let before = try Data(contentsOf: transcript)
        try makeReadOnly(f.repository.conversationDirectory(id: group.id))
        XCTAssertFalse(f.store.delete(f.directA))
        XCTAssertEqual(try Data(contentsOf: transcript), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repository.storage(for: f.a.id).configuration.path))
        XCTAssertEqual(try f.repository.loadConversations().first { $0.id == group.id }?.participantIDs, group.participantIDs)
        for directory in [f.repository.agentsURL, f.repository.conversationsURL] {
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".deleting-") })
        }
    }

    func testFailedRuntimeRestartKeepsSavedSettingsAndReportsRuntimeFailure() throws {
        let f = try fixture(), old = try f.runtime.start(f.a)
        old.automaticallyStops = false
        XCTAssertTrue(update(f), f.store.errorMessage ?? "")
        old.finishStop(false)
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, "Renamed bot")
        XCTAssertEqual(f.store.agents.first { $0.id == f.a.id }?.displayName, "Renamed bot")
        XCTAssertEqual(f.runtime.runtime.snapshot(for: f.a.id).phase, .failed)
        XCTAssertEqual(f.runtime.factory.processes.count, 1)
    }

    func testAddingComputerAfterMessageCanRecoverFromFailedStopWithoutLosingWork() throws {
        let f = try fixture(), computerID = UUID()
        var computers = ComputerAssignments()
        computers.computers = [.init(id: computerID, name: "Fixture computer", kind: "linux",
                                    state: "running", symbol: "desktopcomputer")]
        try computers.save(root: f.repository.rootURL)
        try f.store.computers.reloadAssignments()
        _ = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "Inspect the files on my computer")
        let transcript = f.repository.conversationDirectory(id: f.directA.id).appendingPathComponent("messages.json")
        let messages = try Data(contentsOf: transcript)
        let old = try f.runtime.start(f.a)
        old.transition(.working)
        old.hasInterruptedWork = true
        old.automaticallyStops = false
        let state = f.repository.storage(for: f.a.id).sessionState(provider: .codex, extendedAccess: false)
        try Data("saved session".utf8).write(to: state)
        var work = AgentTurnRecovery(sessionStateURL: state)
        try work.begin()
        let backstory = try f.repository.loadAgentBackstory(f.a)
        XCTAssertTrue(update(f, backstory: backstory, computers: [computerID]), f.store.errorMessage ?? "")
        old.finishStop(false)
        let saved = try XCTUnwrap(f.store.agents.first { $0.id == f.a.id })
        XCTAssertEqual(f.store.computers.selectedIDs(for: saved), [computerID])
        XCTAssertNil(f.runtime.runtime.kick(agent: saved, repository: f.repository))
        XCTAssertEqual(old.stops, 2)
        XCTAssertEqual(f.runtime.factory.processes.count, 1)
        old.finishStop(true)
        XCTAssertEqual(f.runtime.factory.processes.count, 2)
        XCTAssertTrue(f.runtime.factory.processes.last!.launch.recoverInterruptedWork)
        XCTAssertEqual(f.runtime.runtime.snapshot(for: saved.id).phase, .ready)
        XCTAssertEqual(try Data(contentsOf: transcript), messages)
        XCTAssertEqual(try Data(contentsOf: state), Data("saved session".utf8))
        XCTAssertTrue(work.hasUnfinishedTurn)
        XCTAssertEqual(try ComputerAssignments.load(root: f.repository.rootURL).assigned(to: saved.id), [computerID])
    }

}
