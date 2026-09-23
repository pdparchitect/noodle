import Foundation
import HubCore
import NoodleCore
import XCTest

/// Drives the Hub's API over loopback, as a paired client would. No harness or network.
final class HubServerTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var server: HubServer!
    private var base: URL!
    private let token = "fixture-token"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-server-\(UUID())")
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        server = HubServer(repository: repository, token: token)
        let port = try await server.start(port: 0)
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ method: String, _ path: String, body: [String: String]? = nil,
                         token: String? = "fixture-token") async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    func testRequestsWithoutTheTokenAreRefused() async throws {
        let (missing, _) = try await request("GET", "/conversations", token: nil)
        XCTAssertEqual(missing, 401)
        let (wrong, _) = try await request("GET", "/conversations", token: "guess")
        XCTAssertEqual(wrong, 401)
    }

    func testListsTheHubsConversations() async throws {
        let created = try repository.createAgent(named: "Alfred")
        let (status, data) = try await request("GET", "/conversations")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try decode([BotConversation].self, data).map(\.id), [created.conversation.id])
    }

    func testSentMessagesAreQueuedForTheBotAndReadBackAfterWhatWasSeen() async throws {
        let conversation = try repository.createAgent(named: "Alfred").conversation
        let path = "/conversations/\(conversation.id.uuidString)/messages"
        let (sent, sentData) = try await request("POST", path, body: ["body": "Order more coffee."])
        XCTAssertEqual(sent, 201)
        let message = try decode(ChatMessage.self, sentData)
        XCTAssertEqual(message.body, "Order more coffee.")
        XCTAssertEqual(message.delivery, .queued)
        XCTAssertEqual(try repository.loadMessages(conversationID: conversation.id).map(\.id), [message.id])

        let (status, data) = try await request("GET", path + "?after=0")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try decode([ChatMessage].self, data).map(\.id), [message.id])
        let (_, seen) = try await request("GET", path + "?after=1")
        XCTAssertEqual(try decode([ChatMessage].self, seen), [])
    }

    func testUnknownConversationsAndRoutesAreNotFound() async throws {
        let (messages, _) = try await request("GET", "/conversations/\(UUID().uuidString)/messages")
        XCTAssertEqual(messages, 404)
        let (send, _) = try await request("POST", "/conversations/\(UUID().uuidString)/messages", body: ["body": "Hi"])
        XCTAssertEqual(send, 404)
        let (route, _) = try await request("GET", "/nowhere")
        XCTAssertEqual(route, 404)
    }

    func testAnEmptyMessageIsRejected() async throws {
        let conversation = try repository.createAgent(named: "Alfred").conversation
        let (status, _) = try await request("POST", "/conversations/\(conversation.id.uuidString)/messages", body: ["body": "  "])
        XCTAssertEqual(status, 400)
        XCTAssertEqual(try repository.loadMessages(conversationID: conversation.id), [])
    }
}
