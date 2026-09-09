import Foundation
import NoodleCore

@MainActor protocol AgentRuntimeProcess: AnyObject {}

/// Opt-in live transport for the real adapter. Uses only a temporary Noodle
/// repository and Muse session store; never loads or modifies a user's bot.
@MainActor final class ExtendedAgentConnection {
    static var workspace: URL!
    static var storage: URL!
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    private let process = Process(), input = Pipe(), output = Pipe()
    init() throws {}
    func start(provider: HarnessProvider, agentID: UUID, executablePath: String, modelIdentifier: String?,
               effortIdentifier: String?, reply: @escaping (Int32, String?) -> Void) {
        do {
            let native = try MuseExecutableTrust.executable(at: executablePath, home: HarnessStorage.userHome)
            process.executableURL = native
            process.arguments = ["serve", "--disable-sandbox", "--trust-workspace"]
            process.currentDirectoryURL = Self.workspace
            process.environment = ["HOME": HarnessStorage.userHome.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
                "PATH": "\(HarnessStorage.userHome.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                "TMPDIR": NSTemporaryDirectory(), "XDG_DATA_HOME": Self.storage.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                else { Task { @MainActor in self?.onData?(data, false) } }
            }
            process.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                Task { @MainActor in self?.onExit?(status) }
            }
            try process.run(); reply(process.processIdentifier, nil)
        } catch { reply(0, error.localizedDescription) }
    }
    func write(_ data: Data) { try? input.fileHandleForWriting.write(contentsOf: data) }
    func invalidate() {
        process.terminationHandler = nil
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
    func stop(reply: @escaping (Bool) -> Void) { invalidate(); reply(true) }
}

@main struct MuseLiveChecks {
    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_MUSE_LIVE"] == "1" else {
            print("Set NOODLE_TEST_MUSE_LIVE=1 to run a real model/Messenger roundtrip in a disposable fixture."); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-muse-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"), launcherExecutableURL: helper)
        let bot = try repository.createAgent(named: "Muse reply fixture", harnessIdentifier: "muse",
            modelIdentifier: "muse-spark-1.2", reasoningEffort: "high",
            backstory: "This is an isolated integration test. Respond to the user's greeting through Messenger. Do not access other files, contact other services, or do unrelated work.")
        ExtendedAgentConnection.workspace = repository.directory(for: bot.agent)
        ExtendedAgentConnection.storage = root.appendingPathComponent("MuseData")
        try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .user,
            body: "Hello! Please reply with: Hello from Muse.", delivery: .delivered))
        let runtime = MuseAgentProcess(agent: bot.agent,
            executableURL: HarnessStorage.userHome.appendingPathComponent(".local/bin/muse"),
            workspaceURL: repository.directory(for: bot.agent), extendedAccess: true, recoverInterruptedWork: false,
            onSnapshot: { print("Muse fixture: \($0.phase) — \($0.detail)") }, onHeartbeat: {},
            onUnexpectedTermination: { _, detail, _ in print("Unexpected termination: \(detail)") })
        defer { runtime.stop { _ in } }
        runtime.notify()
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let messages = try repository.loadMessages(conversationID: bot.conversation.id)
            let reply = messages.first { $0.author == .agent(bot.agent.id) }
            if let reply, runtime.snapshot.phase == .ready {
                precondition(!reply.body.isEmpty)
                print("PASS: real Muse → Messenger → persisted Noodle chat reply; turn completed and runtime ready.")
                return
            }
            if runtime.snapshot.phase == .failed { throw HarnessSetupError(runtime.snapshot.detail) }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw HarnessSetupError("Live Muse roundtrip timed out without a completed chat reply.")
    }
}
