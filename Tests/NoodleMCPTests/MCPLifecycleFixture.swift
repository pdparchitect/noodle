import XCTest
import Foundation
import MCP
import NoodleCore
@testable import NoodleMCP

final class LifecycleVault: MCPCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: MCPCredentials] = [:]
    func load(_ id: UUID) -> MCPCredentials? { lock.withLock { values[id] } }
    func save(_ credentials: MCPCredentials, id: UUID) { lock.withLock { values[id] = credentials } }
    func remove(_ id: UUID) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

/// A cancellation-insensitive app callback, used to prove late callbacks are revalidated.
actor LifecycleGate {
    let entered = XCTestExpectation(description: "callback entered")
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        entered.fulfill()
        if !open { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

final class LifecycleHTTPGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "HTTP request paused")
    let stopped = XCTestExpectation(description: "HTTP request cancelled")
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var open = false
    func pause(_ completion: @escaping () -> Void) {
        let run = lock.withLock {
            if open { return true }
            self.completion = completion
            return false
        }
        entered.fulfill()
        if run { completion() }
    }
    func release() {
        let run = lock.withLock { open = true; defer { completion = nil }; return completion }
        run?()
    }
}

/// Awaiting an XCTest expectation is bounded even when the implementation hangs.
final class LifecycleOperation<Value: Sendable>: @unchecked Sendable {
    let finished = XCTestExpectation(description: "operation finished")
    private let lock = NSLock()
    private var stored: Result<Value, Error>?
    private(set) var task: Task<Value, Error>!
    var result: Result<Value, Error>? { lock.withLock { stored } }
    init(_ body: @escaping @Sendable () async throws -> Value) {
        task = Task { try await body() }
        Task {
            let result = await task.result
            lock.withLock { stored = result }
            finished.fulfill()
        }
    }
    func wait(seconds: TimeInterval = 2) async -> Bool {
        await XCTWaiter.fulfillment(of: [finished], timeout: seconds) == .completed
    }
}

final class MCPLifecycleFixture: @unchecked Sendable {
    let vault = LifecycleVault()
    let endpoint: URL
    let redirect = URL(string: "noodle-fixture://oauth/callback")!
    let record: MCPConnectionRecord
    let service: MCPService
    let session: URLSession
    private let state: LifecycleHTTPState

    init(expired: Bool = false) throws {
        endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).invalid/mcp")!
        record = try MCPConnectionRecord(name: "Offline lifecycle fixture", endpoint: endpoint)
        state = LifecycleHTTPState(endpoint: endpoint)
        LifecycleHTTPProtocol.register(state)
        let config: @Sendable () -> URLSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LifecycleHTTPProtocol.self]
            return configuration
        }
        session = URLSession(configuration: config())
        service = MCPService(credentials: vault, oauth: MCPOAuth(session: session), httpConfiguration: config)
        seed(expired: expired)
    }
    deinit { session.invalidateAndCancel(); LifecycleHTTPProtocol.unregister(state) }

    func seed(expired: Bool = false) {
        let origin = endpoint.deletingLastPathComponent()
        vault.save(MCPCredentials(endpoint: endpoint, issuer: origin,
            authorizationEndpoint: origin.appendingPathComponent("authorize"), tokenEndpoint: origin.appendingPathComponent("token"),
            clientID: "synthetic-client", redirectURI: redirect, resource: endpoint, scope: nil,
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: expired ? .distantPast : .distantFuture), id: record.id)
    }
    func hold(_ key: String) -> LifecycleHTTPGate { state.hold(key) }
    func count(_ key: String) -> Int { state.count(key) }
    func request(expiresIn: TimeInterval = 8) -> MCPBridgeRequest {
        MCPBridgeRequest(session: "fixture", connectionID: record.id, action: .call, tool: "echo", arguments: nil,
                         expiresAt: Date().addingTimeInterval(expiresIn))
    }
    func call(expiresIn: TimeInterval = 8, authorized: @escaping @Sendable () async -> Bool = { true }) -> LifecycleOperation<Data> {
        let request = request(expiresIn: expiresIn)
        return LifecycleOperation { [service, record] in try await service.perform(request, connection: record, authorized: authorized) }
    }
    static func callback(_ authorization: URL) throws -> URL {
        let query = try XCTUnwrap(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems)
        let target = try XCTUnwrap(query.first { $0.name == "redirect_uri" }?.value)
        var response = try XCTUnwrap(URLComponents(string: target))
        response.queryItems = [.init(name: "code", value: "synthetic-code"), try XCTUnwrap(query.first { $0.name == "state" })]
        return try XCTUnwrap(response.url)
    }
}

private final class LifecycleHTTPState: @unchecked Sendable {
    let endpoint: URL
    private let lock = NSLock()
    private var gates: [String: [LifecycleHTTPGate]] = [:]
    private var counts: [String: Int] = [:]
    init(endpoint: URL) { self.endpoint = endpoint }
    func hold(_ key: String) -> LifecycleHTTPGate {
        let gate = LifecycleHTTPGate()
        lock.withLock { gates[key, default: []].append(gate) }
        return gate
    }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
    func response(_ request: URLRequest) throws -> (Int, Data, LifecycleHTTPGate?) {
        let body = Self.body(request)
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let form = URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems
        let key = request.url!.path == "/token" ? (form?.first { $0.name == "grant_type" }?.value ?? "token") :
            (object["method"] as? String ?? request.url!.path)
        let gate: LifecycleHTTPGate? = lock.withLock {
            counts[key, default: 0] += 1
            guard !(gates[key] ?? []).isEmpty else { return nil }
            return gates[key]!.removeFirst()
        }
        let origin = endpoint.deletingLastPathComponent().absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let status: Int, payload: [String: Any]
        switch request.url!.path {
        case "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource":
            status = 200; payload = ["resource": endpoint.absoluteString, "authorization_servers": [origin]]
        case "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration":
            status = 200; payload = ["issuer": origin, "authorization_endpoint": origin + "/authorize",
                                     "token_endpoint": origin + "/token", "registration_endpoint": origin + "/register"]
        case "/register": status = 201; payload = ["client_id": "synthetic-registration", "token_endpoint_auth_method": "none"]
        case "/token": status = 200; payload = ["access_token": "synthetic-new-access", "refresh_token": "synthetic-rotated",
                                                "token_type": "Bearer", "expires_in": 3600]
        case "/mcp":
            if let id = object["id"] {
                let result: [String: Any]
                switch key {
                case "initialize": result = ["protocolVersion": Version.latest, "capabilities": ["tools": [:]], "serverInfo": ["name": "Offline", "version": "1"]]
                case "tools/call": result = ["content": [["type": "text", "text": "fixture-result"]], "isError": false]
                default: throw URLError(.unsupportedURL)
                }
                status = 200; payload = ["jsonrpc": "2.0", "id": id, "result": result]
            } else { status = 202; payload = [:] }
        default: throw URLError(.unsupportedURL)
        }
        return (status, try JSONSerialization.data(withJSONObject: payload), gate)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            result.append(bytes, count: count)
        }
        return result
    }
}

private final class LifecycleHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var registry: [String: LifecycleHTTPState] = [:]
    private let delivery = DispatchQueue(label: "noodle.lifecycle-fixture")
    private var stopped = false
    private var completed = false
    private var gate: LifecycleHTTPGate?
    static func register(_ state: LifecycleHTTPState) { lock.withLock { registry[state.endpoint.host!] = state } }
    static func unregister(_ state: LifecycleHTTPState) { _ = lock.withLock { registry.removeValue(forKey: state.endpoint.host!) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        delivery.async { [self] in
            do {
                guard let state = Self.lock.withLock({ Self.registry[request.url?.host ?? ""] }) else {
                    XCTFail("Unexpected fixture host; external requests are never permitted")
                    throw URLError(.unsupportedURL)
                }
                let (status, data, gate) = try state.response(request)
                self.gate = gate
                let respond = { [weak self] in
                    guard let self else { return }
                    self.delivery.async {
                        guard !self.stopped else { return }
                        let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil,
                                                       headerFields: ["Content-Type": "application/json"])!
                        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        if status != 202 { self.client?.urlProtocol(self, didLoad: data) }
                        self.completed = true
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                }
                if let gate { gate.pause(respond) } else { respond() }
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {
        delivery.async { [self] in
            guard !stopped else { return }
            stopped = true
            if !completed { gate?.stopped.fulfill() }
        }
    }
}
