import Darwin
import Foundation

/// Fixed host probes and credential imports. Output is bounded and never used as an error message.
enum OpenCodeCommand {
    static func run(_ executable: URL, arguments: [String], workspace: URL,
                    environment: [String: String], profile: String, input: Data = Data(),
                    timeout: TimeInterval = 30, limit: Int = 4_194_304) throws -> Data {
        func temporaryFile() throws -> FileHandle {
            var name = Array(FileManager.default.temporaryDirectory.appendingPathComponent("noodle-opencode-XXXXXX").path.utf8CString)
            let fd = mkstemp(&name)
            guard fd >= 0 else { throw HarnessSetupError("Could not create an OpenCode inspection pipe.") }
            unlink(name)
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let source = try temporaryFile(), output = try temporaryFile()
        defer { try? source.close(); try? output.close() }
        try source.write(contentsOf: input); try source.seek(toOffset: 0)
        let process = Process(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, executable.path] + arguments
        process.environment = environment
        process.currentDirectoryURL = workspace
        process.standardInput = source; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let pid = process.processIdentifier
        defer { if getpgid(pid) == pid { kill(-pid, SIGKILL) } }
        guard done.wait(timeout: .now() + timeout) == .success else {
            if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            _ = done.wait(timeout: .now() + 2)
            throw HarnessSetupError("OpenCode inspection timed out. Check its installation and sign-in in Terminal, then retry.")
        }
        guard process.terminationStatus == 0 else {
            throw HarnessSetupError("OpenCode inspection failed (exit \(process.terminationStatus)). Install the current v2 native CLI and run opencode auth login in Terminal, then check again.")
        }
        try output.seek(toOffset: 0)
        let data = try output.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw HarnessSetupError("OpenCode returned too much inspection data.") }
        return data
    }
}
