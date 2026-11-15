import NoodleCore
import NoodleRuntime
import XCTest

/// What Pion's agents use is kept, as Noodle keeps it, for the Usage window and a resumed session's totals.
@MainActor final class UsageTests: XCTestCase {
    func testWhatAgentsUseIsRecordedAndKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionUsage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        let agent = UUID(), now = Date()
        let sample = UsageSample(date: now, agentID: agent, agentName: "Lunar Fox", harness: "codex", model: "gpt-5",
                                 tokens: UsageTokens(input: 120, output: 30), costUSD: 0.01, session: "s1")
        try XCTUnwrap(model.runtime.onUsage)(sample)
        let days = model.usage.days(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400), agentID: agent)
        XCTAssertEqual(days.map(\.tokens.input).reduce(0, +), 120)
        XCTAssertNotNil(model.runtime.recordedUsage?("s1"))
        let reopened = PionModel(root: root, messenger: nil, isScripted: true)
        XCTAssertEqual(reopened.usage.days(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400), agentID: agent).count, 1)
    }
}
