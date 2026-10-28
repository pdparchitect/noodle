import Darwin
import Foundation
import MCP
import NoodleCore
import System

/// One launched program. Standard output is checked before any MCP client reads it.
public final class MCPProgramSession: @unchecked Sendable {
    public let processIdentifier: Int32
    private let process: Process?
    private let remoteStop: (@Sendable () -> Void)?
    private let input: FileHandle
    private let validated: Pipe
    private let secrets: [String]
    private let lock = NSLock()
    private var errorText = ""
    private var stdoutBuffer = Data()
    private var protocolFailure: String?
    private var stopped = false
    public private(set) var wasStopped = false
    private var sawMessage = false
    private let stderrLimit = 16_384
    private var parentWatch: DispatchSourceTimer?

    public init(launch: MCPProgramLaunch, parentProcessID: Int32? = nil, parentPollSeconds: TimeInterval = 1) throws {
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.workingDirectory
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        self.process = process
        self.remoteStop = nil
        self.processIdentifier = process.processIdentifier
        self.input = inputPipe.fileHandleForWriting
        self.validated = Pipe()
        self.secrets = launch.secrets
        watch(output: outputPipe.fileHandleForReading, error: errorPipe.fileHandleForReading)
        if let parentProcessID {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + parentPollSeconds, repeating: parentPollSeconds)
            timer.setEventHandler { [weak self] in
                guard MCPProgramRecord.parentHasExited(parentProcessID) else { return }
                self?.stop()
            }
            timer.resume()
            parentWatch = timer
        }
    }

    /// Pipes from a program the unsandboxed host already started. This process does not spawn it.
    public init(processIdentifier: Int32, input: FileHandle, output: FileHandle, error: FileHandle,
                secrets: [String], stopRemote: @escaping @Sendable () -> Void) {
        self.process = nil
        self.remoteStop = stopRemote
        self.processIdentifier = processIdentifier
        self.input = input
        self.validated = Pipe()
        self.secrets = secrets
        watch(output: output, error: error)
    }

    private func watch(output: FileHandle, error: FileHandle) {
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.finishStdout()
                return
            }
            self?.acceptStdout(data)
        }
        error.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.acceptStderr(data)
        }
    }

    /// File descriptors for an MCP stdio client: validated program output, and the program's input.
    public func transportDescriptors() -> (input: FileDescriptor, output: FileDescriptor) {
        (FileDescriptor(rawValue: validated.fileHandleForReading.fileDescriptor),
         FileDescriptor(rawValue: input.fileDescriptor))
    }

    public func hasMessage() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sawMessage
    }

    public func standardError() -> String {
        lock.lock(); defer { lock.unlock() }
        return errorText
    }

    public func protocolError() -> String? {
        lock.lock(); defer { lock.unlock() }
        return protocolFailure
    }

    public var isRunning: Bool {
        if let process { return process.isRunning }
        return kill(processIdentifier, 0) == 0
    }

    /// A start that never writes an MCP message is closed. Returns whether this call stopped it.
    public func stopIfHung(after seconds: TimeInterval) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        if hasMessage() || !isRunning { return false }
        stop()
        return true
    }

    public func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        wasStopped = true
        lock.unlock()
        parentWatch?.cancel()
        parentWatch = nil
        let pid = processIdentifier
        if let remoteStop {
            remoteStop()
        }
        if let process, process.isRunning {
            kill(-pid, SIGTERM)
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(-pid, SIGKILL) }
        } else if remoteStop != nil {
            kill(-pid, SIGTERM)
        }
        try? input.close()
        try? validated.fileHandleForWriting.close()
    }

    private func acceptStdout(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        var lines: [Data] = []
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = stdoutBuffer[..<newline]
            stdoutBuffer = Data(stdoutBuffer[(newline + 1)...])
            if !line.isEmpty { lines.append(Data(line)) }
        }
        lock.unlock()
        for line in lines {
            let text = String(decoding: line, as: UTF8.self)
            do {
                _ = try MCPProgramRecord.mcpMessageLine(text)
                lock.lock()
                sawMessage = true
                lock.unlock()
                var output = line
                output.append(UInt8(ascii: "\n"))
                try validated.fileHandleForWriting.write(contentsOf: output)
            } catch {
                failProtocol(error.localizedDescription)
                return
            }
        }
    }

    private func finishStdout() {
        lock.lock()
        let trailing = stdoutBuffer
        stdoutBuffer.removeAll()
        lock.unlock()
        if !trailing.isEmpty { acceptStdout(trailing + Data([UInt8(ascii: "\n")])) }
    }

    private func acceptStderr(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let redacted = MCPProgramRecord.redact(text, secrets: secrets)
        lock.lock()
        let room = stderrLimit - errorText.utf8.count
        if room > 0 {
            errorText += String(redacted.prefix(room))
        }
        lock.unlock()
    }

    private func failProtocol(_ message: String) {
        lock.lock()
        if protocolFailure == nil { protocolFailure = message }
        lock.unlock()
        stop()
    }
}

public struct MCPProgramLaunch: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var secrets: [String]
    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL, secrets: [String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.secrets = secrets
    }
}
