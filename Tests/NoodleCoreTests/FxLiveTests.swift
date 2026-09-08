import XCTest
@testable import NoodleCore

/// Explicit opt-in: uses the installed account for two tiny model turns, only in
/// a disposable Noodle repository. Never starts or changes the user's bots.
final class FxLiveTests: XCTestCase {
    func testInstalledFXMessengerAndSessionResume() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_FX_EXECUTABLE"],
              let messenger = ProcessInfo.processInfo.environment["NOODLE_TEST_MESSENGER_EXECUTABLE"] else {
            throw XCTSkip("Set FX and Messenger executable paths to run the live harness test.")
        }
        let executable = try FxExecutableTrust.executable(at: path, home: HarnessStorage.userHome)
        let environment = ProcessInfo.processInfo.environment
        XCTAssertTrue(try FxInspection.status(executable: executable, environment: environment).authenticated)
        XCTAssertFalse(try FxInspection.models(executable: executable, environment: environment).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-fx-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: URL(fileURLWithPath: messenger))
        try repository.prepare()
        let bot = try repository.createAgent(named: "FX Integration Fixture", harnessIdentifier: HarnessProvider.fx.rawValue)
        let workspace = repository.directory(for: bot.agent)
        func enqueue(_ body: String) throws {
            try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .user, body: body, delivery: .queued))
        }
        try enqueue("Integration test: read .agents/skills/messenger/SKILL.md, then reply through Messenger with exactly FX smoke ok. Do not do any other work or use other skills.")
        let first = try ACPWireFixture(executable: executable, workspace: workspace)
        defer { first.stop() }
        _ = try first.request("initialize", FxProtocol.initializeParameters)
        let opened = try first.request("session/new", ["cwd": workspace.path, "mcpServers": []])
        let session = try XCTUnwrap(opened["sessionId"] as? String)
        _ = try first.request("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": AgentWakeReason.inboxChanged.eventText]]])
        guard try repository.loadMessages(conversationID: bot.conversation.id).contains(where: { $0.author == .agent(bot.agent.id) && $0.body.contains("FX smoke ok") }) else {
            throw HarnessSetupError("FX did not reply through Messenger. Fixture output: \(first.diagnostics)")
        }
        first.stop()
        try enqueue("Integration test: reply through Messenger with exactly FX resumed. Do not do any other work.")
        let second = try ACPWireFixture(executable: executable, workspace: workspace)
        defer { second.stop() }
        _ = try second.request("initialize", FxProtocol.initializeParameters)
        _ = try second.request("session/load", ["sessionId": session, "cwd": workspace.path, "mcpServers": []])
        _ = try second.request("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": AgentWakeReason.runtimeRecovered.eventText]]])
        XCTAssertTrue(try repository.loadMessages(conversationID: bot.conversation.id).contains { $0.author == .agent(bot.agent.id) && $0.body.contains("FX resumed") })
    }
}

final class ACPWireFixture {
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe()
    private let condition = NSCondition(), writeLock = NSLock()
    private var messages: [Int: [String: Any]] = [:]
    private var sequence = 0
    private var diagnosticText = ""
    var diagnostics: String {
        condition.lock(); defer { condition.unlock() }
        return diagnosticText
    }
    private lazy var reader = JSONLineReader { [weak self] object in self?.receive(object) }
    init(executable: URL, workspace: URL, arguments: [String] = ["acp"]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.reader.receive(data) }
        }
        try process.run()
    }
    func stop() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            process.terminate()
            if process.isRunning, finished.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
    }
    private func send(_ object: [String: Any]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try stdin.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    private func receive(_ object: [String: Any]) {
        if object["method"] as? String == "session/update", let params = object["params"] as? [String: Any], let update = params["update"] as? [String: Any] {
            let content = update["content"] as? [String: Any]
            let text = content?["text"] as? String ?? "\n\(update)\n"
            condition.lock()
            diagnosticText = String((diagnosticText + text).suffix(18000))
            condition.unlock()
        }
        if let method = object["method"] as? String, let id = object["id"] {
            if method == "session/request_permission", let params = object["params"] as? [String: Any] {
                try? send(["jsonrpc": "2.0", "id": id, "result": FxProtocol.permissionResponse(params: params, sessionID: params["sessionId"] as? String, extendedAccess: true)])
            } else { try? send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported"]]) }
        } else if let id = object["id"] as? Int {
            condition.lock(); messages[id] = object; condition.broadcast(); condition.unlock()
        }
    }
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        FileHandle.standardError.write(Data("ACP fixture: \(method)\n".utf8))
        sequence += 1
        let id = sequence
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(120)
        while messages[id] == nil {
            guard condition.wait(until: deadline) else { throw HarnessSetupError("ACP live test timed out during \(method)") }
        }
        let object = messages.removeValue(forKey: id)!
        if let error = object["error"] as? [String: Any] { throw HarnessSetupError("ACP \(method): \(error["message"] ?? "failed")") }
        return object["result"] as? [String: Any] ?? [:]
    }
}
