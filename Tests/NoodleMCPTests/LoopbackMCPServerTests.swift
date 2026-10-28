import XCTest
import Foundation
import Network
import MCP
import NoodleCore
@testable import NoodleMCP

/// Expected transport results, written down before the cases below:
/// 1. A POST answered with JSON returns the tool list.
/// 2. A POST answered with text/event-stream of `data:` lines returns the same tool list.
/// 3. An offered long-lived GET is not opened. streaming stays off, so GET count stays 0.
/// 4. A legacy stream that starts with `event: endpoint` fails and does not open that endpoint.
/// A redirect, including to another loopback port, is not followed.

private final class LoopbackServer: @unchecked Sendable {
    enum Mode { case json, sse, message, legacy, redirect(URL) }
    let mode: Mode
    private let lock = NSLock()
    private var gets = 0
    private var posts = 0
    private var paths: [String] = []
    private var listener: NWListener?
    private let ready = DispatchSemaphore(value: 0)
    private(set) var port: UInt16 = 0

    init(_ mode: Mode) throws {
        self.mode = mode
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
                self?.ready.signal()
            }
            if case .failed = state { self?.ready.signal() }
        }
        listener.start(queue: .global())
        ready.wait()
        if port == 0 { throw MCPConnectionError.message("The fake server did not start.") }
    }

    func stop() { listener?.cancel() }
    func counts() -> (gets: Int, posts: Int, paths: [String]) { lock.withLock { (gets, posts, paths) } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, _ in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let headerEnd = next.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: next[..<headerEnd.lowerBound], as: UTF8.self)
                let bodyStart = headerEnd.upperBound
                if let length = Self.contentLength(head), next.count >= bodyStart + length {
                    let body = next.subdata(in: bodyStart..<(bodyStart + length))
                    self.reply(head, body: body, on: connection)
                    return
                }
            }
            if complete {
                if let headerEnd = next.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: next[..<headerEnd.lowerBound], as: UTF8.self)
                    self.reply(head, body: next.subdata(in: headerEnd.upperBound..<next.endIndex), on: connection)
                } else {
                    connection.cancel()
                }
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func reply(_ head: String, body: Data, on connection: NWConnection) {
        let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.dropFirst().first.map(String.init) ?? ""
        lock.lock()
        paths.append(method + " " + path)
        if method == "GET" { gets += 1 } else if method == "POST" { posts += 1 }
        lock.unlock()
        switch mode {
        case .legacy:
            let legacy = Data("event: endpoint\ndata: /messages?sessionId=1\n\n".utf8)
            send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(legacy.count)\r\nConnection: close\r\n\r\n",
                 body: legacy, on: connection)
        case .redirect(let url):
            let response = "HTTP/1.1 302 Found\r\nLocation: \(url.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .json, .sse, .message:
            guard let payload = Self.rpc(body) else {
                let accepted = "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(accepted.utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if case .sse = mode {
                let framed = Data("data: \(String(decoding: payload, as: UTF8.self))\n\n".utf8)
                send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(framed.count)\r\nConnection: close\r\n\r\n",
                     body: framed, on: connection)
            } else if case .message = mode {
                let framed = Data("event: message\ndata: \(String(decoding: payload, as: UTF8.self))\n\n".utf8)
                send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(framed.count)\r\nConnection: close\r\n\r\n",
                     body: framed, on: connection)
            } else {
                send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n",
                     body: payload, on: connection)
            }
        }
    }

    private func send(_ headers: String, body: Data, on connection: NWConnection) {
        var bytes = Data(headers.utf8)
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func contentLength(_ head: String) -> Int? {
        for line in head.split(separator: "\r\n") {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.first?.lowercased() == "content-length" {
                return Int(pair.last?.trimmingCharacters(in: .whitespaces) ?? "")
            }
        }
        return nil
    }

    /// A JSON-RPC response for a request that has an id. Notifications return nil so the caller answers 202.
    private static func rpc(_ body: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] else { return nil }
        let result: [String: Any]
        switch object["method"] as? String {
        case "initialize":
            result = ["protocolVersion": Version.latest,
                      "capabilities": ["tools": [String: String]()],
                      "serverInfo": ["name": "Fake", "version": "1"]]
        case "tools/list":
            result = ["tools": [["name": "echo", "description": "Echo", "inputSchema": ["type": "object"]]]]
        default:
            result = [:]
        }
        return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }
}

final class LoopbackMCPServerTests: XCTestCase {
    private func service() -> MCPService {
        MCPService(credentials: MemoryVault(), oauth: MCPOAuth(), httpConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MCPGuardedHTTP.self]
            return configuration
        })
    }

    private func connection(port: UInt16) throws -> MCPConnectionRecord {
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        return try MCPConnectionRecord(name: "Local", loopback: url, authorization: .none,
                                       consentedOrigin: MCPConnectionRecord.origin(of: url))
    }

    private func tools(port: UInt16) async throws -> String {
        let record = try connection(port: port)
        let request = MCPBridgeRequest(session: "local", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
        let data = try await service().perform(request, connection: record)
        return String(decoding: data, as: UTF8.self)
    }

    func testPostJSONListsToolsAndDoesNotOpenAGetStream() async throws {
        let server = try LoopbackServer(.json)
        defer { server.stop() }
        let text = try await tools(port: server.port)
        XCTAssertTrue(text.contains("echo"))
        let counts = server.counts()
        XCTAssertGreaterThan(counts.posts, 0)
        XCTAssertEqual(counts.gets, 0)
        XCTAssertFalse(counts.paths.contains { $0.hasPrefix("GET ") })
    }

    func testPostEventStreamListsTools() async throws {
        let server = try LoopbackServer(.sse)
        defer { server.stop() }
        let text = try await tools(port: server.port)
        XCTAssertTrue(text.contains("echo"))
        XCTAssertEqual(server.counts().gets, 0)
    }

    func testStreamableEventMessageListsTools() async throws {
        let server = try LoopbackServer(.message)
        defer { server.stop() }
        let text = try await tools(port: server.port)
        XCTAssertTrue(text.contains("echo"))
        XCTAssertEqual(server.counts().gets, 0)
    }

    func testLegacySeparateEventStreamFailsClearly() async throws {
        let server = try LoopbackServer(.legacy)
        defer { server.stop() }
        do {
            _ = try await tools(port: server.port)
            XCTFail("A legacy event stream should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("separate event stream"), error.localizedDescription)
        }
        let counts = server.counts()
        XCTAssertEqual(counts.gets, 0)
        XCTAssertFalse(counts.paths.contains { $0.contains("/messages") })
    }

    func testRedirectIsNotFollowed() async throws {
        let elsewhere = try LoopbackServer(.json)
        defer { elsewhere.stop() }
        let server = try LoopbackServer(.redirect(URL(string: "http://127.0.0.1:\(elsewhere.port)/mcp")!))
        defer { server.stop() }
        do { _ = try await tools(port: server.port) } catch {}
        XCTAssertEqual(elsewhere.counts().posts, 0)
        XCTAssertEqual(elsewhere.counts().gets, 0)
        XCTAssertGreaterThan(server.counts().posts, 0)
    }
}

private final class MemoryVault: MCPCredentialStorage, @unchecked Sendable {
    func load(_ id: UUID) throws -> MCPCredentials? { nil }
    func save(_ credentials: MCPCredentials, id: UUID) throws {}
    func remove(_ id: UUID) throws {}
}
