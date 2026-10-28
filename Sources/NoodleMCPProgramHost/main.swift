import Darwin
import Foundation
import NoodleCore

/// One connection from Noodle. launchd starts this process without the app sandbox.
private final class HostSession: NSObject, MCPProgramHostService {
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    private var parentWatch: DispatchSourceTimer?
    private let parentPID: Int32

    init(parentPID: Int32) {
        self.parentPID = parentPID
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.parentPID <= 1 || kill(self.parentPID, 0) != 0 { self.stopAll() }
        }
        timer.resume()
        parentWatch = timer
    }

    func launch(executable: String, arguments: [String], environment: [String: String], directory: String,
                withReply reply: @escaping (Int32, FileHandle?, FileHandle?, FileHandle?, String?) -> Void) {
        do {
            let started = try start(executable: executable, arguments: arguments, environment: environment, directory: directory)
            reply(started.pid, started.input, started.output, started.error, nil)
        } catch {
            reply(0, nil, nil, nil, error.localizedDescription)
        }
    }

    func stop(_ processIdentifier: Int32) { halt(processIdentifier) }

    func stopAll() {
        lock.lock()
        let ids = Array(processes.keys)
        lock.unlock()
        for id in ids { halt(id) }
        parentWatch?.cancel()
        parentWatch = nil
    }

    private func start(executable: String, arguments: [String], environment: [String: String], directory: String) throws -> (pid: Int32, input: FileHandle, output: FileHandle, error: FileHandle) {
        guard executable.hasPrefix("/"), !executable.contains("\n"),
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw MCPConnectionError.message("The program has to be an executable file.")
        }
        var directoryIsFolder: ObjCBool = false
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &directoryIsFolder),
              directoryIsFolder.boolValue else {
            throw MCPConnectionError.message("The program's folder is not available.")
        }
        if MCPProgramHostLaunch.refusesAppSandbox(containerIdentifier: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]) {
            throw MCPConnectionError.message("The program host is inside the app sandbox, so it will not start the program.")
        }
        let command = MCPProgramHostLaunch.command(executable: executable, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = clean(environment)
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let pid = process.processIdentifier
        _ = setpgid(pid, pid)
        lock.lock()
        processes[pid] = process
        lock.unlock()
        return (pid, inputPipe.fileHandleForWriting, outputPipe.fileHandleForReading, errorPipe.fileHandleForReading)
    }

    /// PATH, language, account, and temporary directory come from the fixed set. Other names are the consented values.
    private func clean(_ supplied: [String: String]) -> [String: String] {
        let user = supplied["USER"] ?? NSUserName()
        let temporary = supplied["TMPDIR"] ?? NSTemporaryDirectory()
        var environment = MCPProgramRecord.minimalEnvironment(user: user, temporaryDirectory: temporary)
        let reserved: Set<String> = ["PATH", "TMPDIR", "LANG", "USER", "LOGNAME", "HOME"]
        for (name, value) in supplied where !reserved.contains(name) {
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            environment[name] = value
        }
        environment.removeValue(forKey: "HOME")
        return environment
    }

    private func halt(_ pid: Int32) {
        lock.lock()
        let process = processes.removeValue(forKey: pid)
        lock.unlock()
        guard let process else { return }
        if process.isRunning {
            kill(-pid, SIGTERM)
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(-pid, SIGKILL) }
    }
}

private final class HostDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              let requirement = MCPProgramHostIdentity.requirement(for: MCPProgramHostIdentity.application) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: MCPProgramHostService.self)
        let session = HostSession(parentPID: connection.processIdentifier)
        connection.exportedObject = session
        connection.invalidationHandler = { session.stopAll() }
        connection.interruptionHandler = { session.stopAll() }
        connection.resume()
        return true
    }
}

private let delegate = HostDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
