#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WindowsPOSIX
import CWindowsSandbox
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
#elseif os(Windows)
public typealias PlatformHarnessLauncher = WindowsHarnessLauncher

/// A harness started in its plan's sandbox, inside a job that ends everything it started. Windows has no
/// gentler way to ask a process to end, so ending it, whether asked or forced, ends the job; so does the harness
/// exiting, which would otherwise leave its tools holding its output open.
@MainActor public final class WindowsHarnessLauncher: HarnessLauncher {
    /// The child's handles, which belong to whichever thread is using them.
    private struct Handles: @unchecked Sendable {
        var input, output, errors, process, job, console, consoleInput: UnsafeMutableRawPointer?
    }

    private var handles: Handles?
    private let writer = DispatchQueue(label: "com.pdparchitect.noodled.harness-input")

    public init() {}

    public func run(_ plan: HarnessLaunchPlan, received: @escaping @MainActor (Data, Bool) -> Void,
                    closed: @escaping @MainActor () -> Void, exited: @escaping @MainActor (Int32) -> Void) throws -> Int32 {
        guard let name = plan.sandbox else { throw HarnessSetupError("\(plan.name) has no sandbox to run in.") }
        let sid = try RestrictedTokenSandbox.bot(name)
        defer { sandbox_free_sid(sid) }
        var child = sandbox_child()
        let error = RestrictedTokenSandbox.spawn(plan, sid: sid, into: &child)
        guard error == 0 else { throw HarnessSetupError("Windows error \(error)") }
        let handles = Handles(input: child.input, output: child.output, errors: child.errors, process: child.process, job: child.job,
                              console: child.console, consoleInput: child.consoleInput)
        self.handles = handles
        for (pipe, isError) in [(handles.output, false), (handles.errors, true)] {
            let source = Handles(input: nil, output: pipe, errors: nil, process: nil, job: nil, console: nil, consoleInput: nil)
            Thread {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = sandbox_read(source.output, &buffer, UInt32(buffer.count))
                    let data = count > 0 ? Data(buffer[..<Int(count)]) : Data()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { data.isEmpty ? closed() : received(data, isError) }
                    }
                    if data.isEmpty { break }
                }
                sandbox_close(source.output)
            }.start()
        }
        Thread {
            let status = sandbox_wait(handles.process)
            sandbox_end(handles.job, status)
            sandbox_close(handles.process)
            sandbox_close_console(handles.console, handles.consoleInput)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { exited(Int32(bitPattern: status)) }
            }
        }.start()
        return Int32(bitPattern: child.identifier)
    }

    public func write(_ data: Data) {
        guard let handles else { return }
        writer.async {
            var offset = 0
            while offset < data.count {
                let written = data[offset...].withUnsafeBytes { sandbox_write(handles.input, $0.baseAddress, UInt32($0.count)) }
                guard written > 0 else { return }
                offset += Int(written)
            }
        }
    }

    public func terminate() { end(1) }

    public func kill() { end(137) }

    private func end(_ code: UInt32) {
        guard let handles else { return }
        sandbox_end(handles.job, code)
        writer.async {
            sandbox_close(handles.input)
            sandbox_close(handles.job)
        }
        self.handles = nil
    }
}
#endif
