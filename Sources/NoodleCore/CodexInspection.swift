import Foundation

/// Codex's model catalogue, read over a short-lived account-only app-server
/// connection. The Agent Host runs this for a Codex the sandboxed app cannot.
public enum CodexInspection {
    public static func models(executable: URL, environment: [String: String], clientVersion: String,
                              timeout: TimeInterval = 8) throws -> [HarnessModel] {
        let wire = try Wire(executable: executable, environment: environment, timeout: timeout)
        defer { wire.stop() }
        _ = try wire.request(1, "initialize", ["clientInfo": ["name": "noodle", "title": "Noodle", "version": clientVersion],
                                               "capabilities": [:]])
        try wire.send(["method": "initialized", "params": [:]])
        let result = try wire.request(2, "model/list", ["includeHidden": false, "limit": 100])
        let models = (result["data"] as? [[String: Any]] ?? []).compactMap(model)
        guard !models.isEmpty else { throw HarnessSetupError("Codex returned no available models") }
        return models
    }

    public static func model(_ value: [String: Any]) -> HarnessModel? {
        guard let id = (value["model"] as? String) ?? (value["id"] as? String) else { return nil }
        let effortValues = value["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        let efforts = effortValues.compactMap { effort -> HarnessEffort? in
            guard let id = effort["reasoningEffort"] as? String else { return nil }
            return HarnessEffort(id: id, description: effort["description"] as? String ?? "")
        }
        return HarnessModel(
            id: id,
            displayName: value["displayName"] as? String ?? id,
            description: value["description"] as? String ?? "",
            supportedEfforts: efforts,
            defaultEffort: value["defaultReasoningEffort"] as? String ?? efforts.first?.id ?? "medium",
            isDefault: value["isDefault"] as? Bool ?? false
        )
    }

    private final class Wire: @unchecked Sendable {
        private let process = Process(), input = Pipe(), output = Pipe()
        private let condition = NSCondition()
        private var responses: [Int: [String: Any]] = [:]
        private var ended = false
        private let timeout: TimeInterval
        private lazy var reader = JSONLineReader { [weak self] object in
            guard let self, let id = (object["id"] as? NSNumber)?.intValue else { return }
            self.condition.lock(); self.responses[id] = object; self.condition.broadcast(); self.condition.unlock()
        }

        init(executable: URL, environment: [String: String], timeout: TimeInterval) throws {
            self.timeout = timeout
            process.executableURL = executable
            process.arguments = CodexLaunch.appServerArguments()
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let reader = reader
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard data.isEmpty else { return reader.receive(data) }
                handle.readabilityHandler = nil
                reader.finish { [weak self] in
                    guard let self else { return }
                    self.condition.lock(); self.ended = true; self.condition.broadcast(); self.condition.unlock()
                }
            }
            try process.run()
        }

        func send(_ object: [String: Any]) throws {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
        }

        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["id": id, "method": method, "params": params])
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while responses[id] == nil {
                guard !ended, condition.wait(until: deadline) else {
                    throw HarnessSetupError("Codex did not return its model list")
                }
            }
            let response = responses.removeValue(forKey: id)!
            if let error = response["error"] as? [String: Any] {
                throw HarnessSetupError(error["message"] as? String ?? "Codex capability check failed")
            }
            return response["result"] as? [String: Any] ?? [:]
        }

        func stop() {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
    }
}
