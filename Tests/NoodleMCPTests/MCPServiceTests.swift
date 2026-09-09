import XCTest
import Foundation
import MCP
import NoodleCore
@testable import NoodleMCP

private final class TestVault: MCPCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: MCPCredentials] = [:]
    func load(_ id: UUID) -> MCPCredentials? { lock.withLock { values[id] } }
    func save(_ credentials: MCPCredentials, id: UUID) { lock.withLock { values[id] = credentials } }
    func remove(_ id: UUID) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private final class FixtureState: @unchecked Sendable {
    let lock = NSLock()
    var registrations = 0
    var refreshes = 0
    var calls = 0
    var invalidGrant = false
    var mismatchedIssuer = false
    var resourceIdentifier = "https://service.example/mcp"
    var pathMetadataMissing = false
    var tokenResources: [String] = []
    func response(_ request: URLRequest) throws -> (Int, [String: Any]) {
        try lock.withLock {
            switch request.url!.path {
            case "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource":
                if pathMetadataMissing && request.url!.path.hasSuffix("/mcp") { return (404, [:]) }
                return (200, ["resource": resourceIdentifier, "authorization_servers": ["https://service.example"], "scopes_supported": ["read"]])
            case "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration":
                return (200, ["issuer": mismatchedIssuer ? "https://wrong.example" : "https://service.example",
                              "authorization_endpoint": "https://service.example/authorize", "token_endpoint": "https://service.example/token",
                              "registration_endpoint": "https://service.example/register"])
            case "/register":
                registrations += 1
                return (201, ["client_id": "client-\(registrations)", "token_endpoint_auth_method": "none"])
            case "/token":
                let body = String(data: Self.body(request), encoding: .utf8) ?? ""
                let form = URLComponents(string: "https://service.example/?" + body)?.queryItems
                tokenResources.append(form?.first { $0.name == "resource" }?.value ?? "")
                if body.contains("refresh_token") {
                    refreshes += 1
                    if invalidGrant { return (400, ["error": "invalid_grant"]) }
                }
                return (200, ["access_token": "private-token", "refresh_token": "rotated-\(refreshes)", "token_type": "Bearer", "expires_in": 3600])
            case "/mcp":
                let object = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
                guard let id = object["id"] else { return (202, [:]) }
                let result: [String: Any]
                switch object["method"] as? String {
                case "initialize":
                    result = ["protocolVersion": Version.latest, "capabilities": ["tools": [:]],
                              "serverInfo": ["name": "Fixture", "version": "1"]]
                case "tools/list":
                    let params = object["params"] as? [String: Any]
                    if params?["cursor"] == nil {
                        result = ["tools": [["name": "first", "description": "First", "inputSchema": ["type": "object"]]], "nextCursor": "page2"]
                    } else {
                        result = ["tools": [["name": "second", "description": "Second", "inputSchema": ["type": "object"]]]]
                    }
                case "tools/call":
                    calls += 1
                    result = ["content": [["type": "text", "text": "ok"]], "structuredContent": ["accepted": true], "isError": false]
                default: result = [:]
                }
                return (200, ["jsonrpc": "2.0", "id": id, "result": result])
            default: return (404, [:])
            }
        }
    }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
private final class FixtureProtocol: URLProtocol {
    static var state = FixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, object) = try Self.state.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status != 202 { client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object)) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MCPServiceTests: XCTestCase {
    private let endpoint = URL(string: "https://service.example/mcp")!
    private let redirect = URL(string: "noodle-local://mcp/oauth/callback")!
    override func setUp() { FixtureProtocol.state = FixtureState() }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return config
    }
    private func service(vault: TestVault) -> MCPService {
        MCPService(credentials: vault, oauth: MCPOAuth(session: URLSession(configuration: configuration())), httpConfiguration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FixtureProtocol.self]
            return config
        })
    }
    private static let callback: @Sendable (URL) async throws -> URL = { url in
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertNotNil(query.first { $0.name == "code_challenge" }?.value)
        XCTAssertEqual(query.first { $0.name == "resource" }?.value, "https://service.example/mcp")
        var response = URLComponents(string: query.first { $0.name == "redirect_uri" }!.value!)!
        response.queryItems = [.init(name: "code", value: "one-time-code"), query.first { $0.name == "state" }!]
        return response.url!
    }
    func testTwoAccountsPersistIndependentRegistrationsAcrossRestart() async throws {
        let vault = TestVault()
        let first = try MCPConnectionRecord(name: "Notion", endpoint: endpoint)
        let second = try MCPConnectionRecord(name: "Notion", endpoint: endpoint)
        let client = service(vault: vault)
        try await client.signIn(first, redirectURI: redirect, browser: Self.callback)
        try await client.signIn(second, redirectURI: redirect, browser: Self.callback)
        XCTAssertEqual(FixtureProtocol.state.registrations, 2)
        XCTAssertNotEqual(vault.load(first.id)?.clientID, vault.load(second.id)?.clientID)
        let restarted = service(vault: vault)
        try await restarted.signIn(first, redirectURI: redirect, browser: Self.callback)
        XCTAssertEqual(FixtureProtocol.state.registrations, 2, "Reconnect must reuse the durable client registration")
        try await restarted.disconnect(first.id)
        XCTAssertNil(vault.load(first.id))
        XCTAssertNotNil(vault.load(second.id))
    }
    func testBadStateOrCallbackDoesNotStoreTokens() async throws {
        let vault = TestVault()
        let record = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
        do {
            try await service(vault: vault).signIn(record, redirectURI: redirect) { _ in
                URL(string: "noodle-local://mcp/oauth/callback?code=stolen&state=wrong")!
            }
            XCTFail("Unverified callback accepted")
        } catch { XCTAssertTrue(error is MCPServiceError) }
        XCTAssertNil(vault.load(record.id)?.accessToken)
        XCTAssertNotNil(vault.load(record.id)?.clientID, "Retry must preserve registration even if authorization was cancelled")
    }
    func testPaginatedDiscoveryStructuredResultsAndRevocation() async throws {
        let vault = TestVault()
        let record = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
        let client = service(vault: vault)
        try await client.signIn(record, redirectURI: redirect, browser: Self.callback)
        let list = MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
        let data = try await client.perform(list, connection: record)
        let tools = try JSONDecoder().decode(ListTools.Result.self, from: data)
        XCTAssertEqual(tools.tools.map(\.name), ["first", "second"])
        let inspect = MCPBridgeRequest(session: "", connectionID: record.id, action: .inspect, tool: "first", arguments: nil)
        let schema = try await client.perform(inspect, connection: record)
        XCTAssertEqual(try JSONDecoder().decode(Tool.self, from: schema).name, "first")
        let call = MCPBridgeRequest(session: "", connectionID: record.id, action: .call, tool: "first", arguments: Data("{}".utf8))
        let result = try await client.perform(call, connection: record)
        let object = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        XCTAssertEqual((object["structuredContent"] as? [String: Bool])?["accepted"], true)
        do { _ = try await client.perform(call, connection: record, authorized: { false }); XCTFail("Revoked assignment accepted") }
        catch { XCTAssertTrue(error is MCPServiceError) }
        XCTAssertEqual(FixtureProtocol.state.calls, 1)
    }
    func testConcurrentCallsRefreshOnceAndPersistRotation() async throws {
        let vault = TestVault()
        let record = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
        let client = service(vault: vault)
        try await client.signIn(record, redirectURI: redirect, browser: Self.callback)
        var stored = vault.load(record.id)!
        stored.expiresAt = .distantPast
        vault.save(stored, id: record.id)
        let request = MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
        async let first = client.perform(request, connection: record)
        async let second = client.perform(request, connection: record)
        _ = try await (first, second)
        XCTAssertEqual(FixtureProtocol.state.refreshes, 1)
        XCTAssertEqual(vault.load(record.id)?.refreshToken, "rotated-1")
    }
    func testInvalidGrantStopsRefreshAndRequiresReconnect() async throws {
        let vault = TestVault()
        let record = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
        let client = service(vault: vault)
        try await client.signIn(record, redirectURI: redirect, browser: Self.callback)
        var stored = vault.load(record.id)!
        stored.expiresAt = .distantPast
        vault.save(stored, id: record.id)
        FixtureProtocol.state.invalidGrant = true
        let request = MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
        for _ in 0..<2 {
            do { _ = try await client.perform(request, connection: record); XCTFail("Invalid grant accepted") } catch {}
        }
        XCTAssertEqual(FixtureProtocol.state.refreshes, 1)
        XCTAssertNil(vault.load(record.id)?.refreshToken)
        XCTAssertNotNil(vault.load(record.id)?.clientID)
    }
    func testIssuerMismatchPreventsRegistration() async throws {
        FixtureProtocol.state.mismatchedIssuer = true
        let vault = TestVault()
        let record = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
        do {
            try await service(vault: vault).signIn(record, redirectURI: redirect, browser: Self.callback)
            XCTFail("Mismatched issuer accepted")
        } catch { XCTAssertTrue(error is MCPServiceError) }
        XCTAssertEqual(FixtureProtocol.state.registrations, 0)
        XCTAssertNil(vault.load(record.id))
    }
    func testCanonicalRootResourcePersistsThroughAuthorizationRefreshAndDiscovery() async throws {
        FixtureProtocol.state.resourceIdentifier = "https://service.example"
        FixtureProtocol.state.pathMetadataMissing = true
        let vault = TestVault()
        let record = try MCPConnectionRecord(name: "Gateway", endpoint: endpoint)
        let client = service(vault: vault)
        try await client.signIn(record, redirectURI: redirect) { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "resource" }?.value, "https://service.example")
            XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
            var callback = URLComponents(string: query.first { $0.name == "redirect_uri" }!.value!)!
            callback.queryItems = [.init(name: "code", value: "one-time-code"), query.first { $0.name == "state" }!]
            return callback.url!
        }
        var stored = try XCTUnwrap(vault.load(record.id))
        XCTAssertEqual(stored.resource.absoluteString, "https://service.example")
        XCTAssertEqual(stored.endpoint, endpoint, "Canonical audience must not rewrite the MCP transport endpoint")
        stored.expiresAt = .distantPast
        vault.save(stored, id: record.id)
        let request = MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
        let data = try await client.perform(request, connection: record)
        XCTAssertEqual(try JSONDecoder().decode(ListTools.Result.self, from: data).tools.count, 2)
        XCTAssertEqual(FixtureProtocol.state.tokenResources, ["https://service.example", "https://service.example"])
    }
    func testResourceSubstitutionIsRejectedBeforeRegistration() async throws {
        for resource in ["https://other.example", "https://service.example.evil.example", "http://service.example",
                         "https://service.example:444", "https://service.example/other", "https://service.example/?tenant=other",
                         "https://service.example/#fragment", "https://user:password@service.example", "https://127.0.0.1"] {
            FixtureProtocol.state.resourceIdentifier = resource
            let vault = TestVault()
            let record = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
            do {
                try await service(vault: vault).signIn(record, redirectURI: redirect, browser: Self.callback)
                XCTFail("Unexpected resource accepted: \(resource)")
            } catch { XCTAssertTrue(error is MCPServiceError) }
            XCTAssertEqual(FixtureProtocol.state.registrations, 0)
            XCTAssertNil(vault.load(record.id))
        }
    }
    func testOnlyExactOrSameOriginRootResourcesAreAccepted() {
        for resource in [endpoint.absoluteString, "https://service.example", "https://service.example/", "https://SERVICE.example:443"] {
            XCTAssertTrue(MCPOAuth.acceptsResource(URL(string: resource)!, for: endpoint), resource)
        }
        for resource in ["https://service.example/mcp/", "https://service.example/%2F", "https://service.example/..",
                         "https://service.example/?", "https://service.example:8443"] {
            XCTAssertFalse(MCPOAuth.acceptsResource(URL(string: resource)!, for: endpoint), resource)
        }
    }
    func testCallbackTargetAndDuplicateStateAreRejected() async throws {
        for variant in 0..<3 {
            let vault = TestVault()
            let record = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
            do {
                try await service(vault: vault).signIn(record, redirectURI: redirect) { url in
                    var callback = URLComponents(url: try await Self.callback(url), resolvingAgainstBaseURL: false)!
                    if variant == 0 { callback.path = "/wrong" }
                    if variant == 1 { callback.user = "unexpected" }
                    if variant == 2 { callback.queryItems!.append(callback.queryItems!.first { $0.name == "state" }!) }
                    return callback.url!
                }
                XCTFail("Invalid callback accepted")
            } catch { XCTAssertTrue(error is MCPServiceError) }
            XCTAssertNil(vault.load(record.id)?.accessToken)
        }
    }
}
