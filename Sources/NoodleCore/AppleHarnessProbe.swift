import Foundation
import Darwin

public enum AppleHarnessProbe {
    /// Called only after the host verifies the bundled executable. Availability
    /// inspection receives no bot workspace and no network permission.
    public static func inspect(executable: URL, application: URL) throws -> AppleHarnessInspection {
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0), capture = Capture()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", AppleAgentSandbox.profile(application: application), executable.path, "--inspect"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": HarnessStorage.userHome.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        output.fileHandleForWriting.closeFile()
        DispatchQueue.global(qos: .utility).async {
            while let bytes = try? output.fileHandleForReading.read(upToCount: 8_192), !bytes.isEmpty { capture.append(bytes) }
            drained.signal()
        }
        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            throw HarnessSetupError("Apple model availability check timed out. Try Check Again.")
        }
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else {
            throw HarnessSetupError("The bundled Apple harness could not inspect model availability.")
        }
        let result = try JSONDecoder().decode(AppleHarnessInspection.self, from: capture.data)
        guard !result.models.isEmpty, Set(result.models.map(\.id)).count == result.models.count,
              result.models.allSatisfy({ FxProtocol.validIdentifier($0.id) }) else {
            throw HarnessSetupError("The Apple harness returned an invalid model catalogue.")
        }
        return result
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data.prefix(max(0, 131_072 - bytes.count))) }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
