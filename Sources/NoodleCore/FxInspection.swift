import Foundation

/// Fixed read-only FX commands; never returns raw configuration or credentials.
public enum FxInspection {
    public static func status(executable: URL, environment: [String: String]) throws -> (authenticated: Bool, model: String?) {
        let data = try run(executable: executable, arguments: ["status", "--json"], environment: environment)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "status", let auth = object["auth"] as? String else {
            throw HarnessSetupError("FX returned an unsupported account status.")
        }
        return (!auth.isEmpty && auth != "missing", object["model"] as? String)
    }

    public static func models(executable: URL, environment: [String: String]) throws -> [HarnessModel] {
        let current = try status(executable: executable, environment: environment)
        let data = try run(executable: executable, arguments: ["models", "--json"], environment: environment)
        return try FxProtocol.models(from: data, defaultModel: current.model)
    }

    private static func run(executable: URL, arguments: [String], environment: [String: String]) throws -> Data {
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let capture = BoundedOutput()
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        output.fileHandleForWriting.closeFile()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                capture.append(bytes)
            }
            drained.signal()
        }
        guard finished.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            throw HarnessSetupError("FX inspection timed out. Check FX in Terminal and try again.")
        }
        guard drained.wait(timeout: .now() + 2) == .success else { throw HarnessSetupError("FX inspection output did not close.") }
        guard process.terminationStatus == 0 else { throw HarnessSetupError("FX inspection failed. Check FX in Terminal and try again.") }
        return try capture.result()
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + bytes.count <= 2_000_000 { data.append(bytes) } else { overflow = true }
    }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw HarnessSetupError("FX inspection exceeded its response limit.") }
        return data
    }
}
