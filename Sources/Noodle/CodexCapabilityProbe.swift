import Darwin
import Foundation
import NoodleCore

@MainActor
final class CodexCapabilityProbe {
    private let executableURL: URL
    private var process: Process?
    private var input: ProcessInputWriter?
    private var output: FileHandle?
    private var errors: FileHandle?
    private lazy var outputReader = JSONLineReader { [weak self] message in
        Task { @MainActor in self?.handle(message) }
    }
    private var completion: ((Result<[HarnessModel], Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func loadModels(completion: @escaping (Result<[HarnessModel], Error>) -> Void) {
        self.completion = completion
        do {
            let child = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            child.executableURL = executableURL
            child.arguments = CodexLaunch.appServerArguments()
            child.standardInput = inputPipe
            child.standardOutput = outputPipe
            child.standardError = errorPipe
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = HostEnvironment.codexHome.path
            child.environment = environment

            let reader = outputReader
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                reader.receive(data)
            }
            // Readiness callbacks must consume bytes, even when diagnostics are
            // discarded. Otherwise this spins continuously and can fill the pipe,
            // preventing the child from completing initialization.
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.completion != nil else { return }
                    self.finish(.failure(ProbeError("Codex capability check exited with status \(child.terminationStatus)")))
                }
            }

            try child.run()
            process = child
            input = ProcessInputWriter(handle: inputPipe.fileHandleForWriting)
            output = outputPipe.fileHandleForReading
            errors = errorPipe.fileHandleForReading
            try send([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": ["name": "noodle", "title": "Noodle", "version": noodleAppVersion],
                    "capabilities": [:]
                ]
            ])
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.finish(.failure(ProbeError("Codex did not return its model list")))
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        completion = nil
        tearDown()
    }

    private func handle(_ message: [String: Any]) {
        guard completion != nil,
              let id = CodexAgentProcess.integerID(message["id"]) else { return }
        if let error = message["error"] as? [String: Any] {
            finish(.failure(ProbeError(error["message"] as? String ?? "Codex capability check failed")))
            return
        }
        if id == 1 {
            do {
                try send(["method": "initialized", "params": [:]])
                try send([
                    "method": "model/list",
                    "id": 2,
                    "params": ["includeHidden": false, "limit": 100]
                ])
            } catch {
                finish(.failure(error))
            }
        } else if id == 2 {
            let result = message["result"] as? [String: Any]
            let data = result?["data"] as? [[String: Any]] ?? []
            let models = data.compactMap(CodexInspection.model)
            guard !models.isEmpty else {
                finish(.failure(ProbeError("Codex returned no available models")))
                return
            }
            finish(.success(models))
        }
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let input else { throw CocoaError(.fileNoSuchFile) }
        input.write(data + Data([0x0A])) { [weak self] error in
            Task { @MainActor in
                self?.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<[HarnessModel], Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        tearDown()
        completion(result)
    }

    private func tearDown() {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        errors = nil
    }

    private struct ProbeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private enum HostEnvironment {
    static var codexHome: URL {
        if let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }
}
