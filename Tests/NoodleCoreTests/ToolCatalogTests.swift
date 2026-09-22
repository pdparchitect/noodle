import XCTest
@testable import NoodleCore

final class ToolCatalogTests: XCTestCase {
    func testPresetIdentitiesAndSafeEndpoints() throws {
        XCTAssertEqual(Set(ToolCatalog.entries.map(\.id)).count, ToolCatalog.entries.count)
        for tool in ToolCatalog.entries {
            XCTAssertFalse(tool.name.isEmpty)
            XCTAssertFalse(tool.summary.isEmpty)
            XCTAssertFalse(tool.defaultInstructions.isEmpty)
            XCTAssertLessThanOrEqual(tool.defaultInstructions.count, 20_000)
            XCTAssertEqual(tool.iconName, tool.id)
            XCTAssertFalse(tool.iconName.contains("/"))
            switch tool.configuration {
            case .mcp(let configuration):
                let endpoint = configuration.endpoint
                XCTAssertEqual(try MCPConnectionRecord.validatedEndpoint(endpoint), endpoint)
                XCTAssertNil(endpoint.query)
                XCTAssertFalse(endpoint.path.hasSuffix("/sse"))
                XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: endpoint), tool)
                let first = try configuration.makeConnection(name: tool.name, description: tool.summary)
                let second = try configuration.makeConnection(name: tool.name, description: tool.summary)
                XCTAssertNotEqual(first.id, second.id)
                // The registry allocates stable numbered names when accounts are saved.
                XCTAssertEqual(first.skillName, second.skillName)
                XCTAssertEqual(first.endpoint, endpoint)
                XCTAssertNil(first.iconData)
            }
        }
    }

    func testSearchAndCustomMCPStaySeparate() {
        XCTAssertEqual(ToolCatalog.matching("   "), ToolCatalog.entries)
        XCTAssertEqual(ToolCatalog.matching("nOtIoN MCP").map(\.id), ["notion"])
        XCTAssertTrue(ToolCatalog.matching("nothing-matches-this").isEmpty)
        XCTAssertNil(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://example.com/mcp")!))
        let excluded = ["github", "betterstack", "zapier", "workato", "hubspot", "asana"]
        XCTAssertTrue(Set(excluded).isDisjoint(with: ToolCatalog.entries.map(\.id)))
        let notion = ToolCatalog.matching("Notion")[0]
        XCTAssertEqual(ToolCatalog.availableName(for: notion, existingNames: []), "Notion")
        XCTAssertEqual(ToolCatalog.availableName(for: notion, existingNames: ["notion", "Notion 2"]), "Notion 3")
    }

    func testPipedreamUsesThePublicEndUserGateway() throws {
        let tool = try XCTUnwrap(ToolCatalog.matching("Pipedream").first)
        XCTAssertEqual(tool.configuration, .mcp(.init(endpoint: URL(string: "https://mcp.pipedream.net/v2")!)))
        XCTAssertEqual(tool.iconName, "pipedream")
        XCTAssertTrue(tool.defaultInstructions.contains("account is unclear"))
        XCTAssertTrue(tool.defaultInstructions.contains("never request or handle their credentials"))
    }

    func testCreatingPresetDoesNotAssignOrAuthenticateIt() throws {
        let tool = try XCTUnwrap(ToolCatalog.matching("Notion").first)
        switch tool.configuration {
        case .mcp(let configuration):
            let connection = try configuration.makeConnection(name: "Notion Work")
            var registry = MCPRegistry()
            registry.connections.append(connection)
            XCTAssertTrue(registry.assignments.isEmpty)
            let roundTrip = try JSONDecoder().decode(MCPRegistry.self, from: JSONEncoder().encode(registry))
            XCTAssertEqual(roundTrip, registry)
            XCTAssertEqual(connection.name, "Notion Work")
        }
    }

    func testExperimentalPresetsSortLastAndAreSearchable() throws {
        let gmail = try XCTUnwrap(ToolCatalog.matching("experimental").first)
        XCTAssertEqual(gmail.id, "gmail")
        XCTAssertEqual(gmail.maturity, .experimental)
        XCTAssertEqual(gmail.maturity.badge, "Experimental")
        let experimental = ToolCatalog.matching("experimental")
        XCTAssertEqual(experimental.map(\.id), ["gmail", "google-calendar", "google-docs", "google-drive"])
        XCTAssertEqual(Array(ToolCatalog.matching("").suffix(experimental.count)), experimental)
        XCTAssertEqual(ToolCatalog.matching("Gmail MCP experimental"), [gmail])
        XCTAssertTrue(ToolCatalog.matching("").dropLast(experimental.count).allSatisfy { $0.maturity == .stable })
        XCTAssertNil(ToolCatalog.matching("Notion").first?.maturity.badge)
    }

    func testGoogleOAuthConfigurationsBelongToSeparateCatalogueEntries() throws {
        let services = [
            ("gmail", "gmail", ["gmail.modify"]),
            ("google-docs", "docs", ["documents"]),
            ("google-drive", "drive", ["drive.readonly", "drive.file"]),
            ("google-calendar", "calendar", ["calendar.calendarlist.readonly", "calendar.events"])
        ]
        var sharedClients: [MCPOAuthClientConfiguration]?
        for (id, service, scopes) in services {
            let tool = try XCTUnwrap(ToolCatalog.entries.first { $0.id == id })
            guard case .mcp(let configuration) = tool.configuration else { return XCTFail("Expected MCP") }
            XCTAssertEqual(configuration.endpoint.absoluteString, "https://\(service)mcp.googleapis.com/mcp/v1")
            let oauth = try XCTUnwrap(configuration.oauth)
            XCTAssertEqual(oauth.scopes, scopes.map { "https://www.googleapis.com/auth/" + $0 })
            XCTAssertEqual(oauth.clients.count, 2)
            if let sharedClients { XCTAssertEqual(oauth.clients, sharedClients) }
            sharedClients = oauth.clients
            for client in oauth.clients {
                XCTAssertEqual(client.redirectURI.scheme, client.id.split(separator: ".").reversed().joined(separator: "."))
            }
        }
        XCTAssertNil(MCPToolConfiguration(endpoint: URL(string: "https://custom.example/mcp")!).oauth)
    }
}
