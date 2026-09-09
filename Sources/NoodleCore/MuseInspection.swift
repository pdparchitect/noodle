import Foundation

public enum MuseInspection {
    /// No login, prompts, sessions, Keychain access, or shell launcher.
    public static func inspect(home: URL, environment: [String: String]) throws -> MuseInspectionResult {
        let path = home.appendingPathComponent(".local/bin/muse").path
        guard FileManager.default.isExecutableFile(atPath: path) else { return .init(executablePath: nil, models: []) }
        let executable = try MuseExecutableTrust.executable(at: path, home: home)
        let wire = try MuseInspectionWire(executable: executable, environment: environment)
        defer { wire.stop() }
        try MuseProtocol.validateInitialization(wire.request(1, "initialize", MuseProtocol.initialize), durable: false)
        try wire.notify("initialized")
        return .init(executablePath: path, models: try MuseProtocol.models(wire.request(2, "model/list", [:])),
                     authentication: MuseAuthentication.inspect(home: home, environment: environment))
    }
}

private final class MuseInspectionWire: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe()
    private let condition = NSCondition()
    private var responses: [Int: [String: Any]] = [:]
    private var ended = false
    private lazy var reader = JSONLineReader { [weak self] object in
        guard let self, let id = object["id"] as? Int, id == 1 || id == 2 else { return }
        self.condition.lock(); defer { self.condition.unlock() }
        self.responses[id] = object
        self.condition.broadcast()
    }

    init(executable: URL, environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = ["serve", "--no-session-log"]
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

    func notify(_ method: String) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": [:]])
    }
    private func write(_ message: [String: Any]) throws {
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10]))
    }
    func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(15)
        while responses[id] == nil {
            guard !ended, condition.wait(until: deadline) else { throw HarnessSetupError("Muse Code inspection stopped or timed out.") }
        }
        guard let response = responses.removeValue(forKey: id), response["error"] == nil,
              let result = response["result"] as? [String: Any] else {
            throw HarnessSetupError("Muse Code could not return its model catalogue. Check Muse in Terminal.")
        }
        return result
    }
    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        guard process.isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        process.terminate()
        if process.isRunning, done.wait(timeout: .now() + 1) != .success {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
        }
    }
}
