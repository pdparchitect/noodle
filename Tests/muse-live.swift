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
    private var diagnostics = Data()
    init() throws {}
    func start(provider: HarnessProvider, agentID: UUID, executablePath: String, modelIdentifier: String?,
               effortIdentifier: String?, reply: @escaping (Int32, String?) -> Void) {
        launch(executablePath: executablePath, restricted: false, reply: reply)
    }
    func startRestrictedMuse(agentID: UUID, executablePath: String, modelIdentifier: String?, effortIdentifier: String?,
                             reply: @escaping (Int32, String?) -> Void) {
        launch(executablePath: executablePath, restricted: true, reply: reply)
    }
    private func launch(executablePath: String, restricted: Bool, reply: @escaping (Int32, String?) -> Void) {
        do {
            let native = try MuseExecutableTrust.executable(at: executablePath, home: HarnessStorage.userHome)
            process.executableURL = native
            process.arguments = ["serve", "--disable-sandbox", "--trust-workspace"]
            process.currentDirectoryURL = Self.workspace
            process.environment = ["HOME": HarnessStorage.userHome.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
                "PATH": "\(HarnessStorage.userHome.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                "TMPDIR": NSTemporaryDirectory(), "XDG_DATA_HOME": Self.storage.path]
            if restricted {
                let workspace = Self.workspace!
                let temporary = workspace.appendingPathComponent(".noodle/tmp")
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                let repository = AgentStorageLayout(workspace: workspace).package.deletingLastPathComponent().deletingLastPathComponent()
                let policy = try RestrictedAgentSandbox.profile(provider: .muse, workspace: workspace, repository: repository,
                    home: HarnessStorage.userHome, executable: native, application: project, temporary: temporary)
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                process.arguments = ["-p", policy, native.path] + process.arguments!
                process.environment?.merge(try RestrictedAgentSandbox.environment(provider: .muse,
                    home: HarnessStorage.userHome, workspace: workspace)) { _, fixed in fixed }
                process.environment?["TMPDIR"] = temporary.path
            }
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                else { Task { @MainActor in self?.receive(data) } }
            }
            process.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                Task { @MainActor in self?.onExit?(status) }
            }
            try process.run(); reply(process.processIdentifier, nil)
        } catch { reply(0, error.localizedDescription) }
    }
    private func receive(_ data: Data) {
        diagnostics.append(data)
        while let end = diagnostics.firstIndex(of: 10) {
            let line = diagnostics.prefix(upTo: end)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                FileHandle.standardError.write(Data("Muse fixture RPC error: \(message)\n".utf8))
            }
            diagnostics.removeSubrange(...end)
        }
        onData?(data, false)
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
        let environment = ProcessInfo.processInfo.environment
        let restricted = environment["NOODLE_TEST_MUSE_RESTRICTED"] == "1"
        guard restricted || environment["NOODLE_TEST_MUSE_LIVE"] == "1" else {
            print("Set NOODLE_TEST_MUSE_RESTRICTED=1 (sandboxed) or NOODLE_TEST_MUSE_LIVE=1 (autonomous) for two small model turns in a disposable fixture."); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-muse-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"), launcherExecutableURL: helper)
        let bot = try repository.createAgent(named: "Muse reply fixture", harnessIdentifier: "muse",
            modelIdentifier: environment["NOODLE_TEST_MUSE_MODEL"], reasoningEffort: "low",
            backstory: "This is an isolated integration test. Respond to the user's greeting through Messenger. Do not access other files, contact other services, or do unrelated work.")
        ExtendedAgentConnection.workspace = repository.directory(for: bot.agent)
        ExtendedAgentConnection.storage = root.appendingPathComponent("MuseData")
        for marker in ["Hello from Muse.", "Muse resumed."] {
            try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .user,
                body: "Integration test: read .agents/skills/messenger/SKILL.md and reply through Messenger with exactly: \(marker) Do not do other work.", delivery: .queued))
            let runtime = MuseAgentProcess(agent: bot.agent,
                executableURL: HarnessStorage.userHome.appendingPathComponent(".local/bin/muse"),
                workspaceURL: repository.directory(for: bot.agent), extendedAccess: !restricted, recoverInterruptedWork: false,
                onSnapshot: { print("Muse fixture: \($0.phase) — \($0.detail)") }, onHeartbeat: {},
                onUnexpectedTermination: { _, detail, _ in print("Unexpected termination: \(detail)") })
            defer { runtime.stop { _ in } }
            runtime.notify()
            let deadline = Date().addingTimeInterval(180)
            var completed = false
            while Date() < deadline {
                let messages = try repository.loadMessages(conversationID: bot.conversation.id)
                let reply = messages.first { $0.author == .agent(bot.agent.id) && $0.body.contains(marker) }
                if reply != nil, runtime.snapshot.phase == .ready { completed = true; break }
                if runtime.snapshot.phase == .failed { throw HarnessSetupError(runtime.snapshot.detail) }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard completed else { throw HarnessSetupError("Live Muse roundtrip timed out without a completed chat reply.") }
            print("PASS: \(restricted ? "restricted" : "autonomous") Muse Messenger reply: \(marker)")
        }
        print("PASS: Muse Messenger replies and session resume after process restart.")
    }
}
