#if canImport(Glibc)
import Glibc
#endif
import Foundation
import NoodleCore
#if os(Linux)
import NoodleRuntime
#endif

/// How a bot's harness runs under bubblewrap: the system read-only, the harness's installation read-only,
/// the bot's package read-only and its workspace writable. The rest of the server's data, the admin's home
/// and every other bot are not there at all. The network is shared; nothing else is.
public struct HarnessSandbox: Sendable {
    public var bubblewrap: URL

    public init(bubblewrap: URL = URL(fileURLWithPath: "/usr/bin/bwrap")) {
        self.bubblewrap = bubblewrap
    }

    /// What in `/etc` programs need to resolve names, check certificates, know the time and find users.
    private static let settings = ["resolv.conf", "hosts", "nsswitch.conf", "gai.conf", "host.conf", "passwd", "group",
                                   "localtime", "ssl", "ca-certificates", "pki", "alternatives", "ld.so.cache", "ld.so.conf",
                                   "ld.so.conf.d", "mime.types"]

    /// bubblewrap's arguments for running `program`, already resolved, with `command` in `workspace`.
    func arguments(workspace: URL, program: URL, command: [String], environment: [String: String]) -> [String] {
        var arguments = ["--unshare-all", "--share-net", "--die-with-parent", "--new-session", "--cap-drop", "ALL", "--clearenv",
                         "--ro-bind", "/usr", "/usr"]
        // Merged-/usr systems link these into /usr; older ones keep them as folders.
        for name in ["bin", "sbin", "lib", "lib32", "lib64", "libx32"] {
            let path = "/" + name
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                arguments += ["--symlink", target, path]
            } else {
                arguments += ["--ro-bind-try", path, path]
            }
        }
        arguments += ["--ro-bind-try", "/opt", "/opt"]
        for name in Self.settings { arguments += ["--ro-bind-try", "/etc/" + name, "/etc/" + name] }
        arguments += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
        let installation = program.deletingLastPathComponent()
        let root = installation.lastPathComponent == "bin" ? installation.deletingLastPathComponent() : installation
        arguments += ["--ro-bind", root.path, root.path]
        arguments += ["--ro-bind", AgentStorageLayout(workspace: workspace).package.path, AgentStorageLayout(workspace: workspace).package.path]
        arguments += ["--bind", workspace.path, workspace.path]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { arguments += ["--setenv", key, value] }
        arguments += ["--chdir", workspace.path, "--", program.path] + command
        return arguments
    }

    #if os(Linux)
    /// Why bubblewrap cannot make a bot's sandbox on this machine, or nil when it can: a bot's whole sandbox
    /// is made around a program that does nothing.
    public func problem() -> String? {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodled-check-\(UUID().uuidString)/bot/workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent().deletingLastPathComponent()) }
        let probe = Process()
        probe.executableURL = bubblewrap
        probe.arguments = arguments(workspace: workspace, program: URL(fileURLWithPath: "/bin/true").resolvingSymlinksInPath(),
                                    command: [], environment: [:])
        let errors = Pipe()
        probe.standardError = errors
        probe.standardOutput = FileHandle.nullDevice
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try probe.run()
        } catch {
            return "bubblewrap is not installed at \(bubblewrap.path); install the bubblewrap package."
        }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        probe.waitUntilExit()
        guard probe.terminationStatus != 0 else { return nil }
        return "bubblewrap cannot make a sandbox for bots here (\(detail.isEmpty ? "status \(probe.terminationStatus)" : detail)). "
            + "noodled needs a Linux machine or virtual machine, or a privileged container."
    }
    #endif

    /// The bot's private home, where its harness keeps settings and its login.
    static func home(workspace: URL) -> URL { workspace.appendingPathComponent(".noodle/home", isDirectory: true) }

    /// What runs for `provider`: its fixed arguments and its whole environment.
    static func command(provider: HarnessProvider, workspace: URL, sessionID: UUID?, resumeSession: Bool,
                        model: String?, effort: String?) throws -> (arguments: [String], environment: [String: String]) {
        let home = home(workspace: workspace)
        let temporary = workspace.appendingPathComponent(".noodle/tmp", isDirectory: true)
        var environment = [
            "HOME": home.path, "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8", "TMPDIR": temporary.path,
            "NOODLE_AGENT_ID": AgentStorageLayout(workspace: workspace).package.lastPathComponent,
            "NOODLE_WORKSPACE": workspace.path,
        ]
        switch provider {
        case .claudeCode:
            environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude").path
            environment["CLAUDE_CODE_TMPDIR"] = temporary.path
            // The admin updates the harness; a copy updating itself would write where the bot cannot.
            environment["DISABLE_AUTOUPDATER"] = "1"
            let arguments = try ClaudeLaunch.arguments(sessionID: sessionID, resumeSession: resumeSession, model: model,
                                                       effort: effort, restricted: true)
            return (arguments, environment)
        case .codex:
            environment["CODEX_HOME"] = home.appendingPathComponent(".codex").path
            return (CodexLaunch.appServerArguments(), environment)
        default:
            throw HarnessSetupError("noodled runs only Claude Code and Codex.")
        }
    }
}

#if os(Linux)
/// A bot's harness run by the server itself, under bubblewrap, in place of the Mac's Agent Host.
/// Its output arrives in order, and it is reported gone only once all of it has.
@MainActor public final class SandboxedHarnessConnection: HarnessRuntimeConnection {
    public var onData: ((Data, Bool) -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onFailure: ((String) -> Void)?
    private let workspace: URL
    private let sandbox: HarnessSandbox
    private var process: Process?
    private var input: ProcessInputWriter?
    private var lock: Int32?
    /// The pipes still open and whether the process ended, before its exit is reported.
    private var open = 0
    private var status: Int32?
    private var stopping = false
    private var stopReplies: [(Bool) -> Void] = []

    public init(workspace: URL, sandbox: HarnessSandbox = HarnessSandbox()) {
        self.workspace = workspace
        self.sandbox = sandbox
    }

    public func startHarness(provider: HarnessProvider, agentID: UUID, executablePath: String,
                             extendedAccess: Bool, appsEnabled: Bool, sessionID: UUID?, resumeSession: Bool,
                             modelIdentifier: String?, effortIdentifier: String?,
                             reply: @escaping (Int32, String?) -> Void) {
        guard process == nil, !stopping else { return reply(0, "Runtime already started or stopping.") }
        do {
            let command = try HarnessSandbox.command(provider: provider, workspace: workspace, sessionID: sessionID,
                                                     resumeSession: resumeSession, model: modelIdentifier, effort: effortIdentifier)
            let program = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: program.path) else {
                throw HarnessSetupError("\(provider.displayName) is not at \(executablePath).")
            }
            let home = HarnessSandbox.home(workspace: workspace)
            for folder in [home.appendingPathComponent(provider == .codex ? ".codex" : ".claude"),
                           workspace.appendingPathComponent(".noodle/tmp")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            // Held until the harness is gone, so no second server runs this bot.
            let lock = try AgentRuntimeLock.acquire(layout: AgentStorageLayout(workspace: workspace))
            let child = Process()
            child.executableURL = sandbox.bubblewrap
            child.arguments = sandbox.arguments(workspace: workspace, program: program,
                                                command: command.arguments, environment: command.environment)
            child.environment = [:]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            child.standardInput = input
            child.standardOutput = output
            child.standardError = errors
            for (handle, isError) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
                handle.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if data.isEmpty { self.closed() } else { self.onData?(data, isError) }
                        }
                    }
                }
            }
            child.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated(status) } }
            }
            do { try child.run() } catch {
                close(lock)
                throw HarnessSetupError("bubblewrap could not start: \(error.localizedDescription)")
            }
            self.lock = lock
            open = 2
            process = child
            self.input = ProcessInputWriter(handle: input.fileHandleForWriting)
            reply(child.processIdentifier, nil)
        } catch {
            reply(0, error.localizedDescription)
        }
    }

    public func write(_ data: Data) {
        guard !stopping else { return }
        input?.write(data) { _ in }
    }

    /// bubblewrap ends everything in the sandbox when it goes, so ending it ends the harness and its tools.
    public func stop(reply: @escaping (Bool) -> Void) {
        guard let process, status == nil else { return reply(true) }
        stopReplies.append(reply)
        guard !stopping else { return }
        stopping = true
        kill(process.processIdentifier, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == nil, let process = self.process else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    public func invalidate() {
        stopping = true
        if let process, status == nil { kill(process.processIdentifier, SIGKILL) }
    }

    private func closed() {
        open -= 1
        finish()
    }

    private func terminated(_ status: Int32) {
        self.status = status
        if let lock { close(lock) }
        lock = nil
        input = nil
        finish()
    }

    private func finish() {
        guard let status, open == 0 else { return }
        if stopping {
            let replies = stopReplies
            stopReplies = []
            replies.forEach { $0(true) }
        } else {
            onExit?(status)
        }
    }
}
#endif
