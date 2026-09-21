import Foundation
import Darwin

/// One fixed read-only command: the model listing, which also answers whether
/// the account is signed in. Noodle receives only the sanitized result.
public enum AntigravityInspection {
    /// `managed` is the copy Noodle installed, already verified by the caller,
    /// and is used only when the user has no installation of their own.
    public static func inspect(home: URL, environment: [String: String], managed: URL? = nil) throws -> AntigravityInspectionResult {
        let path = home.appendingPathComponent(".local/bin/agy").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            guard let managed else { return .init(executablePath: nil, authenticated: false, models: []) }
            return try inspect(executable: managed, installationPath: managed.path, environment: environment)
        }
        let executable = try AntigravityExecutableTrust.executable(at: path, home: home)
        return try inspect(executable: executable, installationPath: path, environment: environment)
    }

    /// A profile's sign-in, read with that profile's environment. The caller has verified `executable`.
    public static func authenticated(executable: URL, environment: [String: String]) throws -> Bool {
        try inspect(executable: executable, installationPath: executable.path, environment: environment).authenticated
    }

    // Exercise the command with a local fixture; the public entry point always verifies the installation.
    static func inspect(executable: URL, installationPath: String, environment: [String: String],
                        timeout: TimeInterval = 40) throws -> AntigravityInspectionResult {
        // Regular files: a read can never wait on a helper the CLI left holding a pipe.
        let process = Process(), output = try scratchFile(), errors = try scratchFile(), finished = DispatchSemaphore(value: 0)
        defer { try? output.close(); try? errors.close() }
        process.executableURL = executable
        process.arguments = ["models"]
        process.environment = environment.merging(["AGY_CLI_DISABLE_AUTO_UPDATE": "true", "NO_COLOR": "1"]) { _, value in value }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            throw HarnessSetupError("Antigravity inspection timed out. Check agy in Terminal and try again.")
        }
        let listing = String(decoding: try contents(output, limit: 262_144), as: UTF8.self)
        let models = process.terminationStatus == 0 ? AntigravityProtocol.models(from: listing) : []
        if !models.isEmpty { return .init(executablePath: installationPath, authenticated: true, models: models) }
        let detail = String(decoding: try contents(errors, limit: 16_384), as: UTF8.self)
        guard AntigravityProtocol.isAuthenticationFailure(detail) else {
            throw HarnessSetupError("Antigravity inspection failed. Check agy in Terminal and try again.")
        }
        return .init(executablePath: installationPath, authenticated: false, models: [])
    }

    private static func contents(_ file: FileHandle, limit: Int) throws -> Data {
        try file.seek(toOffset: 0)
        return try file.read(upToCount: limit) ?? Data()
    }

    /// Unlinked at once, so nothing the CLI printed outlives the inspection.
    private static func scratchFile() throws -> FileHandle {
        var path = Array(FileManager.default.temporaryDirectory.appendingPathComponent("noodle-antigravity-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0, unlink(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
