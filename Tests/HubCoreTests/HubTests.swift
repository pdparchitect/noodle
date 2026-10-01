import CloudKit
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

@MainActor final class HubTests: XCTestCase {
    /// The Agent Host finds bots under Application Support/Noodle in the Hub's container.
    func testHubStoresDataWhereItsAgentHostLooks() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        XCTAssertEqual(Hub.root(applicationSupport: applicationSupport),
                       applicationSupport.appendingPathComponent("Noodle", isDirectory: true))
    }


    func testHubStoresBotsUnderItsRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        try hub.repository.prepare()
        let created = try hub.repository.createAgent(named: "Alfred")
        XCTAssertTrue(hub.repository.directory(for: created.agent).path.hasPrefix(root.path))
    }

    /// The owner Noodle Applet reads from a bot's agent.json, or nil when it names none.
    private func owner(in hub: Hub, of agent: AgentRecord) throws -> [String: String]? {
        let file = hub.repository.agentsURL.appendingPathComponent("\(agent.id.uuidString.lowercased())/agent.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        return json?["owner"] as? [String: String]
    }

    /// Noodle Applet lists the Hub's noodlets under the people whose bots made them, so each bot's
    /// agent.json names its owner and follows a rename.
    func testABotsFileNamesItsOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        try hub.repository.prepare()
        let ada = try hub.access.addUser(named: "Ada")
        let agent = try hub.repository.createAgent(named: "Alfred").agent
        XCTAssertNil(try owner(in: hub, of: agent))
        hub.access.setOwner(ada, ofBot: agent.id)
        XCTAssertEqual(try owner(in: hub, of: agent), ["id": ada.id.uuidString, "name": "Ada"])
        try hub.access.rename(ada, to: "Ada Lovelace")
        XCTAssertEqual(try owner(in: hub, of: agent), ["id": ada.id.uuidString, "name": "Ada Lovelace"])
        hub.access.setOwner(nil, ofBot: agent.id)
        XCTAssertNil(try owner(in: hub, of: agent))
    }

    /// Only an app signed with the iCloud container talks to CloudKit; tests and development builds never do.
    func testPushesNeedTheICloudEntitlement() {
        XCTAssertNil(CloudKitPushes.ifEntitled())
    }

    /// One record per device and conversation, found again by its name alone, carrying only the topic and the count.
    func testAPushIsOneRecordPerTopicAndConversation() {
        let conversation = UUID()
        let record = CloudKitPushes.record(topic: "phone", conversation: conversation, unread: 3)
        XCTAssertEqual(record.recordType, LinkPush.recordType)
        XCTAssertEqual(record[LinkPush.topicField] as? String, "phone")
        XCTAssertEqual(record[LinkPush.conversationField] as? String, conversation.uuidString)
        XCTAssertEqual(record[LinkPush.unreadField] as? Int64, 3)
        XCTAssertEqual(Set(record.allKeys()), [LinkPush.topicField, LinkPush.conversationField, LinkPush.unreadField])
        XCTAssertEqual(CloudKitPushes.recordID(topic: "phone", conversation: conversation), record.recordID)
        XCTAssertNotEqual(CloudKitPushes.recordID(topic: "tablet", conversation: conversation), record.recordID)
        XCTAssertNotEqual(CloudKitPushes.recordID(topic: "phone", conversation: UUID()), record.recordID)
        // The name does not give the topic away to anyone reading the public database.
        XCTAssertFalse(record.recordID.recordName.contains("phone"))
    }

    func testHubKeepsUsageReportedByTheRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        try hub.repository.prepare()
        let sample = UsageSample(date: Date(), agentID: UUID(), agentName: "Alfred", harness: "codex",
            model: "gpt-5.5", tokens: UsageTokens(input: 3, output: 4), costUSD: nil)
        hub.runtime.onUsage?(sample)
        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(hub.usage.days(from: today, to: today.addingTimeInterval(86_400), agentID: nil).map(\.tokens.total), [7])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("usage.sqlite").path))
    }
}
