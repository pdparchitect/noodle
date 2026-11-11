import Foundation
import HubCore
import HubLink
@testable import ServerCore
import XCTest

/// The server's Hub as a device sees it: someone named in the file pairs, keeps a bot and talks to it,
/// and is refused what the server does not keep, over the link it really uses: msquic on Linux, and on
/// a Mac the listener Noodle Hub uses.
@MainActor final class ServerHubTests: XCTestCase {
    func testSomeoneInTheFilePairsKeepsABotAndIsRefusedTheRest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var configuration = try ServerConfiguration(yaml: """
        name: Test Server
        data: \(root.appendingPathComponent("Data").path)
        harnesses:
          claude-code: /bin/sh
        plans:
          Family:
            harnesses: [claude-code]
        users:
          Ada:
            plan: Family
        """)
        configuration.port = 0
        #if os(Linux)
        let listen = QUICListener.listen(certificates: root.appendingPathComponent("Certificates"))
        #else
        let listen = LinkServer.listen
        #endif
        let hub = try ServerHub(configuration: configuration, listen: listen)
        await hub.start()
        addTeardownBlock { await MainActor.run { hub.stop() } }
        guard case .listening = hub.link.state else { throw XCTSkip("Could not listen: \(hub.link.state)") }

        let ada = try XCTUnwrap(hub.access.users.first { $0.name == "Ada" })
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(hub.link.invite(ada).url().absoluteString)
        XCTAssertNil(device.error)

        guard case .bot(let bot) = try await device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        _ = try await device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hi")))
        guard case .messages(let page) = try await device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.last?.body, "Hi")

        do {
            _ = try await device.request(.computers)
            XCTFail("computers were answered")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This Noodle Hub does not keep computers.")
        }
    }
}
