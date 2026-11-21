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
}
