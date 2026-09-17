import Foundation
import Darwin

/// The signed host validates the executable before invoking these fixed, read-only probes.
public enum HarnessVersionInspection {
    public static func inspect(provider: HarnessProvider, executable: URL, environment: [String: String]) throws -> HarnessVersionReport {
        let version = try run(executable, arguments: ["--version"], environment: environment)
        var report = HarnessVersionReport(installedVersion: HarnessVersion.parseOutput(version.text)?.text)
        if provider == .muse, executable.lastPathComponent.hasPrefix("muse-bin-") {
            let release = String(executable.lastPathComponent.dropFirst("muse-bin-".count))
            if MuseExecutableTrust.validVersion(release) { report.installedVersion = release }
        }
        if report.installedVersion == nil { report.checkError = "Could not read the installed version." }
        let help = try run(executable, arguments: HarnessVersionPolicy.helpArguments(for: provider), environment: environment)
        if help.truncated {
            report.checkError = "Could not verify command compatibility because the help output was too large."
        } else if help.exitCode == 0, HarnessVersionPolicy.hasUsage(provider: provider, help: help.text) {
            report.compatibilityIssue = HarnessVersionPolicy.compatibilityIssue(provider: provider, help: help.text)
        } else {
            report.compatibilityIssue = HarnessVersionPolicy.startupIssue(provider: provider, text: help.text)
            if report.compatibilityIssue == nil { report.checkError = "Could not verify command compatibility." }
        }
        if provider == .openCode, let text = report.installedVersion, !OpenCodeProtocol.supportsVersion(text) {
            report.compatibilityIssue = "Noodle requires OpenCode v2. Run the v2 installer in Terminal, then check again."
        }
        return report
    }

    private static func run(_ executable: URL, arguments: [String], environment: [String: String]) throws -> (text: String, exitCode: Int32, truncated: Bool) {
        // Claude's native CLI can exit before flushing piped help. A regular file
        // captures the complete output; unlink it immediately so no probe data persists.
        var path = Array(FileManager.default.temporaryDirectory.appendingPathComponent("noodle-harness-probe-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        guard unlink(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let child = Process(), finished = DispatchSemaphore(value: 0)
        child.executableURL = executable
        child.arguments = arguments
        child.environment = environment.merging(["DISABLE_AUTOUPDATER": "1", "OPENCODE_DISABLE_AUTOUPDATE": "true", "NO_COLOR": "1"]) { _, value in value }
        child.currentDirectoryURL = FileManager.default.temporaryDirectory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = output
        child.terminationHandler = { _ in finished.signal() }
        try child.run()
        guard finished.wait(timeout: .now() + 6) == .success else {
            child.terminate()
            if finished.wait(timeout: .now() + 1) != .success { kill(child.processIdentifier, SIGKILL) }
            throw HarnessSetupError("Harness version check timed out. Try Check Again.")
        }
        let limit = 131_072
        try output.seek(toOffset: 0)
        let bytes = try output.read(upToCount: limit + 1) ?? Data()
        return (String(decoding: bytes.prefix(limit), as: UTF8.self), child.terminationStatus, bytes.count > limit)
    }
}
