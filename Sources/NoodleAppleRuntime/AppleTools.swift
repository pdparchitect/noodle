import Darwin
import Foundation
import NoodleCore
import UniformTypeIdentifiers

/// Tool implementations are independent of the model API so bounds, cancellation,
/// and real filesystem behavior can be tested without making an inference request.
public actor AppleToolContext {
    public let workspace: URL
    private let pageBytes: Int
    private let outputDirectory: URL

    public init(workspace: URL, pageBytes: Int = 3_072) throws {
        let layout = try AgentStorageLayout.containing(workspace)
        self.workspace = layout.workspace
        self.pageBytes = max(1_024, pageBytes)
        outputDirectory = layout.workspace.appendingPathComponent(".noodle/apple/outputs")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func url(_ path: String) throws -> URL {
        try Task.checkCancellation()
        guard !path.isEmpty, !path.utf8.contains(0) else { throw HarnessSetupError("Provide a nonempty file path.") }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path)).standardizedFileURL
    }

    public func read(path: String, offset: Int = 0) throws -> String {
        guard offset >= 0 else { throw HarnessSetupError("The byte offset must be nonnegative.") }
        let file = try url(path)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch { throw HarnessSetupError("Could not read \(file.path): \(error.localizedDescription)") }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            return try present(FileManager.default.contentsOfDirectory(atPath: file.path).sorted().joined(separator: "\n"))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HarnessSetupError("Read a regular file or directory.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: pageBytes) ?? Data()
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let page = try textPage(bytes)
        let end = offset + page.count
        return page.text + "\n[bytes \(offset)..<\(end) of \(size)\(end < size ? "; call read with offset \(end) to continue" : "; end")]"
    }

    /// An image file the model can look at, or nil for anything else.
    func image(path: String) throws -> URL? {
        let file = try url(path)
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 20_971_520 else {
            throw HarnessSetupError("Open images smaller than 20 MiB.")
        }
        return file
    }

    public func write(path: String, content: String, append: Bool = false) throws -> String {
        guard content.utf8.count <= 65_536 else { throw HarnessSetupError("Write at most 64 KiB per call.") }
        let destination = try url(path)
        // Atomic replacement of regular files. The OS sandbox remains the final
        // authority for both native tools and command descendants, including links.
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists {
            let type = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
            guard type == .typeRegular else { throw HarnessSetupError("Write requires a regular file, not a directory or symbolic link.") }
        }
        guard append && exists else {
            try AtomicFile.write(Data(content.utf8), to: destination)
            return "Wrote \(content.utf8.count) bytes to \(destination.path)."
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.write(contentsOf: Data(content.utf8))
        return "Appended \(content.utf8.count) bytes to \(destination.path); it now has \(end + UInt64(content.utf8.count)) bytes."
    }

    public func edit(path: String, old: String, new: String) throws -> String {
        guard !old.isEmpty else { throw HarnessSetupError("Give the exact text to replace.") }
        let file = try url(path)
        let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        guard type == .typeRegular else { throw HarnessSetupError("Edit requires a regular file, not a directory or symbolic link.") }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw HarnessSetupError("\(file.path) is not UTF-8 text.")
        }
        let matches = text.ranges(of: old)
        guard matches.count == 1, let match = matches.first else {
            throw HarnessSetupError(matches.isEmpty
                ? "The text to replace is not in \(file.path). Read the file and copy the exact text."
                : "The text to replace appears \(matches.count) times in \(file.path). Include more of the surrounding text so it appears once.")
        }
        try AtomicFile.write(Data(text.replacingCharacters(in: match, with: new).utf8), to: file)
        return "Replaced the text in \(file.path)."
    }

    public func execute(command: String) async throws -> String {
        try await executeResult(command: command).text
    }

    func executeResult(command: String) async throws -> AppleToolResult {
        try Task.checkCancellation()
        guard !command.isEmpty, command.utf8.count <= 16_384, !command.utf8.contains(0) else {
            throw HarnessSetupError("Provide a command of at most 16 KiB.")
        }
        let result = try await AppleCommand.run(command, workspace: workspace)
        // Failures and summaries usually come last; keep the end in view.
        return AppleToolResult(text: try present("Exit status: \(result.status)\n\(result.output)", keepingEnd: true), failed: result.status != 0)
    }

    private func present(_ value: String, keepingEnd: Bool = false) throws -> String {
        let data = Data(value.utf8)
        guard data.count > pageBytes else { return value }
        let file = outputDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).txt")
        try AtomicFile.write(data, to: file)
        guard keepingEnd else {
            let page = try textPage(Data(data.prefix(pageBytes)))
            return page.text
                + "\n[Full result saved at \(file.path); \(data.count) bytes. Read remaining bytes with read offset \(page.count) before considering this result complete.]"
        }
        let head = try textPage(Data(data.prefix(pageBytes / 2)))
        let tail = textTail(Data(data.suffix(pageBytes / 2)))
        return head.text + "\n[\(data.count - head.count - tail.count) bytes left out here]\n" + tail.text
            + "\n[Full result saved at \(file.path); \(data.count) bytes. Read it from offset \(head.count) for the part left out.]"
    }

    private func textPage(_ bytes: Data) throws -> (text: String, count: Int) {
        if bytes.isEmpty { return ("", 0) }
        for removed in 0...min(3, bytes.count - 1) {
            let page = bytes.prefix(bytes.count - removed)
            if let text = String(data: page, encoding: .utf8) { return (text, page.count) }
        }
        throw HarnessSetupError("This is not UTF-8 text, or the offset splits a character. Use the next offset returned by read.")
    }

    private func textTail(_ bytes: Data) -> (text: String, count: Int) {
        // Start at a character boundary, past any UTF-8 continuation bytes.
        let start = bytes.prefix(3).prefix { $0 & 0xC0 == 0x80 }.count
        let tail = bytes.dropFirst(start)
        return (String(decoding: tail, as: UTF8.self), tail.count)
    }
}

public enum AppleCommand {
    public struct Result: Sendable { public let status: Int32; public let output: String }

    /// Foundation starts a child process group. Track it so turn cancellation,
    /// timeouts, and SIGTERM on the harness also terminate command descendants.
    public static func run(_ command: String, workspace: URL, timeout: TimeInterval = 60) async throws -> Result {
        let job = CommandJob()
        return try await withTaskCancellationHandler {
            try await Task.detached { try job.run(command, workspace: workspace, timeout: timeout) }.value
        } onCancel: { job.cancel() }
    }

    public static func stopAll() { CommandRegistry.shared.stopAll() }
}

private final class CommandRegistry: @unchecked Sendable {
    static let shared = CommandRegistry()
    private let lock = NSLock()
    private var jobs: [UUID: CommandJob] = [:]
    func add(_ job: CommandJob, id: UUID) { lock.lock(); defer { lock.unlock() }; jobs[id] = job }
    func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; jobs[id] = nil }
    func stopAll() {
        lock.lock(); let active = Array(jobs.values); lock.unlock()
        active.forEach { $0.cancel() }
    }
}

private final class CommandJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pid: Int32?
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let pid { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
    }
    func run(_ command: String, workspace: URL, timeout: TimeInterval) throws -> AppleCommand.Result {
        let id = UUID()
        CommandRegistry.shared.add(self, id: id)
        defer { CommandRegistry.shared.remove(id) }
        let child = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = ["-c", AppleCommand.keepingPathsWhole(
            command, paths: [workspace.path, workspace.resolvingSymlinksInPath().path])]
        child.currentDirectoryURL = workspace
        child.environment = ["HOME": workspace.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                             "TMPDIR": workspace.appendingPathComponent(".noodle/tmp").path,
                             "NOODLE_WORKSPACE": workspace.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = pipe
        child.terminationHandler = { _ in finished.signal() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); pid = child.processIdentifier; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer {
            lock.lock()
            // Clean up background processes even after a successful shell exit.
            if let pid { kill(-pid, SIGKILL) }
            pid = nil
            lock.unlock()
            pipe.fileHandleForReading.closeFile()
        }
        pipe.fileHandleForWriting.closeFile()
        let capture = CommandOutput()
        DispatchQueue.global(qos: .utility).async {
            while let data = try? pipe.fileHandleForReading.read(upToCount: 16_384), !data.isEmpty {
                if !capture.append(data) { self.cancel(); break }
            }
            drained.signal()
        }
        if finished.wait(timeout: .now() + min(max(timeout, 0.1), 60)) != .success {
            cancel()
            _ = finished.wait(timeout: .now() + 2)
            throw HarnessSetupError("Command exceeded its time limit and was stopped.")
        }
        // A background process can retain the pipe after its shell has finished.
        kill(-child.processIdentifier, SIGKILL)
        _ = drained.wait(timeout: .now() + 2)
        if capture.overflow { throw HarnessSetupError("Command output exceeded 1 MiB and was stopped.") }
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        return .init(status: child.terminationStatus, output: capture.text)
    }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceeded = false
    func append(_ bytes: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if data.count + bytes.count > 1_048_576 { exceeded = true; return false }
        data.append(bytes); return true
    }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
