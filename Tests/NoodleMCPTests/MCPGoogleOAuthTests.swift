import XCTest
import CryptoKit
import MCP
import NoodleCore
@testable import NoodleMCP

private enum GmailPreset {
    static let configuration: MCPToolConfiguration = {
        guard case .mcp(let configuration) = ToolCatalog.entries.first(where: { $0.id == "gmail" })!.configuration else {
            fatalError("Missing Gmail preset")
        }
        return configuration
    }()
    static let endpoint = configuration.endpoint
    static let oauth = configuration.oauth!
    static let scope = oauth.scopes.joined(separator: " ")
    static let production = oauth.clients.first { $0.bundleIdentifier == "com.pdparchitect.noodle" }!
    static let development = oauth.clients.first { $0.bundleIdentifier == "com.pdparchitect.noodle.local" }!
}

private final class GoogleTestVault: MCPCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: MCPCredentials] = [:]
    func load(_ id: UUID) -> MCPCredentials? { lock.withLock { values[id] } }
    func save(_ credentials: MCPCredentials, id: UUID) { lock.withLock { values[id] = credentials } }
    func remove(_ id: UUID) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private final class GoogleFixture: @unchecked Sendable {
    private let lock = NSLock()
    var requests: [URLRequest] = []
    var challenges: [String: String] = [:]
    var endpoint = GmailPreset.endpoint
    var requestedScope = GmailPreset.scope
    var grantedScope = GmailPreset.scope
    var invalidGrant = false
    func remember(code: String, challenge: String) { lock.withLock { challenges[code] = challenge } }
    func response(_ request: URLRequest) throws -> (Int, [String: Any]) {
        try lock.withLock {
            requests.append(request)
            let body = Self.body(request)
            if request.url == URL(string: "https://oauth2.googleapis.com/token")! {
                let query = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!.queryItems!
                let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
                XCTAssertNil(values["resource"])
                XCTAssertNil(values["client_secret"])
                XCTAssertEqual(values["client_id"], GmailPreset.production.id)
                if invalidGrant { return (400, ["error": "invalid_grant"]) }
                if let code = values["code"] {
                    let challenge = Data(SHA256.hash(data: Data(values["code_verifier", default: ""].utf8)))
                        .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                    XCTAssertEqual(challenge, challenges[code])
                    XCTAssertEqual(values["redirect_uri"], GmailPreset.production.redirectURI.absoluteString)
                    return (200, ["access_token": "access-" + code, "refresh_token": "refresh-" + code,
                                  "token_type": "Bearer", "expires_in": 3600, "scope": grantedScope])
                }
                XCTAssertEqual(values["grant_type"], "refresh_token")
                XCTAssertNil(values["code_verifier"])
                // A refresh response may omit a replacement refresh token and scope.
                return (200, ["access_token": "renewed-" + values["refresh_token", default: ""],
                              "token_type": "Bearer", "expires_in": 3600])
            }
            if request.url == endpoint {
                let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                guard let id = object["id"] else { return (202, [:]) }
                let result: [String: Any]
                if object["method"] as? String == "initialize" {
                    result = ["protocolVersion": Version.latest, "capabilities": ["tools": [:]],
                              "serverInfo": ["name": "Google fixture", "version": "1"]]
                } else if object["method"] as? String == "tools/call" {
                    let params = try XCTUnwrap(object["params"] as? [String: Any])
                    XCTAssertEqual(params["name"] as? String, "create_draft")
                    XCTAssertEqual((params["arguments"] as? [String: String])?["subject"], "Fixture draft")
                    result = ["content": [["type": "text", "text": "draft-created"]]]
                } else {
                    result = ["tools": ["list_labels", "create_draft"].map {
                        ["name": $0, "inputSchema": ["type": "object"]] as [String: Any]
                    }]
                }
                return (200, ["jsonrpc": "2.0", "id": id, "result": result])
            }
            XCTFail("Google presets must not discover metadata or register a client")
            return (404, [:])
        }
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class GoogleProtocol: URLProtocol {
    static var fixture = GoogleFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, object) = try Self.fixture.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            if status != 202 { client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object)) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MCPGoogleOAuthTests: XCTestCase {
    func testNativeBuildsHaveSeparateCallbacksAndExistingCredentialsStillDecode() throws {
        let production = GmailPreset.production, development = GmailPreset.development
        XCTAssertNotEqual(production.id, development.id)
        XCTAssertNotEqual(production.redirectURI, development.redirectURI)
        for client in GmailPreset.oauth.clients {
            XCTAssertEqual(MCPService.configuredRedirectURI(for: GmailPreset.endpoint,
                bundleIdentifier: client.bundleIdentifier), client.redirectURI)
            XCTAssertEqual(try MCPOAuth.preconfiguredCredentials(endpoint: GmailPreset.endpoint,
                redirect: client.redirectURI, configuration: GmailPreset.oauth)?.clientID, client.id)
        }
        XCTAssertNil(MCPService.configuredRedirectURI(for: GmailPreset.endpoint, bundleIdentifier: "unknown.app"))
        let old = MCPCredentials(endpoint: URL(string: "https://example.com/mcp")!, issuer: URL(string: "https://example.com")!,
            authorizationEndpoint: URL(string: "https://example.com/authorize")!, tokenEndpoint: URL(string: "https://example.com/token")!,
            clientID: "registered-client", redirectURI: URL(string: "noodle://mcp/oauth/callback")!,
            resource: URL(string: "https://example.com/mcp")!, scope: "read", accessToken: "saved-token")
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("profile"))
        let decoded = try JSONDecoder().decode(MCPCredentials.self, from: data)
        XCTAssertEqual(decoded.accessToken, "saved-token")
    }

    override func setUp() { GoogleProtocol.fixture = GoogleFixture() }
    private func service(_ vault: GoogleTestVault) -> MCPService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleProtocol.self]
        return MCPService(credentials: vault, oauth: MCPOAuth(session: URLSession(configuration: config)), httpConfiguration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GoogleProtocol.self]
            return config
        })
    }
    private static let browser: @Sendable (URL) async throws -> URL = { url in
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["scope"], GoogleProtocol.fixture.requestedScope)
        XCTAssertEqual(values["access_type"], "offline")
        XCTAssertEqual(values["prompt"], "consent select_account")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertNil(values["client_secret"])
        XCTAssertNil(values["resource"])
        let code = UUID().uuidString
        GoogleProtocol.fixture.remember(code: code, challenge: values["code_challenge"]!)
        var callback = URLComponents(string: values["redirect_uri"]!)!
        callback.queryItems = [.init(name: "code", value: code), .init(name: "state", value: values["state"])]
        return callback.url!
    }

    func testTwoAccountsUseBundledClientWithoutDiscoveryAndSurviveRefreshRestartAndRemoval() async throws {
        let vault = GoogleTestVault(), first = try MCPConnectionRecord(name: "Gmail Work", endpoint: GmailPreset.endpoint)
        let second = try MCPConnectionRecord(name: "Gmail Personal", endpoint: GmailPreset.endpoint)
        let client = service(vault)
        try await client.signIn(first, redirectURI: GmailPreset.production.redirectURI, browser: Self.browser)
        try await client.signIn(second, redirectURI: GmailPreset.production.redirectURI, browser: Self.browser)
        XCTAssertEqual(GoogleProtocol.fixture.requests.count, 2, "Only the two token exchanges should use the network")
        var one = try XCTUnwrap(vault.load(first.id))
        let two = try XCTUnwrap(vault.load(second.id))
        XCTAssertEqual(one.clientID, two.clientID)
        XCTAssertNotEqual(one.accessToken, two.accessToken)
        XCTAssertNotEqual(one.refreshToken, two.refreshToken)
        one.expiresAt = .distantPast
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(one)) as? [String: Any])
        saved["profile"] = "googleNative" // Credentials saved before configuration moved into the catalogue.
        vault.save(try JSONDecoder().decode(MCPCredentials.self, from: JSONSerialization.data(withJSONObject: saved)), id: first.id)
        let restarted = service(vault)
        let list = MCPBridgeRequest(session: "", connectionID: first.id, action: .tools, tool: nil, arguments: nil)
        let data = try await restarted.perform(list, connection: first)
        XCTAssertEqual(try JSONDecoder().decode(ListTools.Result.self, from: data).tools.first?.name, "list_labels")
        XCTAssertEqual(vault.load(first.id)?.refreshToken, one.refreshToken)
        XCTAssertNotEqual(vault.load(first.id)?.accessToken, one.accessToken)
        XCTAssertEqual(vault.load(second.id)?.accessToken, two.accessToken)
        try await restarted.signIn(first, redirectURI: GmailPreset.production.redirectURI, browser: Self.browser)
        XCTAssertEqual(vault.load(first.id)?.redirectURI, GmailPreset.production.redirectURI)
        try await restarted.disconnect(first.id)
        XCTAssertNil(vault.load(first.id))
        XCTAssertEqual(vault.load(second.id)?.refreshToken, two.refreshToken)
    }

    func testCancelledReconnectPreservesPreviousAccountAndBadStateExchangesNothing() async throws {
        let vault = GoogleTestVault(), client = service(vault)
        let record = try MCPConnectionRecord(name: "Gmail", endpoint: GmailPreset.endpoint)
        let redirect = GmailPreset.production.redirectURI
        try await client.signIn(record, redirectURI: redirect, browser: Self.browser)
        let previous = vault.load(record.id)?.accessToken
        do {
            try await client.signIn(record, redirectURI: GmailPreset.production.redirectURI) { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        do {
            try await client.signIn(record, redirectURI: redirect) { _ in URL(string: GmailPreset.production.redirectURI.absoluteString + "?state=wrong&code=wrong")! }
            XCTFail("Expected state rejection")
        } catch MCPServiceError.invalidCallback {}
        XCTAssertEqual(vault.load(record.id)?.accessToken, previous)
        XCTAssertEqual(GoogleProtocol.fixture.requests.count, 1)
    }

    func testWorkspaceServicesKeepScopesAndAccountTokensSeparateAcrossRefresh() async throws {
        let vault = GoogleTestVault(), client = service(vault)
        var accounts: [MCPConnectionRecord] = []
        var refreshTokens: [String] = []
        for id in ["google-docs", "google-drive", "google-calendar"] {
            let tool = try XCTUnwrap(ToolCatalog.entries.first { $0.id == id })
            guard case .mcp(let configuration) = tool.configuration else { return XCTFail("Expected MCP") }
            let oauth = try XCTUnwrap(configuration.oauth)
            let scope = oauth.scopes.joined(separator: " ")
            GoogleProtocol.fixture.endpoint = configuration.endpoint
            GoogleProtocol.fixture.requestedScope = scope
            GoogleProtocol.fixture.grantedScope = scope + " " + GmailPreset.scope
            for client in oauth.clients {
                XCTAssertEqual(MCPService.configuredRedirectURI(for: configuration.endpoint,
                    bundleIdentifier: client.bundleIdentifier), client.redirectURI)
            }
            for suffix in ["Work", "Personal"] {
                let account = try configuration.makeConnection(name: tool.name + " " + suffix)
                try await client.signIn(account, redirectURI: GmailPreset.production.redirectURI, browser: Self.browser)
                var saved = try XCTUnwrap(vault.load(account.id))
                XCTAssertEqual(saved.scope, scope, "Previously granted Gmail access must not become the service's requested scope")
                XCTAssertEqual(saved.endpoint, configuration.endpoint)
                refreshTokens.append(try XCTUnwrap(saved.refreshToken))
                saved.expiresAt = .distantPast
                vault.save(saved, id: account.id)
                _ = try await service(vault).perform(MCPBridgeRequest(session: "", connectionID: account.id,
                    action: .tools, tool: nil, arguments: nil), connection: account)
                XCTAssertEqual(vault.load(account.id)?.refreshToken, saved.refreshToken)
                XCTAssertNotEqual(vault.load(account.id)?.accessToken, saved.accessToken)
                accounts.append(account)
            }
        }
        XCTAssertEqual(Set(refreshTokens).count, accounts.count)
        try await client.disconnect(accounts[0].id)
        XCTAssertNil(vault.load(accounts[0].id))
        for (account, token) in zip(accounts.dropFirst(), refreshTokens.dropFirst()) {
            XCTAssertEqual(vault.load(account.id)?.refreshToken, token)
        }
    }

    func testGoogleConfigurationRejectsUnknownRedirectsAndMissingPermissions() async throws {
        for raw in ["noodle://mcp/oauth/callback", "com.googleusercontent.apps.unknown:/oauth2callback"] {
            XCTAssertThrowsError(try MCPOAuth.preconfiguredCredentials(endpoint: GmailPreset.endpoint, redirect: URL(string: raw)!, configuration: GmailPreset.oauth))
        }
        XCTAssertNil(MCPService.configuredRedirectURI(for: URL(string: "https://gmailmcp.googleapis.com/other")!))
        let vault = GoogleTestVault(), record = try MCPConnectionRecord(name: "Gmail", endpoint: GmailPreset.endpoint)
        GoogleProtocol.fixture.grantedScope = "https://www.googleapis.com/auth/gmail.readonly"
        do {
            try await service(vault).signIn(record, redirectURI: GmailPreset.production.redirectURI, browser: Self.browser)
            XCTFail("Missing draft permission accepted")
        } catch MCPServiceError.signInRequired {}
        XCTAssertNil(vault.load(record.id))
    }

    func testReadOnlyGrantRequiresReconnectBeforeDraftingAndPreservesAccountOnCancel() async throws {
        let vault = GoogleTestVault(), client = service(vault)
        let record = try MCPConnectionRecord(name: "Gmail", endpoint: GmailPreset.endpoint)
        let redirect = GmailPreset.production.redirectURI
        var stored = try XCTUnwrap(MCPOAuth.preconfiguredCredentials(endpoint: record.endpoint, redirect: redirect, configuration: GmailPreset.oauth))
        stored.accessToken = "old-read-only-token"
        stored.refreshToken = "old-refresh-token"
        stored.expiresAt = Date().addingTimeInterval(3600)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        object["scope"] = "https://www.googleapis.com/auth/gmail.readonly"
        vault.save(try JSONDecoder().decode(MCPCredentials.self, from: JSONSerialization.data(withJSONObject: object)), id: record.id)
        let connected = await client.hasCredentials(record.id)
        XCTAssertFalse(connected)
        let draft = MCPBridgeRequest(session: "", connectionID: record.id, action: .call, tool: "create_draft",
            arguments: try JSONEncoder().encode(["subject": "Fixture draft"]))
        do {
            _ = try await client.perform(draft, connection: record)
            XCTFail("Read-only grant used for drafting")
        } catch MCPServiceError.signInRequired {}
        XCTAssertTrue(GoogleProtocol.fixture.requests.isEmpty)
        do {
            try await client.signIn(record, redirectURI: redirect) { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(vault.load(record.id)?.accessToken, stored.accessToken)

        // Google can return an earlier grant alongside the requested permission.
        GoogleProtocol.fixture.grantedScope = "https://www.googleapis.com/auth/gmail.readonly " + GmailPreset.scope
        try await client.signIn(record, redirectURI: redirect, browser: Self.browser)
        let reconnected = await client.hasCredentials(record.id)
        XCTAssertTrue(reconnected)
        XCTAssertEqual(vault.load(record.id)?.scope, GmailPreset.scope)
        let result = try await client.perform(draft, connection: record)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("draft-created"))
    }

    func testExpiredTestingGrantRequiresReconnect() async throws {
        let vault = GoogleTestVault(), client = service(vault)
        let record = try MCPConnectionRecord(name: "Gmail", endpoint: GmailPreset.endpoint)
        try await client.signIn(record, redirectURI: GmailPreset.production.redirectURI, browser: Self.browser)
        var stored = vault.load(record.id)!
        stored.expiresAt = .distantPast
        vault.save(stored, id: record.id)
        GoogleProtocol.fixture.invalidGrant = true
        do {
            _ = try await client.perform(MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil), connection: record)
            XCTFail("Expired grant accepted")
        } catch MCPServiceError.signInRequired {}
        XCTAssertNil(vault.load(record.id)?.accessToken)
        XCTAssertNil(vault.load(record.id)?.refreshToken)
    }
}
