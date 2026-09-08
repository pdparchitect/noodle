import Foundation

/// An account/catalogue-only ACP exchange. No sessions, prompts or tools.
/// Called by the signed host; Noodle receives only the sanitized result.
public enum GrokInspection {
    public static func inspect(home: URL, environment: [String: String]) throws -> GrokInspectionResult {
        let path = home.appendingPathComponent(".grok/bin/grok").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .init(executablePath: nil, authenticated: false, models: [])
        }
        let executable = try GrokExecutableTrust.executable(at: path, home: home)
        let wire = try GrokInspectionWire(executable: executable, environment: environment)
        defer { wire.stop() }
        let initialization = try wire.request(1, "initialize", FxProtocol.initializeParameters)
        guard let result = initialization["result"] as? [String: Any], result["protocolVersion"] as? Int == 1 else {
            throw HarnessSetupError("Grok Build returned an unsupported ACP version.")
        }
        let auth = try wire.request(2, "authenticate", ["methodId": "cached_token"])
        return .init(executablePath: path, authenticated: auth["result"] is [String: Any],
                     models: try GrokProtocol.models(from: result))
    }
}

private final class GrokInspectionWire: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe()
    private let condition = NSCondition()
    private var responses: [Int: [String: Any]] = [:]
    private var ended = false
    private lazy var reader = JSONLineReader { [weak self] object in
        guard let self, let id = object["id"] as? Int, id == 1 || id == 2 else { return }
        self.condition.lock()
        self.responses[id] = object
        self.condition.broadcast()
        self.condition.unlock()
    }

    init(executable: URL, environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = ["agent", "--no-leader", "stdio"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = reader
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock(); self.ended = true; self.condition.broadcast(); self.condition.unlock()
        }
        try process.run()
    }

    func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject:
            ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([10]))
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(20)
        while responses[id] == nil {
            guard !ended, condition.wait(until: deadline) else {
                throw HarnessSetupError("Grok Build account inspection stopped or timed out. Check grok in Terminal.")
            }
        }
        return responses.removeValue(forKey: id)!
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        guard process.isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        process.terminate()
        if process.isRunning, done.wait(timeout: .now() + 2) != .success {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 2)
        }
    }
}
