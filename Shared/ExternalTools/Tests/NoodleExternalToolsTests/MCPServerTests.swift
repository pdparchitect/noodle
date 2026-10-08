import Foundation
@testable import NoodleExternalTools
import Testing

private struct Echo: MCPToolSource {
    func tools() async throws -> Data {
        try JSONSerialization.data(withJSONObject: [["name": "echo", "description": "Echo.", "inputSchema": ["type": "object"]]])
    }
    func call(_ name: String, arguments: Data) async -> Data {
        let object = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let text = "\(name):\(object["text"] as? String ?? "")"
        return try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "isError": false])
    }
}

private func reply(_ server: MCPServer, _ message: [String: Any]) async throws -> [String: Any]? {
    guard let data = await server.handle(try JSONSerialization.data(withJSONObject: message)) else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Suite struct MCPServerTests {
    private let server = MCPServer(name: "noodle-browser", version: "1.2.3", instructions: "Use it.", source: Echo())

    @Test func initializeAnswersWithTheClientsVersionWhenKnown() async throws {
        let answer = try #require(try await reply(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "c", "version": "1"]]]))
        let result = try #require(answer["result"] as? [String: Any])
        #expect(answer["id"] as? Int == 1)
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "noodle-browser")
        #expect(result["instructions"] as? String == "Use it.")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test func anUnknownVersionGetsTheLatestKnown() async throws {
        let answer = try #require(try await reply(server, ["jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "1999-01-01"]]))
        #expect((answer["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.versions.last)
        #expect(answer["id"] as? String == "a")
    }

    @Test func notificationsGetNoAnswer() async throws {
        #expect(try await reply(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func toolsAreListedAndCalled() async throws {
        let list = try #require(try await reply(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "echo")
        let call = try #require(try await reply(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "echo", "arguments": ["text": "hi"]]]))
        let content = try #require((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "echo:hi")
    }

    @Test func pingAndUnknownMethods() async throws {
        let ping = try #require(try await reply(server, ["jsonrpc": "2.0", "id": 4, "method": "ping"]))
        #expect(ping["result"] is [String: Any])
        let unknown = try #require(try await reply(server, ["jsonrpc": "2.0", "id": 5, "method": "resources/list"]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    /// JSON may carry U+2028, U+2029 and U+0085 unescaped; only a newline ends a message.
    @Test func messagesEndOnlyAtNewlines() async throws {
        let input = Pipe(), output = Pipe()
        let text = "a\u{2028}b\u{2029}c\u{0085}d"
        let call = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                               "params": ["name": "echo", "arguments": ["text": text]]])
        input.fileHandleForWriting.write(call + Data("\n".utf8))
        try input.fileHandleForWriting.close()
        await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let lines = output.fileHandleForReading.readDataToEndOfFile().split(separator: UInt8(ascii: "\n"))
        #expect(lines.count == 1)
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        #expect(answer["id"] as? Int == 7)
        let content = try #require((answer["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "echo:" + text)
    }

    /// JSON that parses but is not a request is an invalid request, and so is one with an unusable id.
    @Test func invalidRequestsAreSaidToBe() async throws {
        for body in ["[1,2]", "42", #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#] {
            let data = try #require(await server.handle(Data(body.utf8)), "\(body)")
            let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((answer["error"] as? [String: Any])?["code"] as? Int == -32600, "\(body)")
        }
    }

    @Test func malformedInputIsAParseError() async throws {
        let data = try #require(await server.handle(Data("{nope".utf8)))
        let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((answer["error"] as? [String: Any])?["code"] as? Int == -32700)
    }
}

@Suite struct ExternalConnectionTests {
    @Test func aRequestAndItsAnswerCrossTheSocket() async throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("x-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("x.sock")
        let server = try ExternalConnectionServer(socket: url, verify: { _ in }) { data in
            Data("got ".utf8) + data
        }
        let answer = try await Task.detached {
            try ExternalConnection.call(Data("hello".utf8), socket: url, seconds: 5, verify: { _ in })
        }.value
        #expect(String(decoding: answer, as: UTF8.self) == "got hello")
        withExtendedLifetime(server) {}
    }

    @Test func aRefusedPeerGetsAnErrorNotTheHandler() async throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("x-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("x.sock")
        let server = try ExternalConnectionServer(socket: url, verify: { _ in throw ExternalToolsError("Not ours.") }) { _ in
            Issue.record("The handler ran for a refused peer."); return Data("x".utf8)
        }
        let answer = try await Task.detached { try ExternalConnection.call(Data("hello".utf8), socket: url, seconds: 5, verify: { _ in }) }.value
        let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any]
        #expect(object?["error"] as? String == "Not ours.")
        #expect(object?["version"] as? Int == 1)
        withExtendedLifetime(server) {}
    }

    /// A caller holding every connection open gets in nobody else's way unanswered: the next one is told why.
    @Test func aFullServerSaysItIsBusy() async throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("x-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("x.sock")
        let server = try ExternalConnectionServer(socket: url, limit: 1, verify: { _ in }) { data in
            try? await Task.sleep(for: .seconds(2)); return data
        }
        let slow = Task.detached { try ExternalConnection.call(Data("slow".utf8), socket: url, seconds: 5, verify: { _ in }) }
        try await Task.sleep(for: .milliseconds(300))
        let answer = try await Task.detached { try ExternalConnection.call(Data("next".utf8), socket: url, seconds: 5, verify: { _ in }) }.value
        let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any]
        #expect((object?["error"] as? String)?.contains("busy") == true)
        #expect(String(decoding: try await slow.value, as: UTF8.self) == "slow")
        withExtendedLifetime(server) {}
    }

    @Test func aMissingSocketSaysTheAppIsNotListening() {
        #expect(throws: ExternalToolsError.self) {
            try ExternalConnection.call(Data("x".utf8), socket: URL(fileURLWithPath: "/tmp/none-\(UUID()).sock"), seconds: 1, verify: { _ in })
        }
    }
}
