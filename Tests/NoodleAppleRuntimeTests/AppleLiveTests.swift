import XCTest
import NoodleCore
import FoundationModels
@testable import NoodleAppleRuntime

/// Explicit opt-in: a real on-device model and a synthetic disposable bot. Never
/// opens the user's Noodle storage, accounts, or external model services.
final class AppleLiveTests: XCTestCase {
    func testSandboxedCompletedReplyDoesNotRepeatItsCommand() throws {
        try exercise(tasks: [["Use execute_command to run: printf repeated > should-not-run.txt"]],
                     completedReply: "The operation finished before the interruption.") { workspace, replies in
            XCTAssertEqual(replies[0].body, "The operation finished before the interruption.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("should-not-run.txt").path))
        }
    }

    func testSandboxedAgentReadsWritesExecutesAndReplies() throws {
        try exercise(tasks: [
            ["Use write_file to create result.txt with this content:\na small apple"],
            ["Use read_file to read seed.txt, then send me its text in your reply."],
            ["Use execute_command to run this shell command:\n```sh\nprintf ready > command.txt\n```"]
        ]) { workspace, replies in
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("result.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "a small apple")
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("command.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "ready")
            XCTAssertTrue(replies.dropFirst().first?.body.contains("a crisp pear") == true)
        }
    }

    func testSandboxedConversationAnswersAndRemembersAcrossWakes() throws {
        let remember = "Remember the secret word avocado"
        let followup = "What did I ask you to remember?"
        try exercise(tasks: [["Hi there", remember], ["What is the secret word?"], [followup]]) { _, replies in
            for reply in replies {
                XCTAssertFalse(reply.body.lowercased().contains("file"), "Invented a file task for chat: \(reply.body)")
                XCTAssertFalse(reply.body.contains("[bytes ") || reply.body.contains("User:"), "Dumped history instead of answering: \(reply.body)")
            }
            XCTAssertNotEqual(replies.first?.body, remember)
            XCTAssertTrue(replies[1].body.lowercased().contains("avocado"), "Reply lost prior chat: \(replies[1].body)")
            XCTAssertNotEqual(replies[2].body, followup)
            XCTAssertTrue(replies[2].body.lowercased().contains("avocado"), "Follow-up lost prior chat: \(replies[2].body)")
        }
    }

    func testSandboxedConversationCorrectsAnEarlierWrongAnswer() throws {
        let correction = "No, it is not. I told you what the secret word is..."
        // Reproduce the existing conversation in the screenshot, including the
        // old harness's echo and incorrect answer, before running the fixed one.
        try exercise(history: [
            (false, "Hi there"), (true, "Hi there!"),
            (false, "Remember the secret word avocado"), (true, "Remember the secret word avocado"),
            (false, "What is the secret word?"), (true, "The secret word is password.")
        ], tasks: [[correction]]) { _, replies in
            XCTAssertFalse(replies[0].body.lowercased().contains("file"), "Invented file persistence: \(replies[0].body)")
            XCTAssertNotEqual(replies[0].body, correction)
            XCTAssertTrue(replies[0].body.lowercased().contains("avocado"), "Correction ignored user history: \(replies[0].body)")
            // Merely mentioning the correct word must not pass when the model
            // asserts the opposite (for example, "password, not avocado").
            let answer = replies[0].body.lowercased().filter { $0.isLetter || $0.isWhitespace }
            XCTAssertFalse(answer.contains("not avocado"), "Correction denied the user's word: \(replies[0].body)")
            XCTAssertFalse(answer.contains("word is password") || answer.contains("word is indeed password"),
                           "Correction repeated the wrong answer: \(replies[0].body)")
        }
    }

    func testSandboxedConversationEscapesGreetingLoopAndUpdatesMemory() throws {
        try exercise(history: [
            (false, "Hi there"), (false, "Remember the secret word avocado"),
            (true, "Hi there!"), (true, "Remember the secret word avocado"),
            (false, "What is the secret word?"), (true, "The secret word is password."),
            (false, "Hello"), (true, "Hello!"),
            (false, "Remember the secret word tutifruti"), (true, "Hello!")
        ], tasks: [["Remember the secret word avocado"], ["What is the secret word?"],
                   ["Change the word to marigold"], ["What is the word now?"]]) { workspace, replies in
            for reply in replies {
                XCTAssertFalse(reply.body.lowercased().contains("file"), "Invented file persistence: \(reply.body)")
            }
            XCTAssertNotEqual(replies[0].body, "Hello!")
            XCTAssertTrue(replies[1].body.lowercased().contains("avocado"), "Lost remembered word: \(replies[1].body)")
            XCTAssertTrue(replies[3].body.lowercased().contains("marigold"), "Ignored the update: \(replies[3].body)")
            XCTAssertFalse(replies[3].body.lowercased().contains("avocado"), "Repeated the old word: \(replies[3].body)")
            let sessions = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent(".noodle/apple/conversations").path)
            XCTAssertEqual(sessions.count, 1)
        }
    }

    func testSandboxedRecallAfterRepeatedCorrectionsAndGreetings() throws {
        try exercise(named: "Carmen", history: [
            (false, "Hi there"), (false, "Remember the secret word avocado"),
            (true, "Hi there!"), (true, "Remember the secret word avocado"),
            (false, "What is the secret word?"), (true, "The secret word is \"password\"."),
            (false, "No it is not. I told you what the secret word is …"),
            (true, "No, it is not. I told you what the secret word is..."),
            (false, "Hello"), (true, "Hello!"),
            (false, "Remember the secret word tutifruti"), (true, "Hello!"),
            (false, "Remember the secret word avocado"), (true, "Hello!"),
            (false, "Hello"), (true, "Hello there! How can I assist you today?")
        ], tasks: [["Do you know what is the secret word?"]]) { _, replies in
            let answer = replies[0].body.lowercased()
            XCTAssertTrue(answer.contains("avocado"), "Lost the latest user-provided word: \(answer)")
            XCTAssertFalse(answer.contains("password") || answer.contains("tutifruti"), "Repeated an obsolete answer: \(answer)")
        }
    }

    private func exercise(named name: String = "Apple test", history: [(Bool, String)] = [], tasks: [[String]], completedReply: String? = nil,
                          verify: (URL, [ChatMessage]) throws -> Void) throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_APPLE_MODEL"] == "1" else {
            throw XCTSkip("Set NOODLE_TEST_APPLE_MODEL=1 for the real on-device model test.")
        }
        if let reason = AppleModel.inspection(version: "test").unavailableReason { throw XCTSkip(reason) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-live-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: name, harnessIdentifier: "apple")
        for (isAssistant, body) in history {
            if isAssistant { _ = try repository.sendAgentMessage(agentID: bot.agent.id, conversationID: bot.conversation.id, body: body) }
            else { _ = try repository.sendUserMessage(conversationID: bot.conversation.id, body: body) }
        }
        _ = try repository.latestMessages(for: bot.agent.id, consuming: true)
        let existingMessageIDs = Set(try repository.loadMessages(conversationID: bot.conversation.id).map(\.id))
        let workspace = repository.directory(for: bot.agent)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/tmp"), withIntermediateDirectories: true)
        try Data("a crisp pear".utf8).write(to: workspace.appendingPathComponent("seed.txt"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = ProcessInfo.processInfo.environment["NOODLE_APPLE_TEST_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? project.appendingPathComponent(".build/debug/NoodleAppleAgent")
        let application = helper.deletingLastPathComponent().lastPathComponent == "Helpers"
            ? helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : helper.deletingLastPathComponent()
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe(), responses = Responses()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", AppleAgentSandbox.profile(application: application, workspace: workspace, repository: root), helper.path, "--serve"]
        child.currentDirectoryURL = workspace
        child.environment = ["HOME": workspace.path, "PATH": "/usr/bin:/bin", "TMPDIR": workspace.appendingPathComponent(".noodle/tmp").path]
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        let reader = JSONLineReader { responses.receive($0) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil } else { reader.receive(bytes) }
        }
        try child.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            input.fileHandleForWriting.closeFile()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([10]))
            guard let response = responses.wait(id, timeout: method == "session/prompt" ? 180 : 20) else {
                throw HarnessSetupError("No response to \(method).")
            }
            if let error = response["error"] {
                let trace = (try? String(contentsOf: workspace.appendingPathComponent(".noodle/apple/last-transcript.json"), encoding: .utf8)) ?? "No transcript"
                throw HarnessSetupError("\(error)\nSynthetic transcript: \(String(trace.suffix(10_000)))")
            }
            return try XCTUnwrap(response["result"] as? [String: Any])
        }
        _ = try request(1, "initialize", FxProtocol.initializeParameters)
        let session = try XCTUnwrap(request(2, "session/new", ["cwd": workspace.path, "mcpServers": []])["sessionId"] as? String)
        _ = try request(3, "session/set_model", ["sessionId": session, "modelId": "default"])
        for (index, messages) in tasks.enumerated() {
            var messageIDs: Set<UUID> = []
            for body in messages {
                messageIDs.insert(try repository.sendUserMessage(conversationID: bot.conversation.id, body: body).id)
            }
            if #available(macOS 26, *), let completedReply {
                // Simulate a helper stopping after generation was saved but
                // before Messenger delivery. The command must not run on retry.
                let transcript = Transcript(entries: [Transcript.Entry.response(.init(assetIDs: [],
                    segments: [.text(.init(content: completedReply))]))])
                try AppleConversationSession(transcript: transcript, messageIDs: messageIDs, reply: completedReply)
                    .save(in: workspace, conversationID: bot.conversation.id)
            }
            let result = try request(4 + index, "session/prompt", ["sessionId": session,
                "prompt": [["type": "text", "text": AgentWakeReason.inboxChanged.eventText]]])
            if ProcessInfo.processInfo.environment["NOODLE_APPLE_TEST_TRACE"] == "1" {
                let trace = try String(contentsOf: workspace.appendingPathComponent(".noodle/apple/last-transcript.json"), encoding: .utf8)
                print("Synthetic Apple transcript: \(trace)")
            }
            XCTAssertEqual(result["stopReason"] as? String, "end_turn")
            print("Synthetic Apple completed turn \(index + 1)/\(tasks.count)")
            fflush(stdout)
        }
        let replies = try repository.loadMessages(conversationID: bot.conversation.id).filter {
            $0.author == .agent(bot.agent.id) && !existingMessageIDs.contains($0.id)
        }
        XCTAssertEqual(replies.count, tasks.count)
        guard replies.count == tasks.count else { return }
        print("Synthetic Apple replies: \(replies.map(\.body))")
        fflush(stdout)
        try verify(workspace, replies)
    }
}

private final class Responses: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [Int: [String: Any]] = [:]
    func receive(_ value: [String: Any]) {
        guard let id = value["id"] as? Int else { return }
        condition.lock(); defer { condition.unlock() }
        values[id] = value
        condition.broadcast()
    }
    func wait(_ id: Int, timeout: TimeInterval) -> [String: Any]? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while values[id] == nil, condition.wait(until: deadline) {}
        return values.removeValue(forKey: id)
    }
}
