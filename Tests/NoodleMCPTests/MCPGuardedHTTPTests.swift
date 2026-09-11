import XCTest
import Foundation
@testable import NoodleMCP

final class MCPGuardedHTTPTests: XCTestCase {
    private let endpoint = URL(string: "https://guard-fixture.invalid/mcp")!
    private let limit = 8 * 1_048_576

    override func setUp() { GuardHTTPFixture.reset() }
    override func tearDown() { GuardHTTPFixture.reset() }

    func testRequestAndSuccessfulResponsePreserveBodyAndExplicitCredentials() async throws {
        let responseBody = Data(#"{"result":"ok"}"#.utf8)
        GuardHTTPFixture.reset(chunks: [responseBody])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"method":"tools/list"}"#.utf8)
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        let client = GuardClient()
        let loader = makeLoader(request, client: client)
        loader.startLoading()
        await fulfillment(of: [client.completed], timeout: 5)
        let sent = try XCTUnwrap(GuardHTTPFixture.requests.first)
        XCTAssertEqual(sent.url, endpoint)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(try body(of: sent), request.httpBody)
        XCTAssertEqual(GuardHTTPFixture.requests.count, 1)
        XCTAssertEqual(client.body, responseBody)
        XCTAssertEqual(client.responses.first?.statusCode, 200)
        XCTAssertEqual(client.cachePolicies, [.notAllowed])
        XCTAssertEqual(client.finishes, 1)
        XCTAssertTrue(client.errors.isEmpty)
    }

    func testInvalidEndpointsFailBeforeStartingTransport() async {
        for address in ["http://guard-fixture.invalid/mcp", "https://user:secret@guard-fixture.invalid/mcp",
                        "https://guard-fixture.invalid/mcp#fragment", "https://127.0.0.1/mcp", "file:///tmp/mcp"] {
            let client = GuardClient()
            let loader = makeLoader(URLRequest(url: URL(string: address)!), client: client)
            loader.startLoading()
            await fulfillment(of: [client.completed], timeout: 5)
            XCTAssertEqual(client.errors.count, 1)
            guard case MCPServiceError.invalidMetadata? = client.errors.first else {
                return XCTFail("Invalid endpoints must fail validation")
            }
            XCTAssertEqual(client.finishes, 0)
            XCTAssertTrue(client.body.isEmpty)
        }
        XCTAssertTrue(GuardHTTPFixture.requests.isEmpty)
    }

    func testRedirectDelegateRejectsEveryRedirectStatus() throws {
        let client = GuardClient()
        let loader = makeLoader(URLRequest(url: endpoint), client: client)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: endpoint) // Suspended: no network request is made.
        for status in [301, 302, 303, 307, 308] {
            var redirected = URLRequest(url: URL(string: "https://other.invalid/mcp")!)
            redirected.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
            let response = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil,
                headerFields: ["Location": redirected.url!.absoluteString]))
            var decisions = 0
            loader.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { next in
                decisions += 1
                XCTAssertNil(next, "A bearer request must never follow a redirect")
            }
            XCTAssertEqual(decisions, 1)
        }
    }

    func testSessionDoesNotFollowRedirectsEvenWhenTheDestinationWouldSucceed() async throws {
        let destination = URL(string: "https://other.invalid/mcp")!
        let destinationBody = Data("must not reach the MCP client".utf8)
        for status in [301, 302, 303, 307, 308] {
            // Positive control: this fixture really redirects an ordinary URLSession.
            GuardHTTPFixture.reset(status: status, chunks: [destinationBody], redirect: destination)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GuardHTTPFixture.self]
            let control = URLSession(configuration: configuration)
            defer { control.invalidateAndCancel() }
            let (data, response) = try await control.data(from: endpoint)
            XCTAssertEqual(data, destinationBody)
            XCTAssertEqual(response.url, destination)
            XCTAssertEqual(GuardHTTPFixture.requests.map(\.url), [endpoint, destination])

            GuardHTTPFixture.reset(status: status, chunks: [destinationBody], redirect: destination)
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
            let client = GuardClient()
            let loader = makeLoader(request, client: client)
            loader.startLoading()
            await fulfillment(of: [client.completed], timeout: 5)
            XCTAssertEqual(GuardHTTPFixture.requests.map(\.url), [endpoint], "The destination must never be contacted")
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertEqual(client.finishes, 0)
            XCTAssertTrue(client.responses.isEmpty)
            XCTAssertTrue(client.body.isEmpty)
        }
    }

    func testRedirectResponsesAreNotDeliveredAsSuccessfulMCPResponses() async {
        for status in [301, 302, 307, 308] {
            GuardHTTPFixture.reset(status: status, chunks: [Data("redirect body".utf8)])
            let client = GuardClient()
            let loader = makeLoader(URLRequest(url: endpoint), client: client)
            loader.startLoading()
            await fulfillment(of: [client.completed], timeout: 5)
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertTrue(client.responses.isEmpty)
            XCTAssertTrue(client.body.isEmpty)
            XCTAssertEqual(client.finishes, 0)
        }
    }

    func testAdvertisedOversizedResponseIsRejectedBeforeDeliveringBody() async {
        GuardHTTPFixture.reset(headers: ["Content-Length": String(limit + 1)], chunks: [Data("too large".utf8)])
        let client = GuardClient()
        let loader = makeLoader(URLRequest(url: endpoint), client: client)
        loader.startLoading()
        await fulfillment(of: [client.completed], timeout: 5)
        XCTAssertTrue(client.responses.isEmpty)
        XCTAssertTrue(client.body.isEmpty)
        XCTAssertEqual(client.errors.count, 1)
        XCTAssertEqual(client.finishes, 0)
    }

    func testResponseAtByteLimitSucceeds() async {
        let first = Data(repeating: 0x61, count: limit / 2)
        let second = Data(repeating: 0x62, count: limit / 2)
        GuardHTTPFixture.reset(headers: ["Content-Length": String(limit)], chunks: [first, second])
        let client = GuardClient()
        let loader = makeLoader(URLRequest(url: endpoint), client: client)
        loader.startLoading()
        await fulfillment(of: [client.completed], timeout: 5)
        XCTAssertEqual(client.body, first + second, "The full allowed response must arrive intact and in order")
        XCTAssertEqual(client.finishes, 1)
        XCTAssertTrue(client.errors.isEmpty)
    }

    func testUnadvertisedStreamCannotExceedCumulativeByteLimit() async {
        let chunk = Data(repeating: 0x61, count: limit / 2)
        GuardHTTPFixture.reset(chunks: [chunk, chunk, Data([0x62])])
        let client = GuardClient()
        let loader = makeLoader(URLRequest(url: endpoint), client: client)
        loader.startLoading()
        await fulfillment(of: [client.completed], timeout: 5)
        XCTAssertLessThanOrEqual(client.body.count, limit)
        XCTAssertFalse(client.body.contains(0x62), "Bytes beyond the limit must not reach the SDK")
        XCTAssertEqual(client.errors.count, 1)
        XCTAssertEqual(client.finishes, 0)
    }

    func testTransportFailureReachesClientWithoutReportingSuccess() async {
        GuardHTTPFixture.reset(error: URLError(.timedOut))
        let client = GuardClient()
        let loader = makeLoader(URLRequest(url: endpoint), client: client)
        loader.startLoading()
        await fulfillment(of: [client.completed], timeout: 5)
        XCTAssertEqual((client.errors.first as? URLError)?.code, .timedOut)
        XCTAssertEqual(client.errors.count, 1)
        XCTAssertEqual(client.finishes, 0)
    }

    func testStoppingAnActiveLoadCancelsItsTransport() async {
        let started = expectation(description: "fixture transport started")
        let stopped = expectation(description: "fixture transport stopped")
        GuardHTTPFixture.reset(hold: true, started: { started.fulfill() }, stopped: { stopped.fulfill() })
        let client = GuardClient()
        let loader = makeLoader(URLRequest(url: endpoint), client: client)
        loader.startLoading()
        await fulfillment(of: [started], timeout: 5)
        loader.stopLoading()
        await fulfillment(of: [stopped, client.completed], timeout: 5)
        XCTAssertEqual((client.errors.first as? URLError)?.code, .cancelled)
        XCTAssertEqual(client.finishes, 0)
        XCTAssertTrue(client.body.isEmpty)
        loader.stopLoading() // Repeated cancellation is harmless.
    }

    func testNonHTTPResponseIsRejected() {
        let loader = makeLoader(URLRequest(url: endpoint), client: GuardClient())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: endpoint)
        let response = URLResponse(url: endpoint, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        var decisions = 0
        loader.urlSession(session, dataTask: task, didReceive: response) { disposition in
            decisions += 1
            XCTAssertEqual(disposition, .cancel)
        }
        XCTAssertEqual(decisions, 1)
    }

    private func makeLoader(_ request: URLRequest, client: GuardClient) -> MCPGuardedHTTP {
        let loader = MCPGuardedHTTP(request: request, cachedResponse: nil, client: client)
        loader.sessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GuardHTTPFixture.self]
            return configuration
        }
        return loader
    }

    private func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            result.append(bytes, count: count)
        }
        return result
    }
}

private final class GuardClient: NSObject, URLProtocolClient {
    let completed = XCTestExpectation(description: "guard completed")
    override init() {
        super.init()
        completed.assertForOverFulfill = true
    }
    private let lock = NSLock()
    private var storedBody = Data(), storedResponses: [HTTPURLResponse] = []
    private var storedErrors: [Error] = [], storedFinishes = 0
    private var storedCachePolicies: [URLCache.StoragePolicy] = []
    var body: Data { lock.withLock { storedBody } }
    var responses: [HTTPURLResponse] { lock.withLock { storedResponses } }
    var errors: [Error] { lock.withLock { storedErrors } }
    var finishes: Int { lock.withLock { storedFinishes } }
    var cachePolicies: [URLCache.StoragePolicy] { lock.withLock { storedCachePolicies } }
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
        lock.withLock {
            if let response = response as? HTTPURLResponse { storedResponses.append(response) }
            storedCachePolicies.append(policy)
        }
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { lock.withLock { storedBody.append(data) } }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) {
        lock.withLock { storedFinishes += 1 }
        completed.fulfill()
    }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) {
        lock.withLock { storedErrors.append(error) }
        completed.fulfill()
    }
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {
        XCTFail("Redirects must not reach the client")
    }
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { XCTFail("Unexpected authentication challenge") }
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}

private final class GuardHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var plan = Plan()
    private struct Plan {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var error: URLError?
        var redirect: URL?
        var hold = false
        var started: (() -> Void)?
        var stopped: (() -> Void)?
    }
    private var onStop: (() -> Void)?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(status: Int = 200, headers: [String: String] = [:], chunks: [Data] = [], error: URLError? = nil,
                      redirect: URL? = nil, hold: Bool = false, started: (() -> Void)? = nil, stopped: (() -> Void)? = nil) {
        lock.withLock {
            recorded = []
            plan = Plan(status: status, headers: headers, chunks: chunks, error: error, redirect: redirect,
                        hold: hold, started: started, stopped: stopped)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let plan = Self.lock.withLock { Self.recorded.append(request); return Self.plan }
        onStop = plan.stopped
        plan.started?()
        if plan.hold { return }
        if let error = plan.error { client?.urlProtocol(self, didFailWithError: error); return }
        if let destination = plan.redirect, request.url != destination {
            let response = HTTPURLResponse(url: request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            var redirected = request
            redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: plan.redirect == nil ? plan.status : 200,
                                       httpVersion: "HTTP/1.1", headerFields: plan.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { onStop?(); onStop = nil }
}
