import XCTest
@testable import NoodleCore

final class ToolCatalogueListingTests: XCTestCase {
    private let me = UUID(), friend = UUID(), stranger = UUID()
    private var bots: [UUID: String] { [me: "Marco", friend: "Fern", stranger: "Stranger Bot"] }

    private func entry(_ name: String) -> ToolDefinition {
        .init(id: UUID().uuidString.lowercased(), name: name, summary: "\(name) things.", defaultInstructions: "Use \(name).",
              iconName: "", configuration: .connection(.init(endpoint: URL(string: "https://\(name.lowercased()).example.com/mcp")!)))
    }

    private func registry(_ grants: [(ToolConnection, [UUID])]) -> ToolConnectionRegistry {
        var registry = ToolConnectionRegistry()
        registry.connections = grants.map(\.0)
        for (connection, holders) in grants {
            for bot in holders { registry.assignments[bot.uuidString.lowercased(), default: []].append(connection.id) }
        }
        return registry
    }

    private func rows(_ entries: [ToolDefinition], _ registry: ToolConnectionRegistry, known: Set<UUID> = []) -> [ToolCatalogueListing] {
        ToolCatalogueListing.rows(entries: entries, registry: registry, requester: me, bots: bots, known: known)
    }

    /// Each entry is listed once, by name, however many accounts were made from it: available with none, configured
    /// when no bot has one, assigned when only others have one, assigned to you when the asking bot has one.
    func testEachEntryIsListedOnceWithItsStatus() throws {
        let open = entry("Open"), unused = entry("Unused"), others = entry("Others"), mine = entry("Mine")
        let listed = rows([unused, open, mine, others], registry([
            (try unused.makeConnection(name: "One"), []), (try unused.makeConnection(name: "Two"), []),
            (try others.makeConnection(name: "Theirs"), [stranger]),
            (try mine.makeConnection(name: "Work"), [me]), (try mine.makeConnection(name: "Home"), [stranger]),
        ]))
        XCTAssertEqual(listed, [
            .init(name: "Mine", summary: "Mine things.", status: .assignedToYou, alsoAssignedElsewhere: true),
            .init(name: "Open", summary: "Open things.", status: .available),
            .init(name: "Others", summary: "Others things.", status: .assigned, alsoAssignedElsewhere: true),
            .init(name: "Unused", summary: "Unused things.", status: .configured),
        ])
    }

    /// Bots the asking bot shares a conversation with are named so it can ask them; any other is only a flag, never a
    /// name or an ID, however many there are.
    func testOnlyBotsInConversationWithTheAskerAreNamed() throws {
        let shared = entry("Shared"), close = entry("Close"), both = entry("Both")
        let listed = rows([shared, close, both], registry([
            (try shared.makeConnection(name: "A"), [friend, stranger]),
            (try close.makeConnection(name: "B"), [friend]),
            (try both.makeConnection(name: "C"), [me, friend]),
        ]), known: [me, friend])
        let fern = ToolCatalogueListing.Assignee(name: "Fern", agentID: friend)
        XCTAssertEqual(listed, [
            .init(name: "Both", summary: "Both things.", status: .assignedToYou, assignedTo: [fern]),
            .init(name: "Close", summary: "Close things.", status: .assigned, assignedTo: [fern]),
            .init(name: "Shared", summary: "Shared things.", status: .assigned, assignedTo: [fern], alsoAssignedElsewhere: true),
        ])
        let output = MessengerCommandResult.json(listed).standardOutput
        XCTAssertFalse(output.contains("Stranger"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains(stranger.uuidString))
    }

    /// An account added by address, one made from a preset this app does not offer, and a grant to a bot that is gone
    /// count for nothing.
    func testOnlyThisAppsEntriesAndCurrentBotsCount() throws {
        let here = entry("Here"), elsewhere = entry("Elsewhere")
        let listed = rows([here], registry([
            (try here.makeConnection(name: "Here"), [UUID()]),
            (try elsewhere.makeConnection(name: "Elsewhere"), [me]),
            (try ToolConnection(name: "Custom", endpoint: URL(string: "https://custom.example.com/mcp")!), [me]),
        ]))
        XCTAssertEqual(listed, [.init(name: "Here", summary: "Here things.", status: .configured)])
    }

    /// A connection the person added by address alone, with no remembered entry, leaves a preset at that very address
    /// available, assigned or not.
    func testAConnectionAddedByAddressAtAPresetsEndpointCountsForNothing() throws {
        let preset = try XCTUnwrap(ToolCatalog.entries.first { !$0.needsSetUp })
        guard case .connection(let configuration) = preset.configuration else { return XCTFail() }
        let manual = try ToolConnection(name: "Manual", endpoint: configuration.endpoint)
        XCTAssertNil(manual.catalogueID)
        // Elsewhere, such as for organisation policy, it still follows the preset at its address.
        XCTAssertEqual(ToolCatalog.definition(for: manual)?.id, preset.id)
        XCTAssertEqual(rows([preset], registry([(manual, [me, friend])]), known: [friend]),
                       [.init(name: preset.name, summary: preset.summary, status: .available)])
    }

    /// An app that offers no tools, as Rook, answers with an empty list.
    func testAnEmptyCatalogueListsNothing() throws {
        let zeta = entry("Zeta")
        XCTAssertEqual(rows([], registry([(try zeta.makeConnection(name: "Zeta"), [me])])), [])
        let output = MessengerCommandResult.json(rows([], ToolConnectionRegistry())).standardOutput
        XCTAssertEqual(output.filter { !$0.isWhitespace }, "[]")
    }

    /// A row never carries the account, its address, its settings or how many there are.
    func testARowCarriesNothingElse() throws {
        let zeta = entry("Zeta")
        var connection = try zeta.makeConnection(name: "Ada's secret Zeta")
        connection.settings = ["domain": "acme"]
        var second = try zeta.makeConnection(name: "Second")
        second.settings = ["domain": "acme"]
        let output = MessengerCommandResult.json(rows([zeta], registry([(connection, [friend, stranger]), (second, [])]),
                                                      known: [friend])).standardOutput
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(Set(decoded[0].keys), ["name", "summary", "status", "assignedTo", "alsoAssignedElsewhere"])
        XCTAssertEqual(Set(try XCTUnwrap((decoded[0]["assignedTo"] as? [[String: Any]])?.first).keys), ["name", "agentID"])
        for leak in ["Ada", "Second", "zeta.example.com", "acme", connection.id.uuidString, second.id.uuidString, zeta.id] {
            XCTAssertFalse(output.localizedCaseInsensitiveContains(leak), leak)
        }
        XCTAssertEqual(Set(try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MessengerCommandResult.json(
            rows([zeta], ToolConnectionRegistry())).standardOutput.utf8)) as? [[String: Any]])[0].keys), ["name", "summary", "status"])
    }

    /// Any bot asks through Messenger; the app answers from its own catalogue, the connections saved for it, and the
    /// conversations the asking bot is in.
    func testMessengerListsTheRunningAppsCatalogueForTheAskingBot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let asker = try repository.createAgent(named: "Scout").agent, colleague = try repository.createAgent(named: "Colleague").agent
        let outsider = try repository.createAgent(named: "Outsider").agent
        _ = try repository.createGroup(named: "Team", participantIDs: [asker.id, colleague.id],
                                       existingAgents: [asker, colleague, outsider])
        let presets = ToolCatalog.entries.filter { !$0.needsSetUp }.prefix(3)
        XCTAssertEqual(presets.count, 3)
        let theirs = presets[presets.startIndex], mine = presets[presets.startIndex + 1], idle = presets[presets.startIndex + 2]
        let connections = [try theirs.makeConnection(name: "Team account"), try mine.makeConnection(name: "Mine"),
                           try idle.makeConnection(name: "Idle")]
        var registry = ToolConnectionRegistry()
        registry.connections = connections
        try registry.assign([connections[0].id], to: colleague.id)
        try registry.assign([connections[0].id], to: outsider.id)
        try registry.assign([connections[1].id], to: asker.id)
        try registry.save(root: root)

        let broker = MessengerBroker(repository: repository)
        try broker.start(agents: [asker])
        defer { broker.stop() }
        let result = MessengerCLI.run(arguments: ["messenger", "--agent-directory", repository.directory(for: asker).path,
                                                  "--list-tool-catalogue"])
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let listed = try JSONDecoder().decode([ToolCatalogueListing].self, from: Data(result.standardOutput.utf8))
        XCTAssertEqual(listed.count, ToolCatalog.entries.count)
        let byName = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0) })
        XCTAssertEqual(byName[theirs.name], .init(name: theirs.name, summary: theirs.summary, status: .assigned,
            assignedTo: [.init(name: "Colleague", agentID: colleague.id)], alsoAssignedElsewhere: true))
        XCTAssertEqual(byName[mine.name]?.status, .assignedToYou)
        XCTAssertEqual(byName[idle.name]?.status, .configured)
        XCTAssertEqual(Set(listed.map(\.status)), [.available, .configured, .assigned, .assignedToYou])
        for leak in ["Team account", "Outsider", outsider.id.uuidString] { XCTAssertFalse(result.standardOutput.contains(leak), leak) }
    }
}
