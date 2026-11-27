#if canImport(Glibc)
import Glibc
#elseif os(Windows)
import WindowsPOSIX
#endif
import Foundation
import NoodleCore
import NoodleRuntime

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
        let root = Self.installation(of: program)
        arguments += ["--ro-bind", root.path, root.path]
        arguments += ["--ro-bind", AgentStorageLayout(workspace: workspace).package.path, AgentStorageLayout(workspace: workspace).package.path]
        arguments += ["--bind", workspace.path, workspace.path]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { arguments += ["--setenv", key, value] }
        arguments += ["--chdir", workspace.path, "--", program.path] + command
        return arguments
    }

    /// Where the harness at `program` is installed: the program's folder, or the folder above a `bin`.
    static func installation(of program: URL) -> URL {
        let installation = program.deletingLastPathComponent()
        return installation.lastPathComponent == "bin" ? installation.deletingLastPathComponent() : installation
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
            "HOME": home.path, "PATH": searchPath(home: home), "LANG": "C.UTF-8", "TMPDIR": temporary.path,
            "NOODLE_AGENT_ID": AgentStorageLayout(workspace: workspace).package.lastPathComponent,
            "NOODLE_WORKSPACE": workspace.path,
        ].merging(provider.reportingOffEnvironment) { own, _ in own }
        switch provider {
        case .claudeCode:
            environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude").path
            environment["CLAUDE_CODE_TMPDIR"] = temporary.path
            // The admin updates the harness; a copy updating itself would write where the bot cannot.
            environment["DISABLE_AUTOUPDATER"] = "1"
            environment.merge(ClaudeLaunch.environment) { _, label in label }
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

    /// Where a bot's commands are looked for. On a Mac, where Noodle's own restricted bots look: the developer
    /// tools' come first.
    static func searchPath(home: URL) -> String {
        #if os(macOS)
        RestrictedAgentSandbox.searchPath(home: home)
        #else
        "/usr/local/bin:/usr/bin:/bin"
        #endif
    }
}

#if os(Linux)
extension HarnessSandbox: HarnessIsolation {
    /// bubblewrap itself, with the harness's whole environment in its arguments. Ending it ends everything in
    /// the sandbox.
    public func launch(workspace: URL, program: URL, command: [String], environment: [String: String]) -> HarnessLaunchPlan {
        HarnessLaunchPlan(name: "bubblewrap", executable: bubblewrap,
                          arguments: arguments(workspace: workspace, program: program, command: command, environment: environment),
                          environment: [:], directory: nil, endsGroup: false)
    }
}
#endif

#if os(Linux) || os(macOS) || os(Windows)
/// A bot's harness run by the server itself, in this machine's isolation, in place of the Mac's Agent Host.
/// Its output arrives in order, and it is reported gone only once all of it has.
@MainActor public final class SandboxedHarnessConnection: HarnessRuntimeConnection {
    public var onData: ((Data, Bool) -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onFailure: ((String) -> Void)?
    private let workspace: URL
    private let logins: ServerLogins
    /// A login the bot runs on for now, in place of its own, as when its own ran out.
    private let profileOverride: UUID?
    private let isolation: any HarnessIsolation
    private var launcher: (any HarnessLauncher)?
    private var lock: Int32?
    /// The pipes still open and whether the process ended, before its exit is reported.
    private var open = 0
    private var status: Int32?
    private var stopping = false
    private var stopReplies: [(Bool) -> Void] = []

    public init(workspace: URL, logins: ServerLogins, profileOverride: UUID? = nil,
                isolation: any HarnessIsolation = PlatformHarnessIsolation()) {
        self.workspace = workspace
        self.logins = logins
        self.profileOverride = profileOverride
        self.isolation = isolation
    }

    public func startHarness(provider: HarnessProvider, agentID: UUID, executablePath: String,
                             extendedAccess: Bool, appsEnabled: Bool, sessionID: UUID?, resumeSession: Bool,
                             modelIdentifier: String?, effortIdentifier: String?,
                             reply: @escaping (Int32, String?) -> Void) {
        guard launcher == nil, !stopping else { return reply(0, "Runtime already started or stopping.") }
        do {
            var command = try HarnessSandbox.command(provider: provider, workspace: workspace, sessionID: sessionID,
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
            // The bot's own login, or the one it runs on for now; a copy of it goes into the bot's home.
            guard let login = try logins.profiles.selected(workspace: workspace, provider: provider, override: profileOverride) else {
                throw HarnessSetupError("\(provider.displayName) has no login on this server.")
            }
            let loginHome = logins.profiles.loginHome(login)
            if provider == .codex {
                SharedLogins.shared.refreshCodexIfDue(loginHome: loginHome, executable: program, environment: logins.environment(login))
            }
            // A login the harness refused is not tried again until someone signs in, or a while has passed.
            if RestrictedHarnessStorage.refusedAgain(provider: provider, workspace: workspace, loginHome: loginHome, secret: { _, _ in nil }) {
                throw RestrictedHarnessStorage.refused(provider)
            }
            try logins.prepare(provider, login: login, workspace: workspace)
            command.environment.merge(try isolation.environment(provider: provider, workspace: workspace)) { _, isolation in isolation }
            let plan = try isolation.launch(workspace: workspace, program: program, command: command.arguments,
                                            environment: command.environment)
            // Held until the harness is gone, so no second server runs this bot.
            let lock = try AgentRuntimeLock.acquire(layout: AgentStorageLayout(workspace: workspace))
            let launcher = PlatformHarnessLauncher()
            let identifier: Int32
            do {
                identifier = try launcher.run(plan, received: { [weak self] data, isError in self?.onData?(data, isError) },
                                              closed: { [weak self] in self?.closed() },
                                              exited: { [weak self] status in self?.terminated(status) })
            } catch {
                close(lock)
                throw HarnessSetupError("\(plan.name) could not start: \(error.localizedDescription)")
            }
            self.lock = lock
            open = 2
            self.launcher = launcher
            // A login the bot renews goes back to be shared, and one renewed elsewhere comes to the bot.
            SharedLogins.shared.add(self, provider: provider, workspace: workspace, loginHome: loginHome, secret: { _, _ in nil },
                                    writeSecret: nil, restricted: true, executable: program, environment: logins.environment(login))
            reply(identifier, nil)
        } catch {
            reply(0, error.localizedDescription)
        }
    }

    public func write(_ data: Data) {
        guard !stopping else { return }
        launcher?.write(data)
    }

    /// The harness is asked to end, and ended after 5 seconds if it has not. Its tools end with it: bubblewrap
    /// ends everything in its sandbox, and elsewhere the launcher ends them.
    public func stop(reply: @escaping (Bool) -> Void) {
        guard let launcher, status == nil else { return reply(true) }
        stopReplies.append(reply)
        guard !stopping else { return }
        stopping = true
        launcher.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == nil, let launcher = self.launcher else { return }
                launcher.kill()
            }
        }
    }

    public func invalidate() {
        stopping = true
        if let launcher, status == nil { launcher.kill() }
    }

    private func closed() {
        open -= 1
        finish()
    }

    private func terminated(_ status: Int32) {
        self.status = status
        SharedLogins.shared.remove(self)
        if let lock { close(lock) }
        lock = nil
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
