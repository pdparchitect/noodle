import Darwin
import Foundation

public enum LocalMacRegistrationStatus: String, Sendable {
    case notRegistered, requiresApproval, enabled, helperMissing, unknown
    public var needsSetup: Bool { self == .notRegistered || self == .requiresApproval }
}

/// Ask the registrar about its own bundled daemon, without opening a window,
/// registering a service, or requesting any permission. Unknown is never treated
/// as a permission denial. The caller's sandbox remains in effect in the child.
public enum LocalMacRegistrationProbe {
    public static func read(executable: URL, timeout: TimeInterval = 5) async -> LocalMacRegistrationStatus {
        let query = RegistrationQuery(executable: executable, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { query.start($0) }
        } onCancel: { query.cancel() }
    }
}

private final class RegistrationQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LocalMac.registration-status")
    private let process = Process()
    private let output = Pipe()
    private let timeout: TimeInterval
    private var deadline: DispatchWorkItem?
    private var continuation: CheckedContinuation<LocalMacRegistrationStatus, Never>?
    private var cancelled = false
    init(executable: URL, timeout: TimeInterval) {
        process.executableURL = executable
        process.arguments = ["--registration-status"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.timeout = timeout
    }
    func start(_ continuation: CheckedContinuation<LocalMacRegistrationStatus, Never>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !self.cancelled else { self.finish(.unknown); return }
            let fd = self.output.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { self.finish(.unknown); return }
            self.process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.queue.async {
                    guard self.continuation != nil else { return }
                    let data = try? self.output.fileHandleForReading.read(upToCount: 256)
                    let value = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finish(process.terminationStatus == 0 ? LocalMacRegistrationStatus(rawValue: value ?? "") ?? .unknown : .unknown)
                }
            }
            do { try self.process.run() }
            catch { self.finish(.unknown); return }
            let deadline = DispatchWorkItem { self.finish(.unknown) }
            self.deadline = deadline
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: deadline)
        }
    }
    func cancel() {
        queue.async { self.cancelled = true; self.finish(.unknown) }
    }
    private func finish(_ status: LocalMacRegistrationStatus) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        continuation.resume(returning: status)
    }
}
