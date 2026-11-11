import Foundation
import HubCore
import HubLink
import NoodleCore
@testable import NoodleMCP
import NoodleRuntime
import XCTest

/// The Hub's core alone, as a Hub without Noodle Computer, Browser or Applet, calls or file pictures runs:
/// devices pair, keep bots and talk with them, and are refused what this Hub does not keep.
@MainActor final class HubCoreOnlyTests: XCTestCase {
    func testAHubWithoutTheMacsAreasKeepsBotsAndRefusesTheRest() async throws {
        let (runtime, _) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-core-only-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        let access = HubAccess(url: root.appendingPathComponent("access.json"))
        let service = MCPService(credentials: NoCredentials(), oauth: MCPOAuth(), httpConfiguration: { .ephemeral })
        let connections = HubConnections(root: root, access: access, service: service,
                                         tools: ToolProviderRegistry(), assignments: ToolAssignmentStore())
        let bots = HubBots(repository: repository, runtime: runtime, access: access, connections: connections,
                           computers: nil, browsers: nil, applets: nil,
                           uploads: root.appendingPathComponent("Uploads", isDirectory: true),
                           readMarks: root.appendingPathComponent("read.json"), pins: nil, notifications: nil)
        let link = HubLinkService(hubName: "Server", directory: root.appendingPathComponent("Link", isDirectory: true),
                                  access: access, profiles: HarnessProfilesController(store: repository.harnessProfiles),
                                  bots: bots, connections: connections, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let plan = try access.addPlan(named: "Family")
        access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: plan)
        let ada = try access.addUser(named: "Ada")
        access.move(ada, to: plan)
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(device.error)

        guard case .bot(let bot) = try await device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        _ = try await device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hi")))
        guard case .messages(let page) = try await device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.last?.body, "Hi")

        let refused: [(LinkRequest, String)] = [
            (.computers, "This Noodle Hub does not keep computers."),
            (.browsers, "This Noodle Hub does not keep browsers."),
            (.noodletArchive(grant: UUID(), offset: 0), "This Noodle Hub does not run noodlets."),
        ]
        for (request, refusal) in refused {
            do {
                _ = try await device.request(request)
                XCTFail("\(request) was answered")
            } catch {
                XCTAssertEqual(error.localizedDescription, refusal, "\(request)")
            }
        }
    }
}
