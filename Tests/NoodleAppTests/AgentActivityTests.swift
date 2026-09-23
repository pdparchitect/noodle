import AppKit
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class AgentActivityTests: XCTestCase {
    func testAppleStatusesAndToolResultsReachWindowLog() {
        let log = AgentActivityLog()
        func feed(_ update: [String: Any]) {
            let message: [String: Any] = ["method": "session/update", "params": ["sessionId": "apple", "update": update]]
            AgentActivityParser.events(message, provider: .apple).forEach { log.record($0) }
        }
        feed(["sessionUpdate": "noodle_activity", "title": "Loaded AGENTS.md and skill catalogue"])
        feed(["sessionUpdate": "tool_call", "toolCallId": "call", "title": "Bash", "status": "in_progress", "rawInput": ["command": "cat missing.txt"]])
        feed(["sessionUpdate": "tool_call_update", "toolCallId": "call", "title": "Bash", "status": "failed",
              "content": [["type": "content", "content": ["type": "text", "text": "Duration: 0.10s\nExit status: 1\nFile not found"]]]])
        feed(["sessionUpdate": "noodle_activity", "title": "Retrying an empty model reply (1/2)"])
        XCTAssertEqual(log.entries.count, 4)
        XCTAssertTrue(log.text.contains("Bash: started"))
        XCTAssertTrue(log.text.contains("cat missing.txt"))
        XCTAssertTrue(log.text.contains("Bash: failed"))
        XCTAssertTrue(log.text.contains("File not found"))
        XCTAssertTrue(log.text.contains("Duration: 0.10s"))
        XCTAssertFalse(log.text.contains("Reasoning summary"))
        let status: [String: Any] = ["method": "session/update", "params": ["update": ["sessionUpdate": "noodle_activity", "title": "Apple only"]]]
        XCTAssertTrue(AgentActivityParser.events(status, provider: .fx).isEmpty)
        let hiddenRoots = "skill discovery warning: inventory incomplete because root \"/Users/me/.claude/skills\" could not be read, so an unknown number of skills may be missing; fix access to the root and reload skills"
        let notice: [String: Any] = ["method": "session/update", "params": ["update": ["sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": hiddenRoots]]]]
        XCTAssertTrue(AgentActivityParser.events(notice, provider: .fx).isEmpty)
        XCTAssertEqual(AgentActivityParser.events(notice, provider: .grokBuild).first?.detail, hiddenRoots)
    }

    func testStreamCoalescingCompletionAndLifecycleBoundaries() {
        let log = AgentActivityLog()
        let id = UUID()
        log.record(.init(agentID: id, phase: .working, detail: "Working"))
        log.record(.init(title: "Output", detail: "Hello ", streamID: "text", appending: true))
        log.record(.init(title: "Output", detail: "world", streamID: "text", appending: true))
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.last?.detail, "Hello world")
        log.record(.init(title: "Output", detail: "Hello world!", streamID: "text"))
        XCTAssertEqual(log.entries.count, 2)
        log.record(.init(agentID: id, phase: .ready, detail: "Ready"))
        let revision = log.revision
        log.record(.init(agentID: id, phase: .ready, detail: "Ready"))
        XCTAssertEqual(log.revision, revision)
        log.record(.init(title: "Output", detail: "Next turn", streamID: "text", appending: true))
        XCTAssertEqual(log.entries.last?.detail, "Next turn")
        XCTAssertTrue(log.text.contains("Hello world!"))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.byteCount, 0)
        XCTAssertEqual(log.status, "Ready")
    }

    func testLogBoundsEntriesAndBytesIncludingMultibyteOutput() {
        let log = AgentActivityLog(entryLimit: 3, byteLimit: 4096)
        for index in 0..<10 { log.record(.init(title: "Event \(index)")) }
        XCTAssertEqual(log.entries.map(\.title), ["Event 7", "Event 8", "Event 9"])
        for _ in 0..<50 {
            log.record(.init(title: "Output", detail: String(repeating: "🙂", count: 5000), streamID: "output", appending: true))
        }
        XCTAssertLessThanOrEqual(log.byteCount, 4096)
        XCTAssertEqual(log.byteCount, log.entries.reduce(0) { $0 + $1.byteCount })
        XCTAssertFalse(log.entries.isEmpty)
    }

    func testAgentBuffersAreIsolatedAndDeletedAgentsAreForgotten() {
        let store = AgentActivityStore(), first = UUID(), second = UUID()
        store.log(for: first).record(.init(title: "First"))
        store.log(for: second).record(.init(title: "Second"))
        XCTAssertFalse(store.log(for: first).text.contains("Second"))
        store.retainAgents([second])
        XCTAssertTrue(store.log(for: first).entries.isEmpty)
        XCTAssertTrue(store.log(for: second).text.contains("Second"))
    }

    func testCodexCommandOutputAndFinalTextShareTheirStreamingRows() {
        let log = AgentActivityLog()
        func feed(_ method: String, _ params: [String: Any]) {
            for event in AgentActivityParser.events(["method": method, "params": params], provider: .codex) { log.record(event) }
        }
        feed("item/started", ["turnId": "t", "item": ["id": "c", "type": "commandExecution", "command": "swift test"]])
        feed("item/commandExecution/outputDelta", ["turnId": "t", "itemId": "c", "delta": "Passed"])
        feed("item/completed", ["turnId": "t", "item": ["id": "c", "type": "commandExecution", "command": "swift test", "exitCode": 0, "aggregatedOutput": "Passed\n"]])
        feed("item/agentMessage/delta", ["turnId": "t", "itemId": "a", "delta": "All good"])
        feed("item/completed", ["turnId": "t", "item": ["id": "a", "type": "agentMessage", "text": "All good."]])
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries[0].title, "Command completed (exit 0)")
        XCTAssertEqual(log.entries[1].detail, "Passed\n")
        XCTAssertEqual(log.entries[2].detail, "All good.")
    }

    func testACPToolUpdatesAndAppleWorkingAreReadable() {
        let message: [String: Any] = ["method": "session/update", "params": ["sessionId": "s", "update": [
            "sessionUpdate": "tool_call", "toolCallId": "c", "title": "Read", "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": "file contents"]]]]]]
        for provider in [HarnessProvider.fx, .grokBuild] {
            let events = AgentActivityParser.events(message, provider: provider)
            XCTAssertEqual(events.first?.title, "Read: completed")
            XCTAssertEqual(events.first?.detail, "file contents")
        }
        let working: [String: Any] = ["method": "session/update", "params": ["update": [
            "sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Working"]]]]
        let log = AgentActivityLog()
        for _ in 0..<4 { AgentActivityParser.events(working, provider: .apple).forEach { log.record($0) } }
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].title, "Working")
    }

    func testMuseStableSchemaDeltasAndFinalSnapshots() {
        let log = AgentActivityLog()
        func feed(_ method: String, _ fields: [String: Any]) {
            var params = fields
            params["sessionId"] = "s"
            params["viewCursor"] = "cursor"
            AgentActivityParser.events(["method": method, "params": params], provider: .muse).forEach { log.record($0) }
        }
        feed("item/started", ["item": ["itemId": "tool", "kind": "toolCall", "status": "inProgress", "revision": 1, "tool": "bash", "args": "{\"command\":\"pwd\"}"]])
        feed("item/delta", ["itemId": "tool", "field": "output", "delta": "/workspace"])
        feed("item/completed", ["item": ["itemId": "tool", "kind": "toolCall", "status": "failed", "revision": 2,
                                            "tool": "bash", "args": "{\"command\":\"pwd\"}", "visibleOutput": "/workspace\n", "failureReason": "Timed out"]])
        feed("item/delta", ["itemId": "reply", "delta": "Done"])
        feed("item/completed", ["item": ["itemId": "reply", "kind": "agentMessage", "status": "completed", "revision": 2, "text": "Done."]])
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries[0].title, "bash: failed")
        XCTAssertTrue(log.entries[0].detail.contains("Timed out"))
        XCTAssertEqual(log.entries[1].detail, "/workspace\n")
        XCTAssertEqual(log.entries[2].detail, "Done.")
        feed("item/completed", ["item": ["itemId": "future", "kind": "newKind", "status": "completed", "revision": 1, "fallbackText": "New action"]])
        XCTAssertEqual(log.entries.last?.detail, "New action")
        feed("view/gap", [:])
        XCTAssertEqual(log.entries.last?.title, "Some activity was not delivered by Muse")
    }

    func testClaudeToolsAndResultsExcludePrivateOrNonTextBlocks() {
        let assistant: [String: Any] = ["type": "assistant", "message": ["content": [
            ["type": "thinking", "thinking": "private reasoning", "signature": "opaque"],
            ["type": "text", "text": "Checking"],
            ["type": "tool_use", "name": "Bash", "input": ["command": "pwd"]]]]]
        let events = AgentActivityParser.events(assistant, provider: .claudeCode)
        XCTAssertEqual(events.map(\.title), ["Output", "Bash: started"])
        XCTAssertTrue(events.last?.detail.contains("pwd") == true)
        let result: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result", "is_error": true,
            "content": [["type": "text", "text": "failed"], ["type": "image", "data": "image bytes"]]]]]]
        let output = AgentActivityParser.events(result, provider: .claudeCode)
        XCTAssertEqual(output.first?.title, "Tool failed")
        XCTAssertEqual(output.first?.detail, "failed")
        for provider in HarnessProvider.allCases {
            XCTAssertTrue(AgentActivityParser.events(["id": 1, "result": ["apiKey": "secret"]], provider: provider).isEmpty)
            XCTAssertTrue(AgentActivityParser.events(["method": "auth/updated", "params": ["token": "secret"]], provider: provider).isEmpty)
        }
    }

    func testCoordinatorDropsOldRuntimeActivityAfterRestart() throws {
        let f = try RuntimeCoordinatorFixture()
        defer { f.cleanUp() }
        let agent = try f.agent(), first = try f.start(agent)
        let event: [String: Any] = ["method": "item/agentMessage/delta", "params": ["itemId": "a", "delta": "current"]]
        first.launch.onActivity(event)
        let log = f.runtime.activity.log(for: agent.id)
        XCTAssertTrue(log.text.contains("current"))
        f.runtime.restart(agent: agent, repository: f.repository)
        let revision = log.revision
        first.launch.onActivity(event)
        XCTAssertEqual(log.revision, revision)
        f.factory.processes.last?.launch.onActivity(event)
        XCTAssertGreaterThan(log.revision, revision)
    }

    func testNativeWindowReuseCloseReopenAndDeletion() async throws {
        _ = NSApplication.shared
        let registry = AgentActivityWindows(), log = AgentActivityLog()
        var agent = AgentRecord(displayName: "Activity fixture")
        log.record(.init(agentID: agent.id, phase: .working, detail: "Working"))
        log.record(.init(title: "Reading files"))
        log.record(.init(title: "Running command", detail: "swift test --filter AgentActivity"))
        log.record(.init(title: "Tool output", detail: "Executed 14 tests, with 0 failures."))
        let first = registry.show(agent: agent, log: log)
        let panel = try XCTUnwrap(first.window)
        let originalFrame = panel.frame
        panel.zoom(nil)
        panel.miniaturize(nil)
        panel.toggleFullScreen(nil)
        XCTAssertEqual(panel.frame, originalFrame)
        XCTAssertFalse(panel.isMiniaturized)
        XCTAssertFalse(panel.styleMask.contains(.fullScreen))
        XCTAssertTrue(registry.show(agent: agent, log: log) === first)
        XCTAssertEqual(registry.controllers.count, 1)
        XCTAssertTrue(first.output.textView.string.contains("Reading files"))
        if let path = ProcessInfo.processInfo.environment["NOODLE_ACTIVITY_PREVIEW_PATH"], let content = first.window?.contentView {
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        agent.displayName = "Renamed"
        registry.synchronize(agents: [agent])
        XCTAssertEqual(first.window?.title, "Renamed - Activity")
        let preview = try XCTUnwrap(panel.contentView as? AnnotationPreviewFrame)
        XCTAssertEqual(preview.filename, "Renamed - Activity")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let close = try XCTUnwrap(descendants(preview).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Close Activity"
        })
        close.performClick(nil)
        XCTAssertTrue(registry.controllers.isEmpty)
        let second = registry.show(agent: agent, log: log)
        XCTAssertFalse(first === second)
        XCTAssertTrue(second.output.textView.string.contains("Reading files"))
        registry.synchronize(agents: [])
        XCTAssertTrue(registry.controllers.isEmpty)
    }

    func testNativeLogKeepsSelectionAndScrollPositionWhileAppendingAndEvicting() throws {
        _ = NSApplication.shared
        let log = AgentActivityLog(entryLimit: 80)
        for index in 0..<80 { log.record(.init(title: "Line \(index)", detail: "A short line of output")) }
        let controller = AgentActivityWindowController(log: log)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.refresh()
        let output = controller.output
        let text = output.textView.string as NSString
        let range = text.range(of: "Line 40")
        output.textView.setSelectedRange(range)
        output.textView.scrollRangeToVisible(range)
        XCTAssertFalse(output.isAtBottom)
        log.record(.init(title: "Line 80"))
        controller.refresh()
        let selected = (output.textView.string as NSString).substring(with: output.textView.selectedRange())
        XCTAssertEqual(selected, "Line 40")
        XCTAssertFalse(output.isAtBottom)
        let menu = try XCTUnwrap(output.textView.activityMenu?())
        let follow = try XCTUnwrap(menu.item(withTitle: "Follow Latest"))
        XCTAssertTrue(follow.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(follow.action), to: follow.target, from: follow))
        XCTAssertEqual(output.textView.selectedRange().length, 0)
        XCTAssertTrue(output.isAtBottom)
        output.textView.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertFalse(output.isFollowing)
        output.follow()
        XCTAssertTrue(output.isFollowing)
        log.record(.init(title: "Line 81"))
        controller.refresh()
        XCTAssertTrue(output.isAtBottom)
        let clear = try XCTUnwrap(controller.makeContextMenu().item(withTitle: "Clear"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(output.textView.string.isEmpty)
    }
}
