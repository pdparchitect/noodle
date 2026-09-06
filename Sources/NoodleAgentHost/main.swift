import Darwin
import Foundation
import Security
import NoodleCore
import NoodleAgentBridge

private enum HostPaths {
    static let home: URL = {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { fatalError("No user home") }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }()

    static func executable(_ path: String) throws -> URL {
        // Extended mode supports vendor-signed bundled Codex only, not a mutable
        // PATH shim. A compromised workspace cannot choose an arbitrary program.
        let allowed = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        guard allowed.contains(path) else { throw HostError("Extended access requires Codex bundled with ChatGPT or Codex in Applications.") }
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path else { throw HostError("Codex must not be a symbolic link.") }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple generic and identifier \"codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw HostError("Codex's OpenAI signature could not be verified.")
        }
        return url
    }

    static func workspace(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw HostError("Invalid bot identifier.") }
        let root = home.appendingPathComponent("Library/Containers/com.pdparchitect.noodle/Data/Library/Application Support/Noodle/Agents", isDirectory: true).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: true)
        guard directory.resolvingSymlinksInPath() == directory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("agent.json").path) else {
            throw HostError("The bot workspace is missing or redirected.")
        }
        return directory
    }
}

private struct HostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func isolateProcessGroup() throws {
    // Foundation Process already creates a process group on macOS. setsid()
    // fails with EPERM for its leader, so retain that group or create one
    // explicitly when invoked by a launcher that does not provide it.
    if getpgrp() != getpid(), setpgid(0, 0) != 0 {
        throw HostError("Could not isolate the runtime process group: \(String(cString: strerror(errno)))")
    }
    guard getpgrp() == getpid() else { throw HostError("The runtime process group is not isolated.") }
}

// Fixed startup regression probe: no workspace, credentials, or model access.
if CommandLine.arguments == [CommandLine.arguments[0], "--check-process-group"] {
    do {
        try isolateProcessGroup()
        print("\(getpid()) \(getpgrp())")
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// The child creates a dedicated process group before starting Codex. Disabling
// extended access terminates this group, including ordinary tool descendants.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--codex-child" {
    do {
        let executable = try HostPaths.executable(CommandLine.arguments[2])
        let workspace = try HostPaths.workspace(CommandLine.arguments[3])
        try isolateProcessGroup()
        guard chdir(workspace.path) == 0 else { throw HostError("Could not open the bot workspace: \(String(cString: strerror(errno)))") }
        let strings: [String] = [executable.path, "app-server"]
        var arguments: [UnsafeMutablePointer<CChar>?] = strings.map { value in value.withCString { strdup($0) } }
        arguments.append(nil)
        execv(executable.path, arguments)
        throw HostError("Could not execute Codex.")
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private final class HostSession: NSObject, AgentHostService {
    private weak var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "Noodle.agent-host-session")
    private var process: Process?
    private var input: ProcessInputWriter?
    private var outputs: [FileHandle] = []
    private var stopping = false
    private var stopReplies: [(Bool) -> Void] = []
    private var groupID: Int32?

    init(connection: NSXPCConnection) { self.connection = connection }

    private var client: AgentHostClient? { connection?.remoteObjectProxy as? AgentHostClient }

    func start(agentID: String, executablePath: String, withReply reply: @escaping (Int32, String?) -> Void) {
        queue.async {
            guard self.process == nil, !self.stopping else { reply(0, "Runtime already started or stopping."); return }
            do {
                let executable = try HostPaths.executable(executablePath)
                let workspace = try HostPaths.workspace(agentID)
                let child = Process()
                child.executableURL = Bundle.main.executableURL
                child.arguments = ["--codex-child", executable.path, agentID]
                child.currentDirectoryURL = workspace
                // Do not inherit DYLD, shell startup hooks, or arbitrary app environment.
                child.environment = [
                    "HOME": HostPaths.home.path,
                    "USER": NSUserName(), "LOGNAME": NSUserName(),
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                    "TMPDIR": NSTemporaryDirectory(),
                    "CODEX_HOME": HostPaths.home.appendingPathComponent(".codex").path,
                    "NOODLE_AGENT_ID": agentID.lowercased(), "NOODLE_WORKSPACE": workspace.path
                ]
                let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
                child.standardInput = stdinPipe
                child.standardOutput = stdoutPipe
                child.standardError = stderrPipe
                self.outputs = [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
                for (index, handle) in self.outputs.enumerated() {
                    handle.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                        self?.client?.receive(data, isError: index == 1)
                    }
                }
                child.terminationHandler = { [weak self] child in
                    self?.client?.terminated(child.terminationStatus)
                    self?.stop { _ in }
                }
                try child.run()
                self.process = child
                self.groupID = child.processIdentifier
                self.input = ProcessInputWriter(handle: stdinPipe.fileHandleForWriting)
                reply(child.processIdentifier, nil)
            } catch { reply(0, error.localizedDescription) }
        }
    }

    func write(_ data: Data) {
        queue.async {
            guard !self.stopping, data.count <= 16 * 1_024 * 1_024 else { return }
            self.input?.write(data) { [weak self] _ in self?.stop { _ in } }
        }
    }

    func stop(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            if self.stopping, self.groupID == nil { reply(true); return }
            self.stopReplies.append(reply)
            guard !self.stopping else { return }
            self.stopping = true
            self.input = nil
            guard let id = self.groupID else { self.finishStop(true); return }
            kill(-id, SIGTERM)
            if self.process?.isRunning == true { self.process?.terminate() }
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                if kill(-id, 0) == 0 { kill(-id, SIGKILL) }
                if self.process?.isRunning == true { kill(id, SIGKILL) }
                self.queue.asyncAfter(deadline: .now() + 0.2) {
                    self.outputs.forEach { $0.readabilityHandler = nil }
                    self.outputs = []
                    let stopped = kill(-id, 0) != 0 && self.process?.isRunning != true
                    if stopped { self.groupID = nil; self.process = nil }
                    self.finishStop(stopped)
                }
            }
        }
    }

    private func finishStop(_ stopped: Bool) {
        let replies = stopReplies
        stopReplies = []
        if !stopped { stopping = false }
        replies.forEach { $0(stopped) }
    }

    func checkCompatibility(withReply reply: @escaping (Bool, String) -> Void) {
        queue.async {
            // A fixed, read-only probe: no shell, model, user data, or custom policy.
            let probe = Process(), errors = Pipe()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            probe.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
            probe.standardError = errors
            do {
                try probe.run()
                probe.waitUntilExit()
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                reply(probe.terminationStatus == 0, probe.terminationStatus == 0 ? "Runtime isolation check passed." : detail)
            } catch { reply(false, error.localizedDescription) }
        }
    }
}

private final class HostDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              let requirement = AgentHostIdentity.requirement(for: AgentHostIdentity.application) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: AgentHostService.self)
        connection.remoteObjectInterface = NSXPCInterface(with: AgentHostClient.self)
        let session = HostSession(connection: connection)
        connection.exportedObject = session
        connection.invalidationHandler = { session.stop { _ in } }
        connection.interruptionHandler = { session.stop { _ in } }
        connection.resume()
        return true
    }
}

private let delegate = HostDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
