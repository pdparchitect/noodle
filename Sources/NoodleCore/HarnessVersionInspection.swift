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
        if help.exitCode == 0, help.text.lowercased().contains("usage:") {
            report.compatibilityIssue = HarnessVersionPolicy.compatibilityIssue(provider: provider, help: help.text)
        } else {
            report.compatibilityIssue = HarnessVersionPolicy.startupIssue(provider: provider, text: help.text)
            if report.compatibilityIssue == nil { report.checkError = "Could not verify command compatibility." }
        }
        return report
    }

    private static func run(_ executable: URL, arguments: [String], environment: [String: String]) throws -> (text: String, exitCode: Int32) {
        let child = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        child.executableURL = executable
        child.arguments = arguments
        child.environment = environment.merging(["DISABLE_AUTOUPDATER": "1", "NO_COLOR": "1"]) { _, value in value }
        child.currentDirectoryURL = FileManager.default.temporaryDirectory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = pipe
        let capture = Capture()
        child.terminationHandler = { _ in finished.signal() }
        try child.run()
        pipe.fileHandleForWriting.closeFile()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let bytes = pipe.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                capture.append(bytes)
            }
            drained.signal()
        }
        guard finished.wait(timeout: .now() + 6) == .success else {
            child.terminate()
            if finished.wait(timeout: .now() + 1) != .success { kill(child.processIdentifier, SIGKILL) }
            throw HarnessSetupError("Harness version check timed out. Try Check Again.")
        }
        guard drained.wait(timeout: .now() + 1) == .success else { throw HarnessSetupError("Harness version output did not close.") }
        return (capture.text, child.terminationStatus)
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data.prefix(max(0, 131_072 - bytes.count))) }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }
}
