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
            XCTAssertNotNil(UUID(uuidString: tool.id), "\(tool.name) is not identified by a UUID")
            XCTAssertFalse(tool.iconName.contains("/"))
            switch tool.configuration {
            case .connection(let configuration):
                let endpoint = configuration.endpoint
                XCTAssertEqual(try ToolConnection.validatedEndpoint(endpoint), endpoint)
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
        XCTAssertEqual(ToolCatalog.matching("nOtIoN MCP").map(\.iconName), ["notion"])
        XCTAssertTrue(ToolCatalog.matching("nothing-matches-this").isEmpty)
        XCTAssertNil(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://example.com/mcp")!))
        let excluded = ["github", "betterstack", "zapier", "workato", "hubspot"]
        XCTAssertTrue(Set(excluded).isDisjoint(with: ToolCatalog.entries.map(\.iconName)))
        let notion = ToolCatalog.matching("Notion")[0]
        XCTAssertEqual(ToolCatalog.availableName(for: notion, existingNames: []), "Notion")
        XCTAssertEqual(ToolCatalog.availableName(for: notion, existingNames: ["notion", "Notion 2"]), "Notion 3")
    }

    func testPipedreamUsesThePublicEndUserGateway() throws {
        let tool = try XCTUnwrap(ToolCatalog.matching("Pipedream").first)
        XCTAssertEqual(tool.configuration, .connection(.init(endpoint: URL(string: "https://mcp.pipedream.net/v2")!)))
        XCTAssertEqual(tool.iconName, "pipedream")
        XCTAssertTrue(tool.defaultInstructions.contains("account is unclear"))
        XCTAssertTrue(tool.defaultInstructions.contains("never request or handle their credentials"))
    }

    func testSelfRegisteringServicesAreListed() {
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.klaviyo.com/mcp")!)?.iconName, "klaviyo")
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.evernote.com/mcp")!)?.iconName, "evernote")
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.agentmail.to/mcp")!)?.iconName, "agentmail")
        for (id, endpoint) in ["asana": "https://mcp.asana.com/mcp", "calendly": "https://mcp.calendly.com",
                               "datadog": "https://mcp.datadoghq.com/api/unstable/mcp-server/mcp",
                               "socket": "https://mcp.socket.dev/", "semgrep": "https://mcp.semgrep.ai/mcp",
                               "elevenlabs": "https://api.us.elevenlabs.io/v1/mcp", "coinbase": "https://agents.coinbase.com/mcp",
                               "kling": "https://kling.ai/mcp", "inkbox": "https://inkbox.ai/mcp",
                               "krea": "https://api.krea.ai/mcp", "basecamp": "https://mcp.basecamp.com/mcp",
                               "wordpress": "https://public-api.wordpress.com/wpcom/v2/mcp/v1"] {
            XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: endpoint)!)?.iconName, id)
        }
    }

    func testAtlassianNamesItsAuthorizationServer() throws {
        let tool = try XCTUnwrap(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.atlassian.com/v1/mcp")!))
        guard case .connection(let configuration) = tool.configuration else { return XCTFail() }
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
        case .connection(let configuration):
            let connection = try configuration.makeConnection(name: "Notion Work")
            var registry = ToolConnectionRegistry()
            registry.connections.append(connection)
            XCTAssertTrue(registry.assignments.isEmpty)
            let roundTrip = try JSONDecoder().decode(ToolConnectionRegistry.self, from: JSONEncoder().encode(registry))
            XCTAssertEqual(roundTrip, registry)
            XCTAssertEqual(connection.name, "Notion Work")
        }
    }

    func testExperimentalPresetsSortLastAndAreSearchable() throws {
        let gmail = try XCTUnwrap(ToolCatalog.matching("experimental").first)
        XCTAssertEqual(gmail.iconName, "gmail")
        XCTAssertEqual(gmail.maturity, .experimental)
        XCTAssertEqual(gmail.maturity.badge, "Experimental")
        let experimental = ToolCatalog.matching("experimental")
        XCTAssertEqual(experimental.map(\.iconName), ["gmail", "google-calendar", "google-docs", "google-drive"])
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
            let tool = try XCTUnwrap(ToolCatalog.entries.first { $0.iconName == id })
            guard case .connection(let configuration) = tool.configuration else { return XCTFail("Expected MCP") }
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
        XCTAssertNil(ToolConnectionConfiguration(endpoint: URL(string: "https://custom.example/mcp")!).oauth)
    }

    func testATokenPresetMakesTokenConnectionsAndOthersSignIn() throws {
        let endpoint = URL(string: "https://keys.example/mcp")!
        let keyed = try ToolConnectionConfiguration(endpoint: endpoint, tokenHeader: "x-apikey").makeConnection(name: "Keys")
        XCTAssertEqual(keyed.tokenHeader, "x-apikey")
        XCTAssertNil(try ToolConnectionConfiguration(endpoint: endpoint).makeConnection(name: "Signs In").tokenHeader)
        XCTAssertThrowsError(try ToolConnectionConfiguration(endpoint: endpoint, tokenHeader: "Cookie").makeConnection(name: "Bad"))
        for case .connection(let configuration) in ToolCatalog.entries.map(\.configuration) {
            if let header = configuration.tokenHeader {
                XCTAssertEqual(try ToolConnection.validatedTokenHeader(header), header)
                XCTAssertNil(configuration.oauth, "a token preset has no sign-in to configure")
            }
        }
    }

    func testAnAppMayOfferItsOwnListReusingNoodlesEntries() throws {
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        XCTAssertEqual(ToolCatalog.entries, ToolCatalog.noodle)
        let notion = try XCTUnwrap(ToolCatalog.noodle.first { $0.iconName == "notion" })
        let own = ToolDefinition(id: "keys", name: "Keys", summary: "Lookups with a key.", defaultInstructions: "Look things up.",
                                 iconName: "keys", configuration: .connection(.init(endpoint: URL(string: "https://keys.example/mcp")!, tokenHeader: "x-apikey")))
        ToolCatalog.use([notion, own])
        XCTAssertEqual(ToolCatalog.matching("").map(\.iconName), ["keys", "notion"])
        XCTAssertEqual(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://keys.example/mcp")!), own)
        XCTAssertNil(ToolCatalog.definition(forMCPEndpoint: URL(string: "https://mcp.airtable.com/mcp")!))
    }

    func testAPresetBuildsEachAccountsAddressFromItsFields() throws {
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        let domain = ToolField(key: "domain", title: "Okta domain", placeholder: "acme.okta.com", kind: .host)
        let region = ToolField(key: "region", title: "Region", placeholder: "us-1",
                               kind: .choice([.init(value: "us-1", title: "US-1"), .init(value: "eu-1", title: "EU-1")]))
        let directory = ToolDefinition(id: "directory", name: "Directory", summary: "People and sign-ins.", defaultInstructions: "Look people up.",
            iconName: "directory", configuration: .connection(.init(endpointTemplate: "https://{domain}/mcp/{region}", fields: [domain, region],
                                                            tokenHeader: "Authorization")))
        ToolCatalog.use(ToolCatalog.noodle + [directory])
        guard case .connection(let configuration) = directory.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://acme.okta.com/mcp/us-1", "a sample address from the placeholders")

        let acme = try directory.makeConnection(name: "Directory — Acme", values: ["domain": " Acme.Okta.com ", "region": "eu-1"])
        XCTAssertEqual(acme.endpoint.absoluteString, "https://acme.okta.com/mcp/eu-1")
        XCTAssertEqual(acme.settings, ["domain": "acme.okta.com", "region": "eu-1"])
        XCTAssertEqual(acme.catalogueID, "directory")
        XCTAssertEqual(acme.tokenHeader, "Authorization")
        let contoso = try directory.makeConnection(name: "Directory — Contoso", values: ["domain": "contoso.okta.com", "region": "us-1"])
        XCTAssertNotEqual(acme.id, contoso.id)
        XCTAssertEqual(ToolCatalog.definition(for: contoso), directory)
        XCTAssertEqual(try JSONDecoder().decode(ToolConnection.self, from: JSONEncoder().encode(acme)), acme)

        for bad in ["acme.okta.com/evil", "user@acme.okta.com", "acme.okta.com:8443", "https://acme.okta.com", "", "localhost", "-acme.okta.com"] {
            XCTAssertThrowsError(try directory.makeConnection(name: "Bad", values: ["domain": bad, "region": "us-1"]), bad)
        }
        XCTAssertThrowsError(try directory.makeConnection(name: "Bad", values: ["domain": "acme.okta.com", "region": "mars"]))
        XCTAssertThrowsError(try directory.makeConnection(name: "Bad", values: ["domain": "acme.okta.com"]))

        let notion = try XCTUnwrap(ToolCatalog.noodle.first { $0.iconName == "notion" })
        let signedIn = try notion.makeConnection(name: "Notion")
        XCTAssertEqual(signedIn.catalogueID, notion.id)
        XCTAssertNil(signedIn.settings)
        let earlier = try ToolConnection(name: "Notion", endpoint: signedIn.endpoint)
        XCTAssertEqual(ToolCatalog.definition(for: earlier), notion, "connections made before entries were remembered match by address")
    }

    func testAClientCredentialsPresetBuildsEachAccountsTokenAddress() throws {
        let domain = ToolField(key: "domain", title: "Domain", placeholder: "acme.okta.com", kind: .host)
        let tool = ToolDefinition(id: "service-app", name: "Service App", summary: "As a service.", defaultInstructions: "Work.",
            iconName: "service-app", configuration: .connection(.init(endpointTemplate: "https://{domain}/mcp", fields: [domain],
                clientCredentials: .init(tokenEndpointTemplate: "https://{domain}/oauth2/v1/token", scope: "okta.users.read"))))
        XCTAssertTrue(tool.needsSetUp)
        let account = try tool.makeConnection(name: "Acme", values: ["domain": "acme.okta.com"])
        XCTAssertEqual(account.clientCredentials, ConnectionClientCredentials(tokenEndpoint: URL(string: "https://acme.okta.com/oauth2/v1/token")!,
                                                                      scope: "okta.users.read"))
        XCTAssertNil(account.tokenHeader)
        XCTAssertEqual(try JSONDecoder().decode(ToolConnection.self, from: JSONEncoder().encode(account)), account)

        let endpoint = URL(string: "https://falcon.example/mcp")!
        let fixed = ConnectionClientCredentials(tokenEndpoint: URL(string: "https://falcon.example/oauth2/token")!, scope: nil)
        XCTAssertNoThrow(try ToolConnection(name: "Falcon", endpoint: endpoint, clientCredentials: fixed))
        XCTAssertThrowsError(try ToolConnection(name: "Both", endpoint: endpoint, tokenHeader: "x-apikey", clientCredentials: fixed),
                             "a connection uses one way to prove who it is")
        XCTAssertThrowsError(try ToolConnection(name: "Plain", endpoint: endpoint,
            clientCredentials: .init(tokenEndpoint: URL(string: "http://falcon.example/oauth2/token")!, scope: nil)))
    }

    func testAnAdapterPresetMakesConnectionsTheAppServesThatStayOnThisMac() throws {
        let tool = ToolDefinition(id: "lookup", name: "Lookup", summary: "Reputation lookups.", defaultInstructions: "Look up.",
            iconName: "lookup", configuration: .connection(.init(endpoint: URL(string: "https://api.lookup.example/v3")!, tokenHeader: "x-apikey",
                                                          adapter: "lookup")))
        let account = try tool.makeConnection(name: "Lookup")
        XCTAssertEqual(account.adapter, "lookup")
        XCTAssertTrue(tool.staysOnThisMac)
        XCTAssertEqual(try JSONDecoder().decode(ToolConnection.self, from: JSONEncoder().encode(account)), account)
        let notion = try XCTUnwrap(ToolCatalog.noodle.first { $0.iconName == "notion" })
        XCTAssertFalse(notion.staysOnThisMac)
        XCTAssertNil(try notion.makeConnection(name: "Notion").adapter)
        XCTAssertThrowsError(try ToolConnection(name: "Bad", endpoint: account.endpoint, adapter: "has spaces"))
    }

    func testAnAdapterMayReachAServiceThePersonRunsOnThisMacOrTheLocalNetwork() throws {
        let address = ToolField(key: "address", title: "Address", placeholder: "http://localhost:3000", kind: .address)
        for kept in ["http://localhost:3000", "http://192.168.1.20:3000/grafana", "http://grafana:3000", "http://grafana.local",
                     "http://100.101.102.103", "http://[::1]:3000", "https://grafana.example.com", "https://10.0.0.5:8443"] {
            XCTAssertNoThrow(try address.validated(kept), kept)
        }
        XCTAssertEqual(try address.validated(" http://LOCALHOST:3000/ "), "http://localhost:3000")
        for refused in ["http://grafana.example.com", "http://8.8.8.8", "http://172.32.0.1", "ftp://localhost",
                        "https://user:pw@grafana.example.com", "https://grafana.example.com/?a=b", "localhost:3000", "grafana.example.com", ""] {
            XCTAssertThrowsError(try address.validated(refused), refused)
        }

        let dashboards = ToolDefinition(id: "dashboards", name: "Dashboards", summary: "Dashboards.", defaultInstructions: "Look.",
            iconName: "dashboards", configuration: .connection(.init(endpointTemplate: "{address}/api", fields: [address],
                                                                     tokenHeader: "Authorization", adapter: "dashboards")))
        let local = try dashboards.makeConnection(name: "Dashboards", values: ["address": "http://localhost:3000"])
        XCTAssertEqual(local.endpoint.absoluteString, "http://localhost:3000/api")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = ToolConnectionRegistry()
        registry.connections = [local]
        try registry.save(root: root)
        XCTAssertEqual(try ToolConnectionRegistry.load(root: root).connections.map(\.endpoint), [local.endpoint])

        // Only an adapter's: an MCP server stays at a public HTTPS address, and HTTP never leaves the local network.
        XCTAssertThrowsError(try ToolConnection(name: "Local MCP", endpoint: URL(string: "http://localhost:3000/mcp")!))
        XCTAssertThrowsError(try ToolConnection(name: "Local MCP", endpoint: URL(string: "https://localhost:3000/mcp")!))
        XCTAssertThrowsError(try ToolConnection(name: "Plain", endpoint: URL(string: "http://grafana.example.com/api")!, adapter: "dashboards"))
    }

    func testAnAccountRemadeFromNewDetailsKeepsTheNameBotsKnowItByAndThePersonsText() throws {
        let organisation = ToolField(key: "org", title: "Organisation", placeholder: "kestrel", kind: .identifier)
        let errors = ToolDefinition(id: "errors", name: "Errors", summary: "Issues.", defaultInstructions: "Read.", iconName: "errors",
            configuration: .connection(.init(endpointTemplate: "https://errors.example/api/0/organizations/{org}", fields: [organisation],
                                             tokenHeader: "Authorization", adapter: "errors")))
        var account = try errors.makeConnection(name: "Errors — Work", values: ["org": "sentry"])
        account.description = "Mine."
        account.instructions = "Look at web first."
        account.iconData = Data([1, 2, 3])
        let fresh = try errors.makeConnection(id: account.id, name: "Something else", values: ["org": "kestrel"])
        let remade = account.remade(as: fresh)
        XCTAssertEqual(remade.endpoint.absoluteString, "https://errors.example/api/0/organizations/kestrel")
        XCTAssertEqual(remade.settings, ["org": "kestrel"])
        XCTAssertEqual(remade.id, account.id)
        XCTAssertEqual(remade.skillName, account.skillName, "bots would lose the name they call it by")
        XCTAssertEqual(remade.name, "Errors — Work")
        XCTAssertEqual(remade.description, "Mine.")
        XCTAssertEqual(remade.instructions, "Look at web first.")
        XCTAssertEqual(remade.iconData, Data([1, 2, 3]))
        XCTAssertEqual(remade.tokenHeader, "Authorization")
    }

    func testARememberedPresetCountsOnlyWhenTheConnectionIsAtAnAddressItMakes() throws {
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        let notion = try XCTUnwrap(ToolCatalog.noodle.first { $0.iconName == "notion" })
        var disguised = try ToolConnection(name: "Notion", endpoint: URL(string: "https://attacker.example/mcp")!)
        disguised.catalogueID = "notion"
        XCTAssertNil(ToolCatalog.definition(for: disguised), "a connection elsewhere passed as a preset the organisation allows")
        guard case .toolConnection(let catalogueID, _) = Organisation.action(for: disguised) else { return XCTFail() }
        XCTAssertNil(catalogueID, "the custom-server rules were skipped")
        XCTAssertEqual(ToolCatalog.definition(for: try notion.makeConnection(name: "Notion")), notion)

        let domain = ToolField(key: "domain", title: "Domain", placeholder: "acme.okta.com", kind: .host)
        let directory = ToolDefinition(id: "directory", name: "Directory", summary: "People.", defaultInstructions: "Look up.",
            iconName: "directory", configuration: .connection(.init(endpointTemplate: "https://{domain}/mcp", fields: [domain], tokenHeader: "x-key")))
        ToolCatalog.use(ToolCatalog.noodle + [directory])
        var account = try directory.makeConnection(name: "Acme", values: ["domain": "acme.okta.com"])
        XCTAssertEqual(ToolCatalog.definition(for: account), directory)
        account.settings = ["domain": "contoso.okta.com"]
        XCTAssertNil(ToolCatalog.definition(for: account), "saved details that do not make its address")
    }

    func testATokenSchemeIsAWordAndNeedsATokenHeader() throws {
        let endpoint = URL(string: "https://acme.okta.com/api/v1")!
        XCTAssertEqual(try ToolConnectionConfiguration(endpoint: endpoint, tokenHeader: "Authorization", tokenScheme: "SSWS")
            .makeConnection(name: "Okta").tokenScheme, "SSWS")
        for scheme in ["", "SS WS", "Bearer:", String(repeating: "a", count: 40)] {
            XCTAssertThrowsError(try ToolConnection(name: "Bad", endpoint: endpoint, tokenHeader: "Authorization", tokenScheme: scheme), scheme)
        }
        XCTAssertThrowsError(try ToolConnection(name: "Bad", endpoint: endpoint, tokenScheme: "SSWS"), "a scheme without a token")
    }

    func testATokenCanBeComposedFromTwoValues() throws {
        let basic = ComposedToken(first: "Access ID", second: "Access Key", format: .basic)
        XCTAssertEqual(try basic.compose(" su1d ", "key/with+chars"), Data("su1d:key/with+chars".utf8).base64EncodedString())
        XCTAssertThrowsError(try basic.compose("has:colon", "k"), "Basic auth's first value cannot hold a colon")
        XCTAssertThrowsError(try basic.compose("", "k"))
        let keys = ComposedToken(first: "Access Key", second: "Secret Key", format: .template("accessKey={first};secretKey={second}"))
        XCTAssertEqual(try keys.compose("abc", "def"), "accessKey=abc;secretKey=def")
        XCTAssertThrowsError(try keys.compose("a;b", "c"), "a value cannot break out of its place in the template")
        XCTAssertThrowsError(try keys.compose("a", "two\nlines"))

        let tool = ToolDefinition(id: "logs", name: "Logs", summary: "Logs.", defaultInstructions: "Search.", iconName: "logs",
            configuration: .connection(.init(endpoint: URL(string: "https://api.logs.example/v1")!, tokenHeader: "Authorization", tokenScheme: "Basic",
                                      composedToken: basic, adapter: "logs")))
        XCTAssertTrue(tool.needsSetUp)
        let account = try tool.makeConnection(name: "Logs")
        XCTAssertEqual(account.tokenHeader, "Authorization")
        XCTAssertEqual(account.tokenScheme, "Basic")
        guard case .connection(let configuration) = tool.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.composedToken, basic)
    }
}
