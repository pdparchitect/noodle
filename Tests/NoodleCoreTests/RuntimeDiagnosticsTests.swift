import XCTest
@testable import NoodleCore

final class RuntimeDiagnosticsTests: XCTestCase {
    func testCLILoggingPreservesInboxAndOutputContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Private Bot")
        let workspace = repository.directory(for: bot.agent)
        try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .user,
            body: "Private message", delivery: .delivered))
        var trace = RuntimeTrace(agentID: bot.agent.id, provider: .codex, workspace: workspace)
        trace.begin(reason: .inboxChanged)
        let context = RuntimeDiagnostics.readContext(in: workspace, agentID: bot.agent.id)
        let args = ["messenger", "--agent-directory", workspace.path, "--get-latest"]
        let peek = MessengerCLI.run(arguments: args + ["--peek"], environment: [:])
        let read = MessengerCLI.run(arguments: args, environment: [:])
        XCTAssertEqual(peek.exitCode, 0)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(peek.standardOutput, read.standardOutput)
        XCTAssertEqual(read.standardError, "")
        let deliveries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.standardOutput.utf8)) as? [[String: Any]])
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual((deliveries.first?["message"] as? [String: Any])?["body"] as? String, "Private message")
        let second = MessengerCLI.run(arguments: args, environment: [:])
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.standardOutput.utf8)) as? [Any])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(context, RuntimeDiagnostics.readContext(in: workspace, agentID: bot.agent.id))
        trace.finish(.turnCompleted)
    }

    func testWakeCorrelationLifecycleAndPrivacy() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bot = UUID()
        var trace = RuntimeTrace(agentID: bot, provider: .codex, workspace: workspace)
        trace.begin(reason: .heartbeat)
        let first = try XCTUnwrap(RuntimeDiagnostics.readContext(in: workspace, agentID: bot))
        XCTAssertEqual(first.reason, "heartbeat")
        XCTAssertEqual(first.provider, .codex)
        let data = try Data(contentsOf: RuntimeDiagnostics.contextURL(in: workspace))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["agentID", "wakeID", "provider", "reason"])
        RuntimeDiagnostics.inboxRead(agentID: bot, workspace: workspace, count: 0, consuming: true)
        XCTAssertEqual(RuntimeDiagnostics.readContext(in: workspace, agentID: bot), first)
        trace.finish(.turnCompleted)
        XCTAssertNil(RuntimeDiagnostics.readContext(in: workspace, agentID: bot))
        trace.begin(reason: .inboxChanged)
        let next = try XCTUnwrap(RuntimeDiagnostics.readContext(in: workspace, agentID: bot))
        XCTAssertNotEqual(first.wakeID, next.wakeID)
        trace.finish(.turnFailed)
        XCTAssertNil(RuntimeDiagnostics.readContext(in: workspace, agentID: bot))
    }

    func testOldRuntimeCannotClearNewWakeAndStartupClearsStaleMarker() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bot = UUID()
        var old = RuntimeTrace(agentID: bot, provider: .claudeCode, workspace: workspace)
        var new = RuntimeTrace(agentID: bot, provider: .claudeCode, workspace: workspace)
        old.begin(reason: .heartbeat)
        new.begin(reason: .runtimeRecovered)
        let current = RuntimeDiagnostics.readContext(in: workspace, agentID: bot)
        old.finish(.runtimeDisconnected)
        XCTAssertEqual(RuntimeDiagnostics.readContext(in: workspace, agentID: bot), current)
        new.runtimeStarting()
        XCTAssertNil(RuntimeDiagnostics.readContext(in: workspace, agentID: bot))
    }

    func testDiagnosticsAreBestEffortAndDoNotFollowRedirectedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent(".noodle"), withDestinationURL: outside)
        let bot = UUID()
        var trace = RuntimeTrace(agentID: bot, provider: .codex, workspace: workspace)
        trace.begin(reason: .heartbeat)
        trace.record(.wakeSubmitted)
        RuntimeDiagnostics.inboxRead(agentID: bot, workspace: workspace, count: nil, consuming: true)
        trace.finish(.runtimeFailed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertNil(RuntimeDiagnostics.readContext(in: workspace, agentID: bot))
    }
}
