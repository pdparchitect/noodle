import Darwin
import Foundation
import Security
import NoodleCore
import NoodleAgentBridge

private enum HostPaths {
    static var application: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var apple: URL { application.appendingPathComponent("Contents/Helpers/NoodleAppleAgent") }
    static let home: URL = {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { fatalError("No user home") }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }()

    static func executable(_ path: String, provider: HarnessProvider) throws -> URL {
        switch provider {
        case .apple:
            guard let requirement = AgentHostIdentity.requirement(for: AgentHostIdentity.application + ".apple-agent") else {
                throw HostError("Apple harness signing configuration is missing.")
            }
            return try AppleExecutableTrust.executable(at: path, application: application, requirement: requirement)
        case .codex: return try CodexExecutableTrust.executable(at: path, home: home)
        case .claudeCode: return try ClaudeExecutableTrust.executable(at: path, home: home)
        case .fx: return try FxExecutableTrust.executable(at: path, home: home)
        case .grokBuild: return try GrokExecutableTrust.executable(at: path, home: home)
        case .muse: return try MuseExecutableTrust.executable(at: path, home: home)
        }
    }

    static func workspace(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw HostError("Invalid bot identifier.") }
        let root = home.appendingPathComponent("Library/Containers/\(AgentHostIdentity.application)/Data/Library/Application Support/Noodle/Agents", isDirectory: true).resolvingSymlinksInPath()
        let layout = AgentStorageLayout(package: root.appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: true))
        try layout.validate()
        return layout.workspace
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

// The child creates a dedicated process group before starting the harness. Disabling
// extended access terminates this group, including ordinary tool descendants.
if CommandLine.arguments.count == 10, CommandLine.arguments[1] == "--harness-child" {
    do {
        guard let provider = HarnessProvider(rawValue: CommandLine.arguments[2]) else {
            throw HostError("Unsupported harness.")
        }
        let executable = try HostPaths.executable(CommandLine.arguments[3], provider: provider)
        let workspace = try HostPaths.workspace(CommandLine.arguments[4])
        let sessionID = CommandLine.arguments[5].isEmpty ? nil : UUID(uuidString: CommandLine.arguments[5])
        let resumeSession = CommandLine.arguments[6] == "1"
        let model = CommandLine.arguments[7].isEmpty ? nil : CommandLine.arguments[7]
        let effort = CommandLine.arguments[8].isEmpty ? nil : CommandLine.arguments[8]
        let restricted = CommandLine.arguments[9] == "restricted"
        guard restricted || CommandLine.arguments[9] == "autonomous",
              !restricted || provider.supportsRestrictedAccess else { throw HostError("Unsupported runtime access mode.") }
        try isolateProcessGroup()
        guard chdir(workspace.path) == 0 else { throw HostError("Could not open the bot workspace: \(String(cString: strerror(errno)))") }
        var strings: [String]
        switch provider {
        case .apple:
            guard effort == nil, model.map(FxProtocol.validIdentifier) ?? true else { throw HostError("Unsupported Apple model configuration.") }
            strings = [executable.path, "--serve"]
        case .muse:
            guard model.map(FxProtocol.validIdentifier) ?? true,
                  effort.map(MuseProtocol.efforts.contains) ?? true else { throw HostError("Unsupported Muse model or effort.") }
            // Restricted runs receive the mandatory outer policy below; do not
            // try to stack Muse's shell sandbox inside the process sandbox.
            strings = [executable.path, "serve", "--disable-sandbox", "--trust-workspace"]
        case .codex:
            strings = [executable.path, "app-server"]
        case .fx:
            guard effort == nil, model.map(FxProtocol.validIdentifier) ?? true else { throw HostError("Unsupported FX model or effort.") }
            strings = [executable.path, "acp"]
            if let model { strings += ["--model", model] }
        case .grokBuild:
            guard model.map(FxProtocol.validIdentifier) ?? true,
                  effort.map(GrokProtocol.efforts.contains) ?? true else { throw HostError("Unsupported Grok Build model or effort.") }
            strings = [executable.path, "agent", "--no-leader"]
            if let model { strings += ["--model", model] }
            if let effort { strings += ["--reasoning-effort", effort] }
            strings += ["stdio"]
        case .claudeCode:
            guard let sessionID else { throw HostError("Claude Code requires a valid session identifier.") }
            if let model {
                guard ClaudeCodeCapabilities.isValidModelIdentifier(model) else {
                    throw HostError("Unsupported Claude Code model identifier.")
                }
            }
            if let effort, !["low", "medium", "high", "xhigh", "max"].contains(effort) {
                throw HostError("Unsupported Claude Code effort.")
            }
            strings = [
                executable.path, "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--permission-mode", "bypassPermissions",
                "--permission-prompts", "none",
                resumeSession ? "--resume" : "--session-id", sessionID.uuidString.lowercased()
            ]
            if let model { strings += ["--model", model] }
            if let effort { strings += ["--effort", effort] }
        }
        if restricted {
            let layout = AgentStorageLayout(workspace: workspace)
            let repository = layout.package.deletingLastPathComponent().deletingLastPathComponent()
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: HostPaths.home)
            let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
            let codexHome = privateHome.appendingPathComponent(".codex", isDirectory: true)
            let temporary = workspace.appendingPathComponent(".noodle/tmp", isDirectory: true)
            // Only fixed paths derived by this host enter the profile. The XPC
            // caller cannot supply policy text, writable roots, or a command.
            let profile: String
            switch provider {
            case .apple:
                profile = AppleAgentSandbox.profile(application: HostPaths.application, workspace: workspace, repository: repository)
            case .codex:
                profile = RestrictedAgentSandbox.profile(workspace: workspace, repository: repository,
                    codexHome: codexHome, executableDirectory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                    application: HostPaths.application, temporary: temporary)
            case .fx, .grokBuild, .muse:
                profile = try RestrictedAgentSandbox.profile(provider: provider, workspace: workspace, repository: repository,
                    home: HostPaths.home, executable: executable, application: HostPaths.application, temporary: temporary)
            default: throw HostError("Unsupported restricted harness.")
            }
            setenv("TMPDIR", temporary.path, 1)
            setenv("TMPPREFIX", temporary.appendingPathComponent("zsh").path, 1)
            setenv("CODEX_HOME", codexHome.path, 1)
            if provider == .fx || provider == .grokBuild || provider == .muse {
                for (key, value) in try RestrictedAgentSandbox.environment(provider: provider, home: HostPaths.home, workspace: workspace) {
                    setenv(key, value, 1)
                }
            } else { setenv("HOME", privateHome.path, 1) }
            strings = ["/usr/bin/sandbox-exec", "-p", profile] + strings
        }
        var arguments: [UnsafeMutablePointer<CChar>?] = strings.map { value in value.withCString { strdup($0) } }
        arguments.append(nil)
        execv(strings[0], arguments)
        throw HostError("Could not execute \(provider.displayName).")
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private final class HostSession: NSObject, AgentHostService {
    private weak var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "Noodle.agent-host-session")
    private var process: Process?
    private var accountProcess: Process?
    private var input: ProcessInputWriter?
    private var outputs: [FileHandle] = []
    private var stopping = false
    private var stopReplies: [(Bool) -> Void] = []
    private var groupID: Int32?
    private var loginOutput: FileHandle?
    private var loginText = ""
    private var loginChallengeSent = false

    init(connection: NSXPCConnection) { self.connection = connection }

    private var client: AgentHostClient? { connection?.remoteObjectProxy as? AgentHostClient }

    func start(
        harnessIdentifier: String,
        agentID: String,
        executablePath: String,
        sessionID: String?,
        resumeSession: Bool,
        modelIdentifier: String?,
        effortIdentifier: String?,
        withReply reply: @escaping (Int32, String?) -> Void
    ) {
        startRuntime(harnessIdentifier: harnessIdentifier, agentID: agentID, executablePath: executablePath,
                     sessionID: sessionID, resumeSession: resumeSession, modelIdentifier: modelIdentifier,
                     effortIdentifier: effortIdentifier, restricted: false, reply: reply)
    }

    func startRestrictedCodex(agentID: String, executablePath: String,
                              withReply reply: @escaping (Int32, String?) -> Void) {
        startRuntime(harnessIdentifier: HarnessProvider.codex.rawValue, agentID: agentID, executablePath: executablePath,
                     sessionID: nil, resumeSession: false, modelIdentifier: nil, effortIdentifier: nil,
                     restricted: true, reply: reply)
    }

    func startRestrictedApple(agentID: String, withReply reply: @escaping (Int32, String?) -> Void) {
        startRuntime(harnessIdentifier: HarnessProvider.apple.rawValue, agentID: agentID, executablePath: HostPaths.apple.path,
                     sessionID: nil, resumeSession: false, modelIdentifier: nil, effortIdentifier: nil,
                     restricted: true, reply: reply)
    }

    func startRestrictedACP(harnessIdentifier: String, agentID: String, executablePath: String,
                            modelIdentifier: String?, effortIdentifier: String?,
                            withReply reply: @escaping (Int32, String?) -> Void) {
        guard let provider = HarnessProvider(rawValue: harnessIdentifier), provider == .fx || provider == .grokBuild else {
            reply(0, "Unsupported restricted ACP harness.")
            return
        }
        startRuntime(harnessIdentifier: provider.rawValue, agentID: agentID, executablePath: executablePath,
                     sessionID: nil, resumeSession: false, modelIdentifier: modelIdentifier, effortIdentifier: effortIdentifier,
                     restricted: true, reply: reply)
    }

    func inspectApple(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let executable = try HostPaths.executable(HostPaths.apple.path, provider: .apple)
                let result = try AppleHarnessProbe.inspect(executable: executable, application: HostPaths.application)
                reply(try JSONEncoder().encode(result), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func startRestrictedMuse(agentID: String, executablePath: String, modelIdentifier: String?, effortIdentifier: String?,
                             withReply reply: @escaping (Int32, String?) -> Void) {
        startRuntime(harnessIdentifier: HarnessProvider.muse.rawValue, agentID: agentID, executablePath: executablePath,
                     sessionID: nil, resumeSession: false, modelIdentifier: modelIdentifier, effortIdentifier: effortIdentifier,
                     restricted: true, reply: reply)
    }

    private func startRuntime(harnessIdentifier: String, agentID: String, executablePath: String,
                              sessionID: String?, resumeSession: Bool, modelIdentifier: String?, effortIdentifier: String?,
                              restricted: Bool, reply: @escaping (Int32, String?) -> Void) {
        queue.async {
            guard self.process == nil, !self.stopping else { reply(0, "Runtime already started or stopping."); return }
            do {
                guard let provider = HarnessProvider(rawValue: harnessIdentifier) else {
                    throw HostError("Unsupported harness.")
                }
                _ = try HostPaths.executable(executablePath, provider: provider)
                let workspace = try HostPaths.workspace(agentID)
                let child = Process()
                child.executableURL = Bundle.main.executableURL
                // Preserve the approved installation path for the child's independent
                // trust check. Passing the resolved release path would fall outside the
                // intentionally narrow installation allowlist on the second check.
                child.arguments = [
                    "--harness-child", provider.rawValue, executablePath, agentID,
                    sessionID ?? "", resumeSession ? "1" : "0",
                    modelIdentifier ?? "", effortIdentifier ?? "", restricted ? "restricted" : "autonomous"
                ]
                child.currentDirectoryURL = workspace
                // Do not inherit DYLD, shell startup hooks, or arbitrary app environment.
                child.environment = [
                    "HOME": HostPaths.home.path,
                    "USER": NSUserName(), "LOGNAME": NSUserName(),
                    "PATH": "\(HostPaths.home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
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
            self.accountProcess?.terminationHandler = nil
            if self.accountProcess?.isRunning == true { self.accountProcess?.terminate() }
            self.accountProcess = nil
            self.loginOutput?.readabilityHandler = nil
            self.loginOutput = nil
            self.loginText = ""
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

    func inspectHarnessVersion(harnessIdentifier: String, executablePath: String, withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                guard let provider = HarnessProvider(rawValue: harnessIdentifier) else { throw HostError("Unknown harness.") }
                let executable = try HostPaths.executable(executablePath, provider: provider)
                let report = try provider == .apple
                    ? HarnessVersionReport(installedVersion: AppleHarnessProbe.inspect(executable: executable, application: HostPaths.application).version)
                    : HarnessVersionInspection.inspect(provider: provider, executable: executable, environment: self.accountEnvironment)
                reply(try JSONEncoder().encode(report), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func inspectGrok(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let result = try GrokInspection.inspect(home: HostPaths.home, environment: self.accountEnvironment)
                reply(try JSONEncoder().encode(result), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func inspectMuse(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let result = try MuseInspection.inspect(home: HostPaths.home, environment: self.accountEnvironment)
                reply(try JSONEncoder().encode(result), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func checkAuthentication(
        harnessIdentifier: String,
        executablePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async {
            do {
                guard let provider = HarnessProvider(rawValue: harnessIdentifier), provider == .claudeCode || provider == .fx else {
                    throw HostError("This harness does not use the Claude Code account check.")
                }
                let executable = try HostPaths.executable(executablePath, provider: provider)
                reply(try provider == .fx ? FxInspection.status(executable: executable, environment: self.accountEnvironment).authenticated : self.claudeAuthenticationStatus(executable), nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func signIn(
        harnessIdentifier: String,
        executablePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async {
            do {
                guard let provider = HarnessProvider(rawValue: harnessIdentifier), provider == .claudeCode || provider == .fx else {
                    throw HostError("This harness does not support this sign-in flow.")
                }
                let executable = try HostPaths.executable(executablePath, provider: provider)
                let login = Process()
                login.executableURL = executable
                login.arguments = provider == .fx ? ["login"] : ["auth", "login", "--claudeai"]
                login.currentDirectoryURL = FileManager.default.temporaryDirectory
                login.standardInput = FileHandle.nullDevice
                login.standardOutput = FileHandle.nullDevice
                login.standardError = FileHandle.nullDevice
                login.environment = self.accountEnvironment
                if provider == .fx {
                    let output = Pipe()
                    login.standardOutput = output
                    self.loginText = ""
                    self.loginChallengeSent = false
                    self.loginOutput = output.fileHandleForReading
                    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil; return }
                        self?.queue.async {
                            guard let self, self.accountProcess === login, !self.loginChallengeSent else { return }
                            self.loginText += String(decoding: data, as: UTF8.self)
                            self.loginText = String(self.loginText.prefix(16_384))
                            if let challenge = FxProtocol.loginChallenge(self.loginText) {
                                self.loginChallengeSent = true
                                self.loginText = ""
                                self.client?.signInChallenge(challenge.url.absoluteString, code: challenge.code)
                            }
                        }
                    }
                }
                login.terminationHandler = { [weak self] login in
                    self?.queue.async {
                        guard let self, self.accountProcess === login else { return }
                        self.accountProcess = nil
                        self.loginOutput?.readabilityHandler = nil
                        self.loginOutput = nil
                        self.loginText = ""
                        do {
                            guard login.terminationStatus == 0 else {
                                throw HostError("\(provider.displayName) sign-in did not complete. Try signing in from Terminal.")
                            }
                            reply(try provider == .fx ? FxInspection.status(executable: executable, environment: self.accountEnvironment).authenticated : self.claudeAuthenticationStatus(executable), nil)
                        } catch { reply(false, error.localizedDescription) }
                    }
                }
                try login.run()
                self.accountProcess = login
            } catch { reply(false, error.localizedDescription) }
        }
    }

    private var accountEnvironment: [String: String] {
        [
            "HOME": HostPaths.home.path,
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "\(HostPaths.home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "TMPDIR": NSTemporaryDirectory()
        ]
    }

    func fxModels(executablePath: String, withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let executable = try HostPaths.executable(executablePath, provider: .fx)
                reply(try JSONEncoder().encode(FxInspection.models(executable: executable, environment: self.accountEnvironment)), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    private func claudeAuthenticationStatus(_ executable: URL) throws -> Bool {
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = accountEnvironment
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else {
            throw HostError("Claude Code returned an unsupported account response.")
        }
        return loggedIn
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
