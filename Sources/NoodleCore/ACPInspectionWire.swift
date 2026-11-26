import Foundation

/// One account or catalogue exchange with an ACP harness: one request at a time, read-only.
final class ACPInspectionWire: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe()
    private let condition = NSCondition()
    private var responses: [Int: [String: Any]] = [:]
    private var pendingID: Int?
    private var ended = false
    private let name: String
    private let command: String
    private let requestTimeout: TimeInterval
    private let terminationGrace: TimeInterval
    private lazy var reader = JSONLineReader { [weak self] object in
        guard let self, let id = object["id"] as? Int else { return }
        self.condition.lock(); defer { self.condition.unlock() }
        guard id == self.pendingID, self.responses[id] == nil else { return }
        self.responses[id] = object
        self.condition.broadcast()
    }

    /// `command` is what the person types to run the harness in Terminal. Only a sign-in the
    /// person started `opensPages`; every other exchange is kept away from the browser.
    init(name: String, command: String, executable: URL, arguments: [String], environment: [String: String],
         requestTimeout: TimeInterval, terminationGrace: TimeInterval, opensPages: Bool = false) throws {
        self.name = name
        self.command = command
        self.requestTimeout = requestTimeout
        self.terminationGrace = terminationGrace
        if opensPages {
            process.executableURL = executable
            process.arguments = arguments
        } else { BrowserlessLaunch.configure(process, executable: executable, arguments: arguments) }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        BrokenPipe.reportAsError(input.fileHandleForWriting.fileDescriptor)
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

    /// `silenceIsAnswer` returns nil when a peer that is still running lets the request time out.
    func request(_ id: Int, _ method: String, _ params: [String: Any], silenceIsAnswer: Bool = false) throws -> [String: Any]? {
        condition.lock(); defer { pendingID = nil; condition.unlock() }
        guard !ended else { throw HarnessSetupError("\(name) account inspection stopped.") }
        pendingID = id
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject:
            ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([10]))
        let deadline = Date().addingTimeInterval(requestTimeout)
        while responses[id] == nil {
            guard !ended, condition.wait(until: deadline) else {
                if silenceIsAnswer, !ended, responses[id] == nil { return nil }
                throw HarnessSetupError("\(name) account inspection stopped or timed out. Check \(command) in Terminal.")
            }
        }
        let response = responses.removeValue(forKey: id)!
        let success = response["result"] is [String: Any] && response["error"] == nil
        let failure = response["error"] is [String: Any] && response["result"] == nil
        guard response["jsonrpc"] as? String == "2.0", success || failure else {
            throw HarnessSetupError("\(name) returned an invalid inspection response.")
        }
        return response
    }

    /// Ends a request still waiting, from another thread, and stops the harness.
    func interrupt() {
        condition.lock(); ended = true; condition.broadcast(); condition.unlock()
        stop()
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
