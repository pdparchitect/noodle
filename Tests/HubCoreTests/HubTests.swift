import Foundation
import HubCore
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
