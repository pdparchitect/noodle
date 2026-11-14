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
        let excluded = ["github", "betterstack", "zapier", "workato", "hubspot"]
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

    func testSelfRegisteringServicesAreListed() {
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.klaviyo.com/mcp")!)?.id, "klaviyo")
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.evernote.com/mcp")!)?.id, "evernote")
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.agentmail.to/mcp")!)?.id, "agentmail")
        for (id, endpoint) in ["asana": "https://mcp.asana.com/mcp", "calendly": "https://mcp.calendly.com",
                               "datadog": "https://mcp.datadoghq.com/api/unstable/mcp-server/mcp",
                               "socket": "https://mcp.socket.dev/", "semgrep": "https://mcp.semgrep.ai/mcp",
                               "elevenlabs": "https://api.us.elevenlabs.io/v1/mcp", "coinbase": "https://agents.coinbase.com/mcp",
                               "kling": "https://kling.ai/mcp", "inkbox": "https://inkbox.ai/mcp",
                               "krea": "https://api.krea.ai/mcp", "basecamp": "https://mcp.basecamp.com/mcp",
                               "wordpress": "https://public-api.wordpress.com/wpcom/v2/mcp/v1"] {
            XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: endpoint)!)?.id, id)
        }
    }

    func testAtlassianNamesItsAuthorizationServer() throws {
        let tool = try XCTUnwrap(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.atlassian.com/v1/mcp")!))
        guard case .mcp(let configuration) = tool.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.authorizationServer, URL(string: "https://mcp.atlassian.com"))
        XCTAssertNil(configuration.oauth)
    }

    func testEveryPresetHasABundledIcon() throws {
        let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Support/ToolIcons").standardizedFileURL
        for tool in ToolCatalog.entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: icons.appendingPathComponent(tool.iconName + ".icon").path), tool.id)
        }
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

    func testATokenPresetMakesTokenConnectionsAndOthersSignIn() throws {
        let endpoint = URL(string: "https://keys.example/mcp")!
        let keyed = try MCPToolConfiguration(endpoint: endpoint, tokenHeader: "x-apikey").makeConnection(name: "Keys")
        XCTAssertEqual(keyed.tokenHeader, "x-apikey")
        XCTAssertNil(try MCPToolConfiguration(endpoint: endpoint).makeConnection(name: "Signs In").tokenHeader)
        XCTAssertThrowsError(try MCPToolConfiguration(endpoint: endpoint, tokenHeader: "Cookie").makeConnection(name: "Bad"))
        for case .mcp(let configuration) in ToolCatalog.entries.map(\.configuration) {
            if let header = configuration.tokenHeader {
                XCTAssertEqual(try MCPConnectionRecord.validatedTokenHeader(header), header)
                XCTAssertNil(configuration.oauth, "a token preset has no sign-in to configure")
            }
        }
    }

    func testAnAppMayOfferItsOwnListReusingNoodlesEntries() throws {
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        XCTAssertEqual(ToolCatalog.entries, ToolCatalog.noodle)
        let notion = try XCTUnwrap(ToolCatalog.noodle.first { $0.id == "notion" })
        let own = ToolDefinition(id: "keys", name: "Keys", summary: "Lookups with a key.", defaultInstructions: "Look things up.",
                                 iconName: "keys", configuration: .mcp(.init(endpoint: URL(string: "https://keys.example/mcp")!, tokenHeader: "x-apikey")))
        ToolCatalog.use([notion, own])
        XCTAssertEqual(ToolCatalog.matching("").map(\.id), ["keys", "notion"])
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://keys.example/mcp")!), own)
        XCTAssertNil(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.airtable.com/mcp")!))
    }

    func testAPresetBuildsEachAccountsAddressFromItsFields() throws {
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        let domain = ToolField(key: "domain", title: "Okta domain", placeholder: "acme.okta.com", kind: .host)
        let region = ToolField(key: "region", title: "Region", placeholder: "us-1",
                               kind: .choice([.init(value: "us-1", title: "US-1"), .init(value: "eu-1", title: "EU-1")]))
        let directory = ToolDefinition(id: "directory", name: "Directory", summary: "People and sign-ins.", defaultInstructions: "Look people up.",
            iconName: "directory", configuration: .mcp(.init(endpointTemplate: "https://{domain}/mcp/{region}", fields: [domain, region],
                                                            tokenHeader: "Authorization")))
        ToolCatalog.use(ToolCatalog.noodle + [directory])
        guard case .mcp(let configuration) = directory.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://acme.okta.com/mcp/us-1", "a sample address from the placeholders")

        let acme = try directory.makeConnection(name: "Directory — Acme", values: ["domain": " Acme.Okta.com ", "region": "eu-1"])
        XCTAssertEqual(acme.endpoint.absoluteString, "https://acme.okta.com/mcp/eu-1")
        XCTAssertEqual(acme.settings, ["domain": "acme.okta.com", "region": "eu-1"])
        XCTAssertEqual(acme.catalogueID, "directory")
        XCTAssertEqual(acme.tokenHeader, "Authorization")
        let contoso = try directory.makeConnection(name: "Directory — Contoso", values: ["domain": "contoso.okta.com", "region": "us-1"])
        XCTAssertNotEqual(acme.id, contoso.id)
        XCTAssertEqual(ToolCatalog.definition(for: contoso), directory)
        XCTAssertEqual(try JSONDecoder().decode(MCPConnectionRecord.self, from: JSONEncoder().encode(acme)), acme)

        for bad in ["acme.okta.com/evil", "user@acme.okta.com", "acme.okta.com:8443", "https://acme.okta.com", "", "localhost", "-acme.okta.com"] {
            XCTAssertThrowsError(try directory.makeConnection(name: "Bad", values: ["domain": bad, "region": "us-1"]), bad)
        }
        XCTAssertThrowsError(try directory.makeConnection(name: "Bad", values: ["domain": "acme.okta.com", "region": "mars"]))
        XCTAssertThrowsError(try directory.makeConnection(name: "Bad", values: ["domain": "acme.okta.com"]))

        let notion = try XCTUnwrap(ToolCatalog.noodle.first { $0.id == "notion" })
        let signedIn = try notion.makeConnection(name: "Notion")
        XCTAssertEqual(signedIn.catalogueID, "notion")
        XCTAssertNil(signedIn.settings)
        let earlier = try MCPConnectionRecord(name: "Notion", endpoint: signedIn.endpoint)
        XCTAssertEqual(ToolCatalog.definition(for: earlier), notion, "connections made before entries were remembered match by address")
    }

    func testAClientCredentialsPresetBuildsEachAccountsTokenAddress() throws {
        let domain = ToolField(key: "domain", title: "Domain", placeholder: "acme.okta.com", kind: .host)
        let tool = ToolDefinition(id: "service-app", name: "Service App", summary: "As a service.", defaultInstructions: "Work.",
            iconName: "service-app", configuration: .mcp(.init(endpointTemplate: "https://{domain}/mcp", fields: [domain],
                clientCredentials: .init(tokenEndpointTemplate: "https://{domain}/oauth2/v1/token", scope: "okta.users.read"))))
        XCTAssertTrue(tool.needsSetUp)
        let account = try tool.makeConnection(name: "Acme", values: ["domain": "acme.okta.com"])
        XCTAssertEqual(account.clientCredentials, MCPClientCredentials(tokenEndpoint: URL(string: "https://acme.okta.com/oauth2/v1/token")!,
                                                                      scope: "okta.users.read"))
        XCTAssertNil(account.tokenHeader)
        XCTAssertEqual(try JSONDecoder().decode(MCPConnectionRecord.self, from: JSONEncoder().encode(account)), account)

        let endpoint = URL(string: "https://falcon.example/mcp")!
        let fixed = MCPClientCredentials(tokenEndpoint: URL(string: "https://falcon.example/oauth2/token")!, scope: nil)
        XCTAssertNoThrow(try MCPConnectionRecord(name: "Falcon", endpoint: endpoint, clientCredentials: fixed))
        XCTAssertThrowsError(try MCPConnectionRecord(name: "Both", endpoint: endpoint, tokenHeader: "x-apikey", clientCredentials: fixed),
                             "a connection uses one way to prove who it is")
        XCTAssertThrowsError(try MCPConnectionRecord(name: "Plain", endpoint: endpoint,
            clientCredentials: .init(tokenEndpoint: URL(string: "http://falcon.example/oauth2/token")!, scope: nil)))
    }
}
