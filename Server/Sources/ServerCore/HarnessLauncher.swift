#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import NoodleCore

/// Starts a bot's harness from its launch plan, talks to it and ends it. Its output reaches the main actor in
/// the order it was written: `received` with each piece and whether it came from standard error, `closed` once
/// for each of standard output and standard error as it ends, and `exited` once with the harness's status.
@MainActor public protocol HarnessLauncher: AnyObject {
    /// Starts `plan` and returns its process identifier.
    func run(_ plan: HarnessLaunchPlan, received: @escaping @MainActor (Data, Bool) -> Void,
             closed: @escaping @MainActor () -> Void, exited: @escaping @MainActor (Int32) -> Void) throws -> Int32
    func write(_ data: Data)
    /// Asks the harness to end, leaving it a moment to finish.
    func terminate()
    /// Ends the harness and everything it started, at once.
    func kill()
}

#if os(Linux) || os(macOS)
public typealias PlatformHarnessLauncher = ProcessHarnessLauncher

/// A harness run with Foundation's `Process`, on pipes. SIGTERM asks it to end and SIGKILL ends it, sent to it
/// alone or, when its plan says so, to its whole process group, which `Process` gives each child on a Mac.
@MainActor public final class ProcessHarnessLauncher: HarnessLauncher {
    private var process: Process?
    private var input: ProcessInputWriter?
    private var endsGroup = false

    public init() {}

    public func run(_ plan: HarnessLaunchPlan, received: @escaping @MainActor (Data, Bool) -> Void,
                    closed: @escaping @MainActor () -> Void, exited: @escaping @MainActor (Int32) -> Void) throws -> Int32 {
        let child = Process()
        child.executableURL = plan.executable
        child.arguments = plan.arguments
        child.environment = plan.environment
        if let directory = plan.directory { child.currentDirectoryURL = directory }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        for (handle, isError) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if data.isEmpty { closed() } else { received(data, isError) }
                    }
                }
            }
        }
        let endsGroup = plan.endsGroup
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            // Tools the harness left running would keep its output open, and nothing else ends them.
            if endsGroup { send(SIGKILL, to: -child.processIdentifier) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.input = nil
                    exited(status)
                }
            }
        }
        try child.run()
        self.endsGroup = endsGroup
        process = child
        self.input = ProcessInputWriter(handle: input.fileHandleForWriting)
        return child.processIdentifier
    }

    public func write(_ data: Data) {
        input?.write(data) { _ in }
    }

    public func terminate() {
        guard let process else { return }
        send(SIGTERM, to: endsGroup ? -process.processIdentifier : process.processIdentifier)
    }

    public func kill() {
        guard let process else { return }
        send(SIGKILL, to: endsGroup ? -process.processIdentifier : process.processIdentifier)
    }
}

/// Sends `signal` to one process, or to a whole process group when `target` is negative.
private func send(_ signal: Int32, to target: pid_t) {
    _ = kill(target, signal)
}
#endif
