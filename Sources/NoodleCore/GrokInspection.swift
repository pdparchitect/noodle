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
        return try inspect(executable: executable, installationPath: path, environment: environment)
    }

    // Exercise the protocol with a local fixture; the public entry point always verifies the installation.
    static func inspect(executable: URL, installationPath: String, environment: [String: String],
                        requestTimeout: TimeInterval = 20, terminationGrace: TimeInterval = 2) throws -> GrokInspectionResult {
        let wire = try GrokInspectionWire(executable: executable, environment: environment,
                                          requestTimeout: requestTimeout, terminationGrace: terminationGrace)
        defer { wire.stop() }
        let initialization = try wire.request(1, "initialize", FxProtocol.initializeParameters)
        guard let result = initialization["result"] as? [String: Any], result["protocolVersion"] as? Int == 1 else {
            throw HarnessSetupError("Grok Build returned an unsupported ACP version.")
        }
        let auth = try wire.request(2, "authenticate", ["methodId": "cached_token"])
        return .init(executablePath: installationPath, authenticated: auth["result"] is [String: Any],
                     models: try GrokProtocol.models(from: result))
    }
}

private final class GrokInspectionWire: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe()
    private let condition = NSCondition()
    private var responses: [Int: [String: Any]] = [:]
    private var pendingID: Int?
    private var ended = false
    private let requestTimeout: TimeInterval
    private let terminationGrace: TimeInterval
    private lazy var reader = JSONLineReader { [weak self] object in
        guard let self, let id = object["id"] as? Int else { return }
        self.condition.lock(); defer { self.condition.unlock() }
        guard id == self.pendingID, self.responses[id] == nil else { return }
        self.responses[id] = object
        self.condition.broadcast()
    }

    init(executable: URL, environment: [String: String], requestTimeout: TimeInterval, terminationGrace: TimeInterval) throws {
        self.requestTimeout = requestTimeout
        self.terminationGrace = terminationGrace
        process.executableURL = executable
        process.arguments = ["agent", "--no-leader", "stdio"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = reader
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                reader.finish { [weak self] in
                    guard let self else { return }
                    self.condition.lock(); self.ended = true; self.condition.broadcast(); self.condition.unlock()
                }
            } else { reader.receive(data) }
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        condition.lock(); defer { pendingID = nil; condition.unlock() }
        guard !ended else { throw HarnessSetupError("Grok Build account inspection stopped.") }
        pendingID = id
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject:
            ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([10]))
        let deadline = Date().addingTimeInterval(requestTimeout)
        while responses[id] == nil {
            guard !ended, condition.wait(until: deadline) else {
                throw HarnessSetupError("Grok Build account inspection stopped or timed out. Check grok in Terminal.")
            }
        }
        let response = responses.removeValue(forKey: id)!
        let success = response["result"] is [String: Any] && response["error"] == nil
        let failure = response["error"] is [String: Any] && response["result"] == nil
        guard response["jsonrpc"] as? String == "2.0", success || failure else {
            throw HarnessSetupError("Grok Build returned an invalid inspection response.")
        }
        return response
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        guard process.isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        process.terminate()
        if process.isRunning, done.wait(timeout: .now() + terminationGrace) != .success {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + terminationGrace)
        }
    }
}
