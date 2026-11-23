import XCTest
import Foundation
import NoodleCore
@testable import NoodleToolConnections

/// A service that answers from a list, in turn, a little later than asked, and counts how many requests it held at once.
private final class PacedService: URLProtocol, @unchecked Sendable {
    struct Answer { var status: Int; var headers: [String: String] = [:]; var body = "{}" }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [Answer] = []
    nonisolated(unsafe) private static var held = 0
    nonisolated(unsafe) private(set) static var mostHeld = 0
    nonisolated(unsafe) private(set) static var methods: [String] = []

    static func reset(_ list: [Answer]) { lock.withLock { answers = list; held = 0; mostHeld = 0; methods = [] } }
    static var asked: Int { lock.withLock { methods.count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let answer = Self.lock.withLock {
            Self.methods.append(request.httpMethod ?? "GET")
            Self.held += 1
            Self.mostHeld = max(Self.mostHeld, Self.held)
            return Self.answers.isEmpty ? Answer(status: 200) : Self.answers.removeFirst()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            Self.lock.withLock { Self.held -= 1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// The pauses an access waited, in seconds, without waiting them.
private final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    var waited: [Double] { lock.withLock { values } }
    func record(_ seconds: Double) { lock.withLock { values.append(seconds) } }
}

/// No sign-ins: the connections here have none.
private struct NoSignIns: MCPCredentialStorage {
    func load(_ id: UUID) -> MCPCredentials? { nil }
    func save(_ credentials: MCPCredentials, id: UUID) {}
    func remove(_ id: UUID) {}
}

/// What a request waiting its turn came to, once it did.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    var value: Bool? { lock.withLock { result } }
    func set(_ value: Bool) { lock.withLock { result = value } }
}

/// An adapter whose call and feed each send six requests to its service at once, for a service that takes two.
private struct BurstAdapter: ToolConnectionAdapter {
    var simultaneousRequests: Int? { 2 }
    var watchedTool: String? { "burst" }
    func tools(for connection: ToolConnection) async throws -> Data { Data(#"{"tools":[]}"#.utf8) }
    func call(_ tool: String, arguments: Data, connection: ToolConnection, access: ToolConnectionAccess) async throws -> Data {
        try await Self.burst(connection, access)
        return Data(#"{"content":[{"type":"text","text":"done"}],"isError":false}"#.utf8)
    }
    func alerts(since: Date, connection: ToolConnection, access: ToolConnectionAccess) async throws -> [ServiceAlert] {
        try await Self.burst(connection, access)
        return []
    }
    static func burst(_ connection: ToolConnection, _ access: ToolConnectionAccess) async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<6 {
                group.addTask { try await access.data(for: URLRequest(url: connection.endpoint.appendingPathComponent("item/\(index)"))).1.statusCode }
            }
            for try await status in group { XCTAssertEqual(status, 200) }
        }
    }
}

final class AdapterRequestPacingTests: XCTestCase {
    private let pauses = Pauses()
    private func access() -> ToolConnectionAccess {
        ToolConnectionAccess(endpoint: URL(string: "https://service.example/v1")!, authorization: nil, pause: { [pauses] in pauses.record($0) }) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PacedService.self]
            return configuration
        }
    }
    private func send(_ method: String = "GET") async throws -> Int {
        var request = URLRequest(url: URL(string: "https://service.example/v1/items")!)
        request.httpMethod = method
        return try await access().data(for: request).1.statusCode
    }
    private static let quota = #"{"error":{"code":403,"message":"Request rate higher than configured.","errors":[{"message":"Request rate higher than configured.","domain":"usageLimits","reason":"quotaExceeded"}]}}"#

    func testARequestTheServiceThrottledIsTriedAgainAfterAPause() async throws {
        // As Google does, a quota can come back as 403 rather than 429.
        PacedService.reset([.init(status: 429, headers: ["Retry-After": "2"]), .init(status: 403, body: Self.quota), .init(status: 200)])
        let status = try await send()
        XCTAssertEqual(status, 200)
        XCTAssertEqual(PacedService.asked, 3)
        XCTAssertEqual(pauses.waited.first, 2, "the service's Retry-After was not waited")
        XCTAssertEqual(pauses.waited.count, 2)
    }

    func testOnlyThrottlingAndAnUnavailableReadAreTriedAgain() async throws {
        let notEnabled = #"{"error":{"code":403,"message":"Admin SDK API has not been used in project 1 before or it is disabled.","errors":[{"domain":"usageLimits","reason":"accessNotConfigured"}]}}"#
        PacedService.reset([.init(status: 403, body: notEnabled)])
        let forbidden = try await send()
        XCTAssertEqual(forbidden, 403)
        XCTAssertEqual(PacedService.asked, 1, "a refusal that is not a quota was tried again")

        // A write the service could not answer may still have been done, so it is never sent twice.
        PacedService.reset([.init(status: 503), .init(status: 200)])
        let write = try await send("POST")
        XCTAssertEqual(write, 503)
        XCTAssertEqual(PacedService.asked, 1, "a write was sent again")

        PacedService.reset([.init(status: 503), .init(status: 200)])
        let read = try await send()
        XCTAssertEqual(read, 200)
        XCTAssertEqual(PacedService.asked, 2)

        // A throttled write was turned away before it was done, so it is.
        PacedService.reset([.init(status: 429), .init(status: 200)])
        let throttledWrite = try await send("POST")
        XCTAssertEqual(throttledWrite, 200)
    }

    /// AWS throttles with a 400 or 503 naming a throttling error, in JSON or XML, rather than a 429: a request signed for
    /// AWS goes again, a read or a write, as AWS did nothing with it; any other 400, and any other service's, does not.
    func testAWSThrottlingIsTriedAgainOnlyForRequestsSignedForAWS() async throws {
        let key = ConnectionAWSKey(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "token")
        let aws = ToolConnectionAccess(endpoint: URL(string: "https://amazonaws.com")!, authorization: .aws(key, defaultRegion: "us-east-1"),
                                       pause: { [pauses] in pauses.record($0) }) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PacedService.self]
            return configuration
        }
        func call(_ method: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "https://cloudtrail.eu-west-1.amazonaws.com/")!)
            request.httpMethod = method
            return try await aws.data(for: request).1.statusCode
        }
        let json = #"{"__type":"com.amazonaws.cloudtrail.v20131101#ThrottlingException","message":"Rate exceeded"}"#
        let xml = "<ErrorResponse><Error><Type>Sender</Type><Code>Throttling</Code><Message>Rate exceeded</Message></Error></ErrorResponse>"
        let ec2 = "<Response><Errors><Error><Code>RequestLimitExceeded</Code><Message>Request limit exceeded.</Message></Error></Errors></Response>"
        let tooMany = #"{"__type":"TooManyRequestsException","message":"slow down"}"#
        PacedService.reset([.init(status: 400, body: json), .init(status: 400, body: xml), .init(status: 503, body: ec2),
                            .init(status: 400, body: tooMany), .init(status: 200)])
        let throttled = try await call("POST")
        XCTAssertEqual(throttled, 400, "four attempts at most")
        XCTAssertEqual(PacedService.asked, 4)
        PacedService.reset([.init(status: 400, body: json), .init(status: 200)])
        let recovered = try await call("POST")
        XCTAssertEqual(recovered, 200)
        XCTAssertEqual(PacedService.asked, 2)

        // A 400 for anything else is AWS's answer, never sent twice.
        PacedService.reset([.init(status: 400, body: #"{"__type":"InvalidParameterException","message":"bad"}"#), .init(status: 200)])
        let invalid = try await call("POST")
        XCTAssertEqual(invalid, 400)
        XCTAssertEqual(PacedService.asked, 1)
        PacedService.reset([.init(status: 400, body: #"{"__type":"LimitExceededException","message":"quota of detectors"}"#), .init(status: 200)])
        let quota = try await call("POST")
        XCTAssertEqual(quota, 400, "a quota that waiting does not lift is not throttling")
        XCTAssertEqual(PacedService.asked, 1)

        // The same throttling answer from any other service is that service's own 400.
        PacedService.reset([.init(status: 400, body: json), .init(status: 200)])
        let elsewhere = try await send("POST")
        XCTAssertEqual(elsewhere, 400)
        XCTAssertEqual(PacedService.asked, 1, "another service's 400 was sent again")
        XCTAssertFalse(ToolConnectionAccess.isAWSThrottle(403, Data(json.utf8)))
        XCTAssertFalse(ToolConnectionAccess.isAWSThrottle(400, Data("not json <Code>Throttling".utf8)))
    }

    /// Only the code of the error the answer is counts: a Code element anywhere else, such as in a listing's items or
    /// nested inside the error, is never taken for throttling, so a write is not sent twice on its account.
    func testAWSThrottlingIsReadOnlyFromAWSsErrorEnvelopes() async throws {
        let key = ConnectionAWSKey(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: nil)
        let aws = ToolConnectionAccess(endpoint: URL(string: "https://amazonaws.com")!, authorization: .aws(key, defaultRegion: "us-east-1"),
                                       pause: { [pauses] in pauses.record($0) }) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PacedService.self]
            return configuration
        }
        let envelopes = ["<ErrorResponse><Error><Type>Sender</Type><Code>Throttling</Code></Error><RequestId>1</RequestId></ErrorResponse>",
                         "<Response><Errors><Error><Code>RequestLimitExceeded</Code><Message>slow</Message></Error></Errors><RequestID>1</RequestID></Response>",
                         "<?xml version=\"1.0\"?><Error><Code>SlowDown</Code><Message>Reduce your request rate.</Message></Error>",
                         #"{"__type":"ThrottlingException"}"#, #"{"code":"TooManyRequestsException"}"#]
        for body in envelopes { XCTAssertTrue(ToolConnectionAccess.isAWSThrottle(400, Data(body.utf8)), body) }
        let elsewhere = ["<CreateTagsResponse><tagSet><item><Code>Throttling</Code></item></tagSet></CreateTagsResponse>",
                         "<ErrorResponse><Error><Detail><Code>Throttling</Code></Detail><Code>ValidationError</Code></Error></ErrorResponse>",
                         "<Response><Error><Code>Throttling</Code></Error></Response>",
                         "<ErrorResponse><Error><Code>TransactionInProgressException</Code></Error></ErrorResponse>",
                         #"{"error":{"__type":"ThrottlingException"}}"#, #"{"Items":[{"Code":"Throttling"}]}"#]
        for body in elsewhere { XCTAssertFalse(ToolConnectionAccess.isAWSThrottle(400, Data(body.utf8)), body) }
        for body in elsewhere.prefix(2) {
            PacedService.reset([.init(status: 400, body: body), .init(status: 200)])
            var request = URLRequest(url: URL(string: "https://ec2.eu-west-1.amazonaws.com/")!)
            request.httpMethod = "POST"
            let status = try await aws.data(for: request).1.statusCode
            XCTAssertEqual(status, 400, body)
            XCTAssertEqual(PacedService.asked, 1, "a write was sent again for a Code outside the error envelope: \(body)")
        }
    }

    func testTryingAgainStopsAfterFourAttemptsOrWhenTheServiceAsksForTooLongAWait() async throws {
        PacedService.reset(Array(repeating: .init(status: 429), count: 10))
        let persistent = try await send()
        XCTAssertEqual(persistent, 429)
        XCTAssertEqual(PacedService.asked, 4)
        XCTAssertLessThanOrEqual(pauses.waited.reduce(0, +), 30)

        PacedService.reset([.init(status: 429, headers: ["Retry-After": "120"]), .init(status: 200)])
        let distant = try await send()
        XCTAssertEqual(distant, 429)
        XCTAssertEqual(PacedService.asked, 1, "a call waited longer than a bot would")
    }

    func testAConnectionSendsItsServiceNoMoreRequestsAtOnceThanTheServiceTakes() async throws {
        PacedService.reset([])
        let service = ToolConnectionService(credentials: NoSignIns(), oauth: MCPOAuth(session: URLSession(configuration: .ephemeral)),
                                            httpConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PacedService.self]
            return configuration
        })
        await service.useAdapters(["burst": BurstAdapter()])
        let connection = try ToolConnection(name: "Burst", endpoint: URL(string: "https://service.example/v1")!, adapter: "burst")

        let call = MCPBridgeRequest(session: "", connectionID: connection.id, action: .call, tool: "burst", arguments: Data("{}".utf8))
        _ = try await service.perform(call, connection: connection)
        XCTAssertEqual(PacedService.asked, 6)
        XCTAssertLessThanOrEqual(PacedService.mostHeld, 2, "a bot's call sent more at once than the service takes")

        PacedService.reset([])
        _ = try await service.alerts(since: Date(), connection: connection)
        XCTAssertEqual(PacedService.asked, 6)
        XCTAssertLessThanOrEqual(PacedService.mostHeld, 2, "checking for alerts sent more at once than the service takes")
    }

    func testTheServiceCanAskForAPauseUntilADate() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let later = formatter.string(from: Date().addingTimeInterval(10))
        PacedService.reset([.init(status: 429, headers: ["Retry-After": later]), .init(status: 200)])
        let status = try await send()
        XCTAssertEqual(status, 200)
        let waited = try XCTUnwrap(pauses.waited.first)
        XCTAssertTrue((8...10.5).contains(waited), "waited \(waited) s for a date 10 s away")
    }

    func testRetriesAreCountedForTheCallThatMadeThemThroughItsConnectionsTurns() async throws {
        PacedService.reset([.init(status: 429), .init(status: 503)])
        let service = pacedService()
        await service.useAdapters(["burst": BurstAdapter()])
        let connection = try ToolConnection(name: "Burst", endpoint: URL(string: "https://service.example/v1")!, adapter: "burst")
        let retries = Retries()
        let call = MCPBridgeRequest(session: "", connectionID: connection.id, action: .call, tool: "burst", arguments: Data("{}".utf8))
        _ = try await Retries.$counting.withValue(retries) { try await service.perform(call, connection: connection) }
        XCTAssertEqual(retries.total, 2)
        XCTAssertEqual(retries.shown, "2 requests retried")
        XCTAssertEqual(Retries().shown, "")
    }

    func testARequestCancelledWhileWaitingItsTurnGivesUpItsPlace() async throws {
        let gate = RequestGate(limit: 1)
        try await gate.enter()
        let waiting = Task { try await gate.enter() }
        while await gate.queued == 0 { await Task.yield() }
        waiting.cancel()
        let outcome = Outcome()
        Task { do { try await waiting.value; outcome.set(false) } catch { outcome.set(error is CancellationError) } }
        // Bounded only so a gate that ignores the cancellation fails rather than hangs.
        for _ in 0..<500 where outcome.value == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(outcome.value, true, "a cancelled request kept waiting for its turn")
        guard outcome.value == true else { return }
        let queued = await gate.queued
        XCTAssertEqual(queued, 0)
        // Its place was not taken by the cancelled request: the next one gets in once the first is done.
        await gate.leave()
        try await gate.enter()
    }

    func testARemovedConnectionsTurnsAreForgotten() async throws {
        PacedService.reset([])
        let service = pacedService()
        await service.useAdapters(["burst": BurstAdapter()])
        let connection = try ToolConnection(name: "Burst", endpoint: URL(string: "https://service.example/v1")!, adapter: "burst")
        let call = MCPBridgeRequest(session: "", connectionID: connection.id, action: .call, tool: "burst", arguments: Data("{}".utf8))
        _ = try await service.perform(call, connection: connection)
        let kept = await service.gates[connection.id]
        XCTAssertNotNil(kept)
        try await service.disconnect(connection.id)
        let forgotten = await service.gates[connection.id]
        XCTAssertNil(forgotten)
    }

    private func pacedService() -> ToolConnectionService {
        ToolConnectionService(credentials: NoSignIns(), oauth: MCPOAuth(session: URLSession(configuration: .ephemeral)), httpConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PacedService.self]
            return configuration
        })
    }
}
