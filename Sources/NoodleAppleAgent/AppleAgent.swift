import Darwin
import Foundation
import NoodleCore
import NoodleAppleRuntime

@main struct AppleAgent {
    static func main() async {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--inspect"] {
            do { try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(AppleModel.inspection(version: version)) + Data([10])) }
            catch { exit(1) }
            return
        }
        if args == ["--version"] { print(version); return }
        if args == ["--help"] { print("Usage: NoodleAppleAgent --serve | --inspect | --version"); return }
        guard args == ["--serve"] else { fputs("Use --serve or --inspect.\n", stderr); exit(2) }
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { AppleCommand.stopAll(); exit(0) }
        termination.resume()
        let server = AppleACPServer(workspace: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), version: version)
        // Read away from inference so cancellation is accepted during tool calls.
        await Task.detached {
            var pending = Data()
            while true {
                let data = FileHandle.standardInput.availableData
                if data.isEmpty { break }
                for byte in data {
                    if byte == 10 {
                        if let object = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] {
                            await server.receive(object)
                        }
                        pending.removeAll(keepingCapacity: true)
                    } else {
                        pending.append(byte)
                        if pending.count > 1_048_576 { AppleCommand.stopAll(); exit(2) }
                    }
                }
            }
            await server.shutdown()
        }.value
        withExtendedLifetime(termination) {}
    }
}

@MainActor private final class AppleACPServer {
    private let workspace: URL
    private let version: String
    private let output = RPCOutput()
    private var initialized = false
    private var sessionID: String?
    private var modelIdentifier: String?
    private var turn: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var timedOut = false
    private struct State: Codable { let id: String }

    init(workspace: URL, version: String) { self.workspace = workspace; self.version = version }

    func receive(_ object: [String: Any]) {
        guard let method = object["method"] as? String else { return }
        let id = object["id"]
        let params = object["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) { if let id { output.send(["id": id, "result": value]) } }
        do {
            if method == "initialize" {
                guard params["protocolVersion"] as? Int == 1 else { throw HarnessSetupError("Unsupported ACP version.") }
                initialized = true
                result(["protocolVersion": 1, "agentCapabilities": ["loadSession": true],
                        "agentInfo": ["name": "noodle-apple", "version": version], "authMethods": []])
                return
            }
            guard initialized else { throw HarnessSetupError("Initialize the harness first.") }
            if method == "session/cancel" {
                if params["sessionId"] as? String == sessionID { turn?.cancel(); AppleCommand.stopAll() }
                return
            }
            guard turn == nil else { throw HarnessSetupError("A turn is already running.") }
            switch method {
            case "session/new", "session/load":
                guard let cwd = params["cwd"] as? String,
                      URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == workspace.resolvingSymlinksInPath() else {
                    throw HarnessSetupError("The session must use the bot workspace selected by Agent Host.")
                }
                _ = try AgentStorageLayout.containing(workspace)
                if let reason = AppleModel.inspection(version: version).unavailableReason { throw HarnessSetupError(reason) }
                let file = workspace.appendingPathComponent(".noodle/apple/session.json")
                if method == "session/load" {
                    guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(State.self, from: data),
                          UUID(uuidString: state.id) != nil, params["sessionId"] as? String == state.id else {
                        throw HarnessSetupError("Session not found")
                    }
                    sessionID = state.id
                } else {
                    let newID = UUID().uuidString.lowercased()
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try AtomicFile.write(JSONEncoder().encode(State(id: newID)), to: file)
                    sessionID = newID
                }
                result(["sessionId": sessionID!])
            case "session/set_model":
                try requireSession(params)
                guard let model = params["modelId"] as? String,
                      AppleModel.inspection(version: version).models.contains(where: { $0.id == model }) else {
                    throw HarnessSetupError("The Apple harness does not support the selected model.")
                }
                modelIdentifier = model
                result([:])
            case "session/prompt":
                try requireSession(params)
                guard let id, let prompt = params["prompt"] as? [[String: Any]],
                      prompt.count == 1, prompt[0]["type"] as? String == "text",
                      let wake = prompt[0]["text"] as? String,
                      AgentWakeReason.allCases.contains(where: { $0.eventText == wake }) else {
                    throw HarnessSetupError("Expected a Noodle wake event.")
                }
                let session = sessionID!, writer = output, workspace = workspace, model = modelIdentifier
                timedOut = false
                turn = Task { [weak self] in
                    do {
                        try await AppleModel.respond(workspace: workspace, modelIdentifier: model, wake: wake) {
                            writer.send(["method": "session/update", "params": ["sessionId": session,
                                "update": ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Working"]]]])
                        }
                        writer.send(["id": id, "result": ["stopReason": "end_turn"]])
                    } catch is CancellationError {
                        if self?.timedOut == true { writer.error(id, "Apple exceeded the five-minute turn limit. Unfinished work is preserved.") }
                        else { writer.send(["id": id, "result": ["stopReason": "cancelled"]]) }
                    } catch { writer.error(id, error.localizedDescription) }
                    self?.deadline?.cancel()
                    self?.turn = nil
                }
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.timedOut = true
                    self?.turn?.cancel()
                    AppleCommand.stopAll()
                }
            default: output.error(id, "Unsupported method.", code: -32601)
            }
        } catch { output.error(id, error.localizedDescription) }
    }

    private func requireSession(_ params: [String: Any]) throws {
        guard let sessionID, params["sessionId"] as? String == sessionID else { throw HarnessSetupError("Session not found") }
    }
    func shutdown() { turn?.cancel(); deadline?.cancel(); AppleCommand.stopAll() }
}

private final class RPCOutput: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ object: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var object = object; object["jsonrpc"] = "2.0"
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
    }
    func error(_ id: Any?, _ message: String, code: Int = -32000) {
        guard let id else { return }
        send(["id": id, "error": ["code": code, "message": message]])
    }
}
