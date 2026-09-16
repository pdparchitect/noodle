import XCTest
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleActivityEventTests: XCTestCase {
    func testStartIsDeliveredBeforeOperationAndResultBeforeReturn() async throws {
        let events = ActivityEvents()
        let text = try await AppleToolActivity.perform(name: "Read file", input: ["path": ".agents/skills/computer/SKILL.md"],
            onEvent: { await events.append($0) }) {
                let started = await events.values
                XCTAssertEqual(started.count, 1, "Tool start must already be visible while the operation runs")
                return AppleToolResult(text: "skill contents")
            }
        XCTAssertEqual(text, "skill contents")
        let values = await events.values
        XCTAssertEqual(values.count, 2)
        guard case .toolStarted(let startID, _, _) = values[0],
              case .toolFinished(let endID, _, _, let output, let failed, let seconds) = values[1] else {
            return XCTFail("Expected a paired start and finish")
        }
        XCTAssertEqual(startID, endID)
        XCTAssertEqual(output, text)
        XCTAssertFalse(failed)
        XCTAssertGreaterThanOrEqual(seconds, 0)
    }

    func testFileErrorIsVisibleToBothActivityAndModel() async throws {
        let events = ActivityEvents()
        let text = try await AppleToolActivity.perform(name: "Read file", input: ["path": "missing.txt"],
            onEvent: { await events.append($0) }) { throw HarnessSetupError("File not found") }
        XCTAssertEqual(text, "Tool failed: File not found")
        let values = await events.values
        guard case .toolFinished(_, _, _, let output, let failed, _) = values.last else { return XCTFail("Missing failure") }
        XCTAssertTrue(failed)
        XCTAssertEqual(output, text)
    }

    func testCancellationAndToolLimitRemainTerminalAndCloseActivity() async throws {
        for error in [CancellationError() as Error, AppleToolLimit()] {
            let events = ActivityEvents()
            do {
                _ = try await AppleToolActivity.perform(name: "Bash", input: [:], onEvent: { await events.append($0) }) { throw error }
                XCTFail("Must preserve terminal errors")
            } catch is CancellationError { XCTAssertTrue(error is CancellationError) }
            catch is AppleToolLimit { XCTAssertTrue(error is AppleToolLimit) }
            let values = await events.values
            XCTAssertEqual(values.count, 2)
            guard case .toolFinished(_, _, _, let text, let failed, _) = values.last else { return XCTFail("Missing end event") }
            XCTAssertTrue(failed)
            if error is CancellationError { XCTAssertEqual(text, "Cancelled.") }
        }
    }

    func testCommandExitStatusIsReportedAsFailureWithoutChangingResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-activity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: "Activity test")
        let context = try AppleToolContext(workspace: repository.directory(for: bot.agent))
        let events = ActivityEvents()
        let command = "printf observed-output; exit 7"
        let text = try await AppleToolActivity.perform(name: "Bash", input: ["command": command], onEvent: { await events.append($0) }) {
            try await context.executeResult(command: command)
        }
        XCTAssertTrue(text.hasPrefix("Exit status: 7\n"))
        XCTAssertTrue(text.contains("observed-output"))
        let values = await events.values
        guard case .toolFinished(_, _, let input, let output, let failed, _) = values.last else { return XCTFail("Missing result") }
        XCTAssertTrue(failed)
        XCTAssertEqual(input["command"], command)
        XCTAssertEqual(output, text)
    }

    func testWireMessagesAreBoundedAndCarrySessionAndExecutionIDs() throws {
        let event = AppleActivityEvent.toolFinished(id: "execution", name: "Bash", input: ["command": "pwd"],
            output: String(repeating: "x", count: 100_000), failed: false, seconds: 1.5)
        let message = event.message(sessionID: "session")
        let data = try JSONSerialization.data(withJSONObject: message)
        XCTAssertLessThan(data.count, 14_000)
        let params = try XCTUnwrap(message["params"] as? [String: Any])
        XCTAssertEqual(params["sessionId"] as? String, "session")
        let update = try XCTUnwrap(params["update"] as? [String: Any])
        XCTAssertEqual(update["sessionUpdate"] as? String, "tool_call_update")
        XCTAssertEqual(update["toolCallId"] as? String, "execution")
        XCTAssertEqual(update["status"] as? String, "completed")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Duration: 1.50s"))
        XCTAssertTrue(text.contains("Activity preview truncated"))
    }
}

actor ActivityEvents {
    var values: [AppleActivityEvent] = []
    func append(_ event: AppleActivityEvent) { values.append(event) }
}
