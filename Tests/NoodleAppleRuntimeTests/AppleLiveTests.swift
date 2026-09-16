import XCTest
import NoodleCore
import FoundationModels
import CoreGraphics
@testable import NoodleAppleRuntime

/// Explicit opt-in: a real on-device model and a synthetic disposable bot. Never
/// opens the user's Noodle storage, accounts, or external model services.
final class AppleLiveTests: XCTestCase {
    func testSandboxedToolActivityArrivesBeforeTurnCompletion() throws {
        let local = ProcessInfo.processInfo.environment["NOODLE_TEST_MLX_MODEL"].map { URL(fileURLWithPath: $0) }
        try exercise(tasks: [["Use bash to run exactly once: printf activity-evidence; exit 7. Report the command's exit code."]],
            modelDirectory: local, promptTimeout: 300, verifyActivity: { _, messages in
                let updates = messages.compactMap { ($0["params"] as? [String: Any])?["update"] as? [String: Any] }
                XCTAssertTrue(updates.contains { ($0["title"] as? String) == "Loaded AGENTS.md and skill catalogue" })
                let start = try XCTUnwrap(updates.firstIndex { $0["sessionUpdate"] as? String == "tool_call" && $0["title"] as? String == "Bash" })
                let id = try XCTUnwrap(updates[start]["toolCallId"] as? String)
                let end = try XCTUnwrap(updates.firstIndex { $0["sessionUpdate"] as? String == "tool_call_update" && $0["toolCallId"] as? String == id })
                XCTAssertLessThan(start, end)
                XCTAssertEqual(updates[end]["status"] as? String, "failed")
                let result = String(decoding: try JSONSerialization.data(withJSONObject: updates[end]), as: UTF8.self)
                XCTAssertTrue(result.contains("Exit status: 7"))
                XCTAssertTrue(result.contains("activity-evidence"))
                XCTAssertTrue(result.contains("Duration:"))
                XCTAssertTrue(updates.contains { $0["title"] as? String == "Reply delivered" },
                              "All activity must arrive before the prompt-completed response")
            }) { _, replies in
                XCTAssertTrue(replies[0].body.contains("7"))
            }
    }

    func testSandboxedLocalModelRoutesResumedGuestTaskThroughComputerCLI() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("Local models require macOS 27.") }
        guard let modelPath = ProcessInfo.processInfo.environment["NOODLE_TEST_MLX_MODEL"] else {
            throw XCTSkip("Set NOODLE_TEST_MLX_MODEL for the local-model computer-routing test.")
        }
        let computer = UUID().uuidString.lowercased(), terminal = UUID().uuidString.lowercased()
        let observed = UUID().uuidString.lowercased()
        try exercise(history: [(false, "An earlier attempt was interrupted before reading the assigned computer.")],
            tasks: [["On my assigned computer, read /workspace/check.txt and reply with its exact contents."]],
            modelDirectory: URL(fileURLWithPath: modelPath), nativeHistory: true, promptTimeout: 600,
            assignedComputer: UUID(uuidString: computer),
            configure: { workspace in
                let skill = workspace.appendingPathComponent(".agents/skills/computer")
                // A synthetic Computer provider: the real model must discover
                // IDs, send the guest command, then read its observed output.
                // No production computer or conversation is touched.
                let script = """
                #!/bin/bash
                set -eu
                printf '%s\\n' "$*" >> computer-calls.txt
                operation="$1"; shift
                computer=''; terminal=''; command=''
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --computer) computer="$2";;
                    --terminal) terminal="$2";;
                    --text) command="$2";;
                    --offset) ;;
                    *) exit 2;;
                  esac
                  shift 2
                done
                case "$operation" in
                  list) printf '%s\\n' '{"computers":[{"id":"\(computer)","name":"Test computer","kind":"shell","state":"running"}]}' ;;
                  open)
                    [ "$computer" = '\(computer)' ]
                    printf '%s\\n' '{"terminalID":"\(terminal)"}' ;;
                  write)
                    [ "$computer" = '\(computer)' ] && [ "$terminal" = '\(terminal)' ]
                    case "$command" in *'/workspace/check.txt'*) printf '%s' "$command" > guest-command.txt;; *) exit 3;; esac
                    printf '%s\\n' '{"ok":true}' ;;
                  read)
                    [ "$computer" = '\(computer)' ] && [ "$terminal" = '\(terminal)' ] && [ -f guest-command.txt ]
                    printf '%s\\n' '{"text":"\(observed)","offset":36,"truncated":false,"exited":false}' ;;
                  *) exit 2 ;;
                esac
                """
                let cli = skill.appendingPathComponent("computer")
                // Replace a generated CLI link without writing through it.
                try? FileManager.default.removeItem(at: cli)
                try Data(script.utf8).write(to: cli)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
                try Data("unfinished".utf8).write(to: workspace.appendingPathComponent(".noodle/apple/unfinished"))
            }) { workspace, replies in
                let transcript = try JSONDecoder().decode(Transcript.self,
                    from: Data(contentsOf: workspace.appendingPathComponent(".noodle/apple/last-transcript.json")))
                let instructions = transcript.compactMap { entry -> String? in
                    if case .instructions = entry { return entry.description }; return nil
                }.joined(separator: "\n")
                XCTAssertTrue(instructions.contains("<name>computer</name>"))
                XCTAssertTrue(instructions.contains("Run commands in guest terminals"))
                XCTAssertFalse(instructions.contains("A write acknowledgement only confirms input was sent"),
                               "Discover the skill through metadata, not a Computer-specific prompt recipe")
                let modelCalls = transcript.flatMap { entry -> [Transcript.ToolCall] in
                    if case .toolCalls(let calls) = entry { return Array(calls) }; return []
                }
                XCTAssertTrue(modelCalls.contains {
                    ($0.toolName == "read" || $0.toolName == "bash")
                        && $0.arguments.jsonString.contains(".agents/skills/computer/SKILL.md")
                }, "The model must read the skill discovered through the system catalogue")
                XCTAssertTrue(replies[0].body.contains(observed), "The reply must use observed guest output")
                let calls = try String(contentsOf: workspace.appendingPathComponent("computer-calls.txt"), encoding: .utf8)
                    .split(separator: "\n").map(String.init)
                for operation in ["list", "open", "write", "read"] {
                    XCTAssertTrue(calls.contains { $0 == operation || $0.hasPrefix(operation + " ") }, "Missing \(operation): \(calls)")
                }
                let guestCommand = try String(contentsOf: workspace.appendingPathComponent("guest-command.txt"), encoding: .utf8)
                XCTAssertTrue(guestCommand.contains("/workspace/check.txt"))
                for call in modelCalls where call.arguments.jsonString.contains("/workspace/check.txt") {
                    XCTAssertEqual(call.toolName, "bash")
                    XCTAssertTrue(call.arguments.jsonString.contains(".agents/skills/computer/computer write"),
                                  "Guest paths must not be executed as local workspace commands")
                }
            }
    }

    func testSandboxedNaturalRequestExecutesBashAndReturnsObservedTime() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires Foundation Models.") }
        let local = ProcessInfo.processInfo.environment["NOODLE_TEST_MLX_MODEL"].map { URL(fileURLWithPath: $0) }
        try exercise(history: [
            (false, "Can you run commands?"), (true, "I cannot run external commands."),
            (false, "You have bash access."), (true, "I have access to bash."),
            (false, "What is the system time?"), (true, "You can run the date command to find the time.")
        ], tasks: [["Use the bash tool to run a command to find the exact system time"]],
           modelDirectory: local, nativeHistory: true) { workspace, replies in
            let transcript = try JSONDecoder().decode(Transcript.self,
                from: Data(contentsOf: workspace.appendingPathComponent(".noodle/apple/last-transcript.json")))
            let calls = transcript.flatMap { entry -> [Transcript.ToolCall] in
                if case .toolCalls(let calls) = entry { return Array(calls) }; return []
            }
            XCTAssertTrue(calls.contains { $0.toolName == "bash" && $0.arguments.jsonString.contains("date") },
                          "Expected an actual Bash date call, received: \(replies[0].body)")
            let outputs = transcript.compactMap { entry -> String? in
                if case .toolOutput(let output) = entry, output.toolName == "bash" { return entry.description }; return nil
            }.joined(separator: "\n")
            XCTAssertTrue(outputs.contains("Exit status: 0"), outputs)
            let range = try XCTUnwrap(outputs.range(of: #"\b\d{2}:\d{2}(?::\d{2})?\b"#, options: .regularExpression), outputs)
            XCTAssertTrue(replies[0].body.contains(String(outputs[range])), replies[0].body)
        }
    }

    func testSandboxedToolDiscoveryAndCLIFollowupUseManagedSession() throws {
        let local = ProcessInfo.processInfo.environment["NOODLE_TEST_MLX_MODEL"].map { URL(fileURLWithPath: $0) }
        try exercise(tasks: [
            ["What tools do you have access to?"],
            ["No execute_command ?"],
            ["Use bash to run ./.agents/skills/messenger/messenger --list-conversations > conversations.json, then report success."]
        ], modelDirectory: local) { workspace, replies in
            let inventory = replies[0].body.lowercased()
            for name in ["bash", "read", "write"] { XCTAssertTrue(inventory.contains(name), replies[0].body) }
            XCTAssertFalse(inventory.contains("conversation_history"), replies[0].body)
            XCTAssertFalse(replies[1].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let conversations = try decoder.decode([BotConversation].self,
                from: Data(contentsOf: workspace.appendingPathComponent("conversations.json")))
            XCTAssertEqual(conversations.count, 1)
            XCTAssertEqual(conversations.first?.displayName, "Apple test")
        }
    }

    func testSandboxedImageAttachmentIsRecognized() throws {
        #if canImport(FoundationModels, _version: 2)
        guard #available(macOS 27, *), SystemLanguageModel.default.capabilities.contains(.vision) else {
            throw XCTSkip("This device has no image capability.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("apple-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let samples: [(String, CGColor)] = [
            ("red", CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            ("green", CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            ("blue", CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ]
        for (expected, color) in samples {
            try Apple27LiveTests.writeSquare(to: file, color: color)
            try exercise(tasks: [["What color is the square in the attached image? Answer in one word."]], image: file) { _, replies in
                XCTAssertTrue(replies[0].body.lowercased().contains(expected), "Expected \(expected), received \(replies[0].body)")
            }
        }
        #else
        throw XCTSkip("Build with the macOS 27 SDK for image input.")
        #endif
    }

    func testSandboxedImportedLocalModelWritesAndReplies() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_MLX_MODEL"] else {
            throw XCTSkip("Set NOODLE_TEST_MLX_MODEL to a local MLX model folder for offline inference.")
        }
        try exercise(tasks: [["Use write to create result.txt containing exactly: saffron"]],
                     modelDirectory: URL(fileURLWithPath: path)) { workspace, replies in
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("result.txt")).trimmingCharacters(in: .whitespacesAndNewlines), "saffron")
            XCTAssertFalse(replies.isEmpty)
        }
    }
    func testSandboxedCompletedReplyDoesNotRepeatItsCommand() throws {
        try exercise(tasks: [["Use bash to run: printf repeated > should-not-run.txt"]],
                     completedReply: "The operation finished before the interruption.") { workspace, replies in
            XCTAssertEqual(replies[0].body, "The operation finished before the interruption.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("should-not-run.txt").path))
        }
    }

    func testSandboxedAgentReadsWritesExecutesAndReplies() throws {
        try exercise(tasks: [
            ["Use write to create result.txt with this content:\na small apple"],
            ["Use read to read seed.txt, then send me its text in your reply."],
            ["Use bash to run this shell command:\n```sh\nprintf ready > command.txt\n```"]
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

    private func exercise(named name: String = "Apple test", history: [(Bool, String)] = [], tasks: [[String]], completedReply: String? = nil, modelDirectory: URL? = nil, image: URL? = nil, nativeHistory: Bool = false,
                          promptTimeout: TimeInterval = 180, assignedComputer: UUID? = nil,
                          configure: (URL) throws -> Void = { _ in },
                          verifyActivity: (Int, [[String: Any]]) throws -> Void = { _, _ in },
                          verify: (URL, [ChatMessage]) throws -> Void) throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_APPLE_MODEL"] == "1" || modelDirectory != nil else {
            throw XCTSkip("Set NOODLE_TEST_APPLE_MODEL=1 for the real on-device model test.")
        }
        if modelDirectory == nil, let reason = AppleModel.inspection(version: "test").unavailableReason { throw XCTSkip(reason) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-live-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = ProcessInfo.processInfo.environment["NOODLE_APPLE_TEST_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? project.appendingPathComponent(".build/debug/NoodleAppleAgent")
        let messenger = helper.deletingLastPathComponent().appendingPathComponent(
            helper.deletingLastPathComponent().lastPathComponent == "Helpers" ? "messenger" : "NoodleMessenger")
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: messenger)
        let modelStore = AppleLocalModelStore(repository: root)
        let local = try modelDirectory.map { try modelStore.importModel(from: $0) }
        let bot = try repository.createAgent(named: name, harnessIdentifier: "apple")
        if let assignedComputer {
            var assignments = ComputerAssignments()
            assignments.agents[bot.agent.id.uuidString] = [assignedComputer]
            try assignments.save(root: root)
            try repository.synchronizeAgentWorkspace(bot.agent)
        }
        for (isAssistant, body) in history {
            if isAssistant { _ = try repository.sendAgentMessage(agentID: bot.agent.id, conversationID: bot.conversation.id, body: body) }
            else { _ = try repository.sendUserMessage(conversationID: bot.conversation.id, body: body) }
        }
        _ = try repository.latestMessages(for: bot.agent.id, consuming: true)
        let existingMessageIDs = Set(try repository.loadMessages(conversationID: bot.conversation.id).map(\.id))
        let broker = MessengerBroker(repository: repository)
        try broker.start(agents: [bot.agent])
        defer { broker.stop() }
        let workspace = repository.directory(for: bot.agent)
        if #available(macOS 26, *), nativeHistory {
            let entries: [Transcript.Entry] = history.map { isAssistant, text in
                isAssistant ? .response(.init(assetIDs: [], segments: [.text(.init(content: text))]))
                    : .prompt(.init(segments: [.text(.init(content: text))]))
            }
            try AppleConversationSession(transcript: Transcript(entries: entries), messageIDs: [], reply: "",
                modelIdentifier: local?.id ?? "default").save(in: workspace, conversationID: bot.conversation.id)
        }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/tmp"), withIntermediateDirectories: true)
        try Data("a crisp pear".utf8).write(to: workspace.appendingPathComponent("seed.txt"))
        try configure(workspace)
        let application = helper.deletingLastPathComponent().lastPathComponent == "Helpers"
            ? helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : helper.deletingLastPathComponent()
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe(), responses = Responses()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", AppleAgentSandbox.profile(application: application, workspace: workspace, repository: root,
            modelsDirectory: try local.map { try modelStore.folder(id: $0.id) }, localModel: local != nil), helper.path, "--serve"]
        child.currentDirectoryURL = workspace
        child.environment = ["HOME": workspace.path, "PATH": "/usr/bin:/bin", "TMPDIR": workspace.appendingPathComponent(".noodle/tmp").path]
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        let diagnostics = DiagnosticBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil } else { diagnostics.append(bytes) }
        }
        child.terminationHandler = { _ in responses.closed() }
        let reader = JSONLineReader { responses.receive($0) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil } else { reader.receive(bytes) }
        }
        try child.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            input.fileHandleForWriting.closeFile()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([10]))
            guard let response = responses.wait(id, timeout: method == "session/prompt" ? promptTimeout : 20) else {
                throw HarnessSetupError("No response to \(method).\n\(diagnostics.text)")
            }
            if let error = response["error"] {
                let trace = (try? String(contentsOf: workspace.appendingPathComponent(".noodle/apple/last-transcript.json"), encoding: .utf8)) ?? "No transcript"
                let detail = (try? String(contentsOf: workspace.appendingPathComponent(".noodle/apple/last-error.txt"), encoding: .utf8)) ?? ""
                throw HarnessSetupError("\(error)\nSynthetic transcript: \(String(trace.suffix(10_000)))\n\(detail)\n\(diagnostics.text)")
            }
            return try XCTUnwrap(response["result"] as? [String: Any])
        }
        _ = try request(1, "initialize", FxProtocol.initializeParameters)
        let session = try XCTUnwrap(request(2, "session/new", ["cwd": workspace.path, "mcpServers": []])["sessionId"] as? String)
        _ = try request(3, "session/set_model", ["sessionId": session, "modelId": local?.id ?? "default"])
        for (index, messages) in tasks.enumerated() {
            var messageIDs: Set<UUID> = []
            for body in messages {
                let attachmentIDs = try image.map { [try repository.importAttachment(from: $0, into: bot.conversation.id, mediaType: "image/png").id] } ?? []
                messageIDs.insert(try repository.sendUserMessage(conversationID: bot.conversation.id, body: body, attachmentIDs: attachmentIDs).id)
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
            try verifyActivity(index, responses.activity(through: 4 + index))
            if ProcessInfo.processInfo.environment["NOODLE_APPLE_TEST_TRACE"] == "1" {
                let trace = try String(contentsOf: workspace.appendingPathComponent(".noodle/apple/last-transcript.json"), encoding: .utf8)
                print("Synthetic Apple transcript: \(trace)")
            }
            XCTAssertEqual(result["stopReason"] as? String, "end_turn")
            if #available(macOS 26, *), completedReply == nil {
                let saved = try JSONDecoder().decode(AppleConversationSession.self,
                    from: Data(contentsOf: AppleConversationSession.file(in: workspace, conversationID: bot.conversation.id)))
                XCTAssertEqual(saved.messageIDs, messageIDs)
                if index > 0 {
                    let transcript = saved.transcript.map(\.description).joined(separator: "\n")
                    XCTAssertTrue(transcript.contains(tasks[index - 1].last!) || transcript.contains("Summary of the conversation so far:"),
                                  "The follow-up must resume or summarize the saved session")
                }
            }
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
    private var updates: [[String: Any]] = []
    private var updatesAtResponse: [Int: [[String: Any]]] = [:]
    private var ended = false
    func closed() { condition.lock(); ended = true; condition.broadcast(); condition.unlock() }
    func receive(_ value: [String: Any]) {
        condition.lock(); defer { condition.unlock() }
        if value["method"] as? String == "session/update" { updates.append(value) }
        guard let id = value["id"] as? Int else { return }
        values[id] = value
        updatesAtResponse[id] = updates
        condition.broadcast()
    }
    func activity(through id: Int) -> [[String: Any]] {
        condition.lock(); defer { condition.unlock() }
        return updatesAtResponse[id] ?? []
    }
    func wait(_ id: Int, timeout: TimeInterval) -> [String: Any]? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while values[id] == nil, !ended, condition.wait(until: deadline) {}
        return values.removeValue(forKey: id)
    }
}

private final class DiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
        if data.count > 24_000 { data = data.suffix(24_000) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
