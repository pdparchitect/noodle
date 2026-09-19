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
    static var appleModels: URL {
        home.appendingPathComponent("Library/Containers/\(AgentHostIdentity.application)/Data/Library/Application Support/Noodle/AppleModels", isDirectory: true)
    }
    static let home: URL = {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { fatalError("No user home") }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }()

    static func executable(_ path: String, provider: HarnessProvider) throws -> URL {
        // A harness Noodle installed is held to the same vendor signature, in Noodle's storage.
        if let managed = try managedHarnesses.trustedExecutable(at: path, provider: provider) { return managed }
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
        case .openCode: return try OpenCodeExecutableTrust.executable(at: path, home: home)
        }
    }

    static var container: URL {
        home.appendingPathComponent("Library/Containers/\(AgentHostIdentity.application)", isDirectory: true)
    }

    static var profiles: HarnessProfileStore {
        HarnessProfileStore(root: container.appendingPathComponent("Data/Library/Application Support/Noodle", isDirectory: true))
    }

    static var managedHarnesses: ManagedHarnessStore {
        ManagedHarnessStore(root: container.appendingPathComponent("Data/Library/Application Support/Noodle", isDirectory: true))
    }

    /// The copy Noodle installed, verified, for inspections that otherwise look
    /// only at the vendor's own location.
    static func managedExecutable(_ provider: HarnessProvider) throws -> URL? {
        guard let path = managedHarnesses.executable(provider)?.path else { return nil }
        return try managedHarnesses.trustedExecutable(at: path, provider: provider)
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
if CommandLine.arguments.count == 11, CommandLine.arguments[1] == "--harness-child" {
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
        guard ["0", "1"].contains(CommandLine.arguments[10]) else { throw HostError("Unsupported apps selection.") }
        let appsEnabled = CommandLine.arguments[10] == "1"
        guard !appsEnabled || provider.supportsAccountApps else { throw HostError("This harness does not support account apps.") }
        guard restricted || CommandLine.arguments[9] == "autonomous",
              !restricted || provider.supportsRestrictedAccess else { throw HostError("Unsupported runtime access mode.") }
        // The profile comes from the bot's own agent.json and is resolved here
        // to a folder in Noodle's storage. The XPC caller cannot supply a path.
        let profiles = HostPaths.profiles
        let harnessProfile = try profiles.selected(workspace: workspace, provider: provider)
        let loginHome = harnessProfile.map(profiles.loginHome) ?? HostPaths.home
        try isolateProcessGroup()
        guard chdir(workspace.path) == 0 else { throw HostError("Could not open the bot workspace: \(String(cString: strerror(errno)))") }
        var strings: [String]
        switch provider {
        case .apple:
            guard effort == nil, model.map(FxProtocol.validIdentifier) ?? true else { throw HostError("Unsupported Apple model configuration.") }
            if let model, model != "default" { _ = try AppleLocalModelStore(directory: HostPaths.appleModels).model(id: model) }
            strings = [executable.path, "--serve"]
        case .muse:
            guard model.map(FxProtocol.validIdentifier) ?? true,
                  effort.map(MuseProtocol.efforts.contains) ?? true else { throw HostError("Unsupported Muse model or effort.") }
            // Restricted runs receive the mandatory outer policy below; do not
            // try to stack Muse's shell sandbox inside the process sandbox.
            strings = [executable.path, "serve", "--disable-sandbox", "--trust-workspace"]
        case .codex:
            strings = [executable.path] + CodexLaunch.appServerArguments(appsEnabled: appsEnabled)
        case .openCode:
            guard model.map(OpenCodeProtocol.validModel) ?? true,
                  effort.map(FxProtocol.validIdentifier) ?? true else { throw HostError("Unsupported OpenCode model or effort.") }
            strings = [executable.path, "acp"]
            setenv("OPENCODE_DISABLE_AUTOUPDATE", "true", 1)
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
            // Noodle updates the copy it installed. Claude Code updating itself would
            // install a second one into the user's home and retire this one.
            if HostPaths.managedHarnesses.manages(HarnessInstallation(provider: provider, executablePath: CommandLine.arguments[3])) {
                setenv("DISABLE_AUTOUPDATER", "1", 1)
            }
            strings = [executable.path] + (try ClaudeLaunch.arguments(sessionID: sessionID,
                resumeSession: resumeSession, model: model, effort: effort, restricted: restricted, appsEnabled: appsEnabled))
        }
        if restricted {
            let layout = AgentStorageLayout(workspace: workspace)
            let repository = layout.package.deletingLastPathComponent().deletingLastPathComponent()
            if harnessProfile == nil {
                try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: loginHome)
            } else {
                // A profile's login is its files alone. The user's Keychain items
                // belong to the system profile and must never stand in for them.
                try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: loginHome,
                                                     secret: { _, _ in nil })
            }
            let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
            let codexHome = privateHome.appendingPathComponent(".codex", isDirectory: true)
            let temporary = workspace.appendingPathComponent(".noodle/tmp", isDirectory: true)
            // Only paths derived by this host enter the profile. The XPC caller
            // cannot supply policy text, writable roots, or a command. Shared
            // folders come from the bot's own agent.json, which the bot cannot
            // write, and are revalidated here against Noodle's storage.
            let folders = try AgentFolder.granted(workspace: workspace, protecting: [HostPaths.container])
            let profile: String
            switch provider {
            case .apple:
                let localModel = model.map(AppleLocalModelStore.validIdentifier) ?? false
                let modelDirectory = try localModel ? AppleLocalModelStore(directory: HostPaths.appleModels).folder(id: model!) : nil
                profile = AppleAgentSandbox.profile(application: HostPaths.application, workspace: workspace, repository: repository,
                    modelsDirectory: modelDirectory, localModel: localModel, folders: folders)
            case .codex:
                let certificates = try RestrictedCodexCertificates.prepare(workspace: workspace)
                setenv("CODEX_CA_CERTIFICATE", certificates.path, 1)
                profile = RestrictedAgentSandbox.profile(workspace: workspace, repository: repository,
                    codexHome: codexHome, executableDirectory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                    application: HostPaths.application, temporary: temporary, folders: folders)
            case .claudeCode, .fx, .grokBuild, .muse, .openCode:
                profile = try RestrictedAgentSandbox.profile(provider: provider, workspace: workspace, repository: repository,
                    home: HostPaths.home, executable: executable, application: HostPaths.application, temporary: temporary,
                    folders: folders)
            }
            setenv("TMPDIR", temporary.path, 1)
            setenv("TMPPREFIX", temporary.appendingPathComponent("zsh").path, 1)
            setenv("CODEX_HOME", codexHome.path, 1)
            if provider == .claudeCode || provider == .fx || provider == .grokBuild || provider == .muse || provider == .openCode {
                for (key, value) in try RestrictedAgentSandbox.environment(provider: provider, home: HostPaths.home, workspace: workspace) {
                    setenv(key, value, 1)
                }
            } else { setenv("HOME", privateHome.path, 1) }
            if provider == .openCode {
                _ = try OpenCodeStorage.seed(workspace: workspace, loginHome: HostPaths.home, executable: executable,
                    environment: ProcessInfo.processInfo.environment, profile: profile)
                // ACP v2 keeps the first catalogue it sees for its process lifetime.
                // Refresh this bot's private cache before it opens a session.
                try OpenCodeInspection.prepareCatalogue(executable: executable, workspace: workspace,
                    environment: ProcessInfo.processInfo.environment, profile: profile)
            }
            strings = ["/usr/bin/sandbox-exec", "-p", profile] + strings
        } else if let harnessProfile {
            for (key, value) in profiles.environment(harnessProfile) { setenv(key, value, 1) }
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
    private var codexAccount: Task<Void, Never>?
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
        appsEnabled: Bool,
        withReply reply: @escaping (Int32, String?) -> Void
    ) {
        startRuntime(harnessIdentifier: harnessIdentifier, agentID: agentID, executablePath: executablePath,
                     sessionID: sessionID, resumeSession: resumeSession, modelIdentifier: modelIdentifier,
                     effortIdentifier: effortIdentifier, restricted: false, appsEnabled: appsEnabled, reply: reply)
    }

    func startRestrictedCodex(agentID: String, executablePath: String, appsEnabled: Bool,
                              withReply reply: @escaping (Int32, String?) -> Void) {
        startRuntime(harnessIdentifier: HarnessProvider.codex.rawValue, agentID: agentID, executablePath: executablePath,
                     sessionID: nil, resumeSession: false, modelIdentifier: nil, effortIdentifier: nil,
                     restricted: true, appsEnabled: appsEnabled, reply: reply)
    }

    func startRestrictedClaude(agentID: String, executablePath: String, sessionID: String?, resumeSession: Bool,
                               modelIdentifier: String?, effortIdentifier: String?, appsEnabled: Bool,
                               withReply reply: @escaping (Int32, String?) -> Void) {
        startRuntime(harnessIdentifier: HarnessProvider.claudeCode.rawValue, agentID: agentID, executablePath: executablePath,
                     sessionID: sessionID, resumeSession: resumeSession, modelIdentifier: modelIdentifier,
                     effortIdentifier: effortIdentifier, restricted: true, appsEnabled: appsEnabled, reply: reply)
    }

    func startRestrictedApple(agentID: String, modelIdentifier: String?, withReply reply: @escaping (Int32, String?) -> Void) {
        startRuntime(harnessIdentifier: HarnessProvider.apple.rawValue, agentID: agentID, executablePath: HostPaths.apple.path,
                     sessionID: nil, resumeSession: false, modelIdentifier: modelIdentifier, effortIdentifier: nil,
                     restricted: true, reply: reply)
    }

    func startRestrictedACP(harnessIdentifier: String, agentID: String, executablePath: String,
                            modelIdentifier: String?, effortIdentifier: String?,
                            withReply reply: @escaping (Int32, String?) -> Void) {
        guard let provider = HarnessProvider(rawValue: harnessIdentifier), provider == .fx || provider == .grokBuild || provider == .openCode else {
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
                let result = try AppleHarnessProbe.inspect(executable: executable, application: HostPaths.application, modelsDirectory: HostPaths.appleModels)
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
                              restricted: Bool, appsEnabled: Bool = false, reply: @escaping (Int32, String?) -> Void) {
        queue.async { [self] in
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
                    modelIdentifier ?? "", effortIdentifier ?? "", restricted ? "restricted" : "autonomous",
                    appsEnabled ? "1" : "0"
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
        queue.async { [self] in
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
            self.codexAccount?.cancel()
            self.codexAccount = nil
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
                ProcessExitConfirmation.wait(process: self.process, groupID: id, queue: self.queue) { stopped in
                    self.outputs.forEach { $0.readabilityHandler = nil }
                    self.outputs = []
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

    func publishHarness(harnessIdentifier: String, version: String, stagingID: String,
                        withReply reply: @escaping (String?, String?) -> Void) {
        queue.async {
            do {
                guard let provider = HarnessProvider(rawValue: harnessIdentifier), let staging = UUID(uuidString: stagingID) else {
                    throw HostError("Invalid harness installation request.")
                }
                reply(try HostPaths.managedHarnesses.publish(provider, version: version, staging: staging).path, nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func inspectGrok(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let result = try GrokInspection.inspect(home: HostPaths.home, environment: self.accountEnvironment,
                                                        managed: HostPaths.managedExecutable(.grokBuild))
                reply(try JSONEncoder().encode(result), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func inspectOpenCode(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let result = try OpenCodeInspection.inspect(home: HostPaths.home, application: HostPaths.application,
                                                            managed: HostPaths.managedExecutable(.openCode))
                reply(try JSONEncoder().encode(result), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func inspectMuse(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let result = try MuseInspection.inspect(home: HostPaths.home, environment: self.accountEnvironment,
                                                        managed: HostPaths.managedExecutable(.muse))
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
                if harnessIdentifier == HarnessProvider.codex.rawValue {
                    let executable = try HostPaths.executable(executablePath, provider: .codex)
                    return self.runCodexAccount(executable, home: HostPaths.home.appendingPathComponent(".codex"), signIn: false, reply: reply)
                }
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
        queue.async { [self] in
            do {
                if harnessIdentifier == HarnessProvider.codex.rawValue {
                    let executable = try HostPaths.executable(executablePath, provider: .codex)
                    return self.runCodexAccount(executable, home: HostPaths.home.appendingPathComponent(".codex"), signIn: true, reply: reply)
                }
                guard let provider = HarnessProvider(rawValue: harnessIdentifier) else { throw HostError("Unsupported harness.") }
                if let arguments = HarnessProfileLogin.arguments(provider) {
                    // Grok Build and Muse Code: the same device-code login a profile uses, into the system account.
                    let executable = try HostPaths.executable(executablePath, provider: provider)
                    let environment = self.accountEnvironment
                    return self.runLogin(executable: executable, arguments: arguments, environment: environment, name: provider.displayName,
                                         challenge: { HarnessProfileLogin.challenge(provider: provider, text: $0) },
                                         status: {
                                             provider == .grokBuild
                                                 ? try GrokInspection.inspect(home: HostPaths.home, environment: environment,
                                                                              managed: HostPaths.managedExecutable(.grokBuild)).authenticated
                                                 : MuseAuthentication.inspect(home: HostPaths.home, environment: environment) != .unauthenticated
                                         }, reply: reply)
                }
                guard provider == .claudeCode || provider == .fx else {
                    throw HostError("This harness does not support this sign-in flow.")
                }
                let executable = try HostPaths.executable(executablePath, provider: provider)
                let environment = self.accountEnvironment
                self.runLogin(executable: executable, arguments: provider == .fx ? ["login"] : ["auth", "login", "--claudeai"],
                              environment: environment, name: provider.displayName,
                              challenge: provider == .fx ? FxProtocol.loginChallenge : nil,
                              status: { try provider == .fx ? FxInspection.status(executable: executable, environment: environment).authenticated
                                  : self.claudeAuthenticationStatus(executable) },
                              reply: reply)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func checkProfileAuthentication(profileID: String, executablePath: String,
                                    withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            do {
                if let codex = try self.codexProfile(profileID, executablePath: executablePath) {
                    return self.runCodexAccount(codex.executable, home: codex.home, signIn: false, reply: reply)
                }
                let account = try self.profileAccount(profileID, executablePath: executablePath)
                reply(try account.status(), nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func signInProfile(profileID: String, executablePath: String,
                       withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async { [self] in
            do {
                if let codex = try self.codexProfile(profileID, executablePath: executablePath) {
                    return self.runCodexAccount(codex.executable, home: codex.home, signIn: true, reply: reply)
                }
                let account = try self.profileAccount(profileID, executablePath: executablePath)
                guard let arguments = HarnessProfileLogin.arguments(account.provider) else {
                    throw HostError("This harness does not support this sign-in flow.")
                }
                self.runLogin(executable: account.executable, arguments: arguments, environment: account.environment,
                              name: account.provider.displayName,
                              challenge: { HarnessProfileLogin.challenge(provider: account.provider, text: $0) },
                              status: account.status, reply: reply)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    /// Codex reports its account over its own app-server protocol, not a login
    /// command. The app runs this itself for a Codex it can execute; a copy Noodle
    /// installed sits in the app's container, where only this host can run it.
    private func runCodexAccount(_ executable: URL, home: URL, signIn: Bool, reply: @escaping (Bool, String?) -> Void) {
        let environment = accountEnvironment
        codexAccount?.cancel()
        codexAccount = Task { @MainActor [weak self] in
            let provider = CodexSetupProvider(codexHome: home, environment: environment)
            let installation = HarnessInstallation(provider: .codex, executablePath: executable.path)
            do {
                let status = try await signIn
                    ? provider.signIn(for: installation) { self?.client?.signInChallenge($0.url.absoluteString, code: $0.code) }
                    : provider.status(for: installation)
                reply(status != .unauthenticated, nil)
            } catch { reply(false, error is CancellationError ? "Sign-in was cancelled." : error.localizedDescription) }
        }
    }

    /// Nil unless the identifier names a Codex profile; its folder is resolved here.
    private func codexProfile(_ profileID: String, executablePath: String) throws -> (executable: URL, home: URL)? {
        guard let id = UUID(uuidString: profileID) else { throw HostError("Invalid profile identifier.") }
        let profiles = HostPaths.profiles
        let profile = try profiles.validated(id)
        guard profile.provider == .codex else { return nil }
        return (try HostPaths.executable(executablePath, provider: .codex), profiles.accountHome(profile))
    }

    private struct ProfileAccount {
        let provider: HarnessProvider
        let executable: URL
        let environment: [String: String]
        let status: () throws -> Bool
    }

    /// Everything here derives from the profile's identifier. The caller
    /// cannot supply a folder, an environment, or a command.
    private func profileAccount(_ profileID: String, executablePath: String) throws -> ProfileAccount {
        guard let id = UUID(uuidString: profileID) else { throw HostError("Invalid profile identifier.") }
        let profiles = HostPaths.profiles
        let profile = try profiles.validated(id)
        let provider = profile.provider
        guard HarnessProfileLogin.arguments(provider) != nil else { throw HostError("This harness does not support this sign-in flow.") }
        let executable = try HostPaths.executable(executablePath, provider: provider)
        let environment = accountEnvironment.merging(profiles.environment(profile)) { _, profile in profile }
        return ProfileAccount(provider: provider, executable: executable, environment: environment) {
            switch provider {
            case .grokBuild:
                return try GrokInspection.inspect(home: HostPaths.home, environment: environment,
                                                  managed: HostPaths.managedExecutable(.grokBuild)).authenticated
            case .muse:
                guard !profiles.loginIsShared(profile) else {
                    throw HostError("This Muse Code version saved the sign-in to the shared Keychain item, so it cannot be kept as a separate profile.")
                }
                return MuseAuthentication.inspect(home: HostPaths.home, environment: environment) == .authenticated
            default: throw HostError("This harness does not support this sign-in flow.")
            }
        }
    }

    /// One account command at a time. Output is read only to find the sign-in
    /// challenge; nothing else the harness prints leaves the host.
    private func runLogin(executable: URL, arguments: [String], environment: [String: String], name: String,
                          challenge: ((String) -> HarnessSignInChallenge?)?, status: @escaping () throws -> Bool,
                          reply: @escaping (Bool, String?) -> Void) {
        do {
            let login = Process()
            login.executableURL = executable
            login.arguments = arguments
            login.currentDirectoryURL = FileManager.default.temporaryDirectory
            login.standardInput = FileHandle.nullDevice
            login.standardOutput = FileHandle.nullDevice
            login.standardError = FileHandle.nullDevice
            login.environment = environment
            if let challenge {
                let output = Pipe()
                login.standardOutput = output
                login.standardError = output
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
                        if let challenge = challenge(self.loginText) {
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
                            throw HostError("\(name) sign-in did not complete. Try signing in from Terminal.")
                        }
                        reply(try status(), nil)
                    } catch { reply(false, error.localizedDescription) }
                }
            }
            try login.run()
            self.accountProcess = login
        } catch { reply(false, error.localizedDescription) }
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

    func codexModels(executablePath: String, withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let executable = try HostPaths.executable(executablePath, provider: .codex)
                var environment = self.accountEnvironment
                environment["CODEX_HOME"] = HostPaths.home.appendingPathComponent(".codex").path
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                reply(try JSONEncoder().encode(CodexInspection.models(executable: executable, environment: environment,
                                                                      clientVersion: version)), nil)
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
