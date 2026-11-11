#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import NoodleCore

/// Who `noodled setup` talks to: it says what it does and asks before doing anything.
public protocol SetupConversation {
    func say(_ text: String)
    /// The answer, or `default` when none is given.
    func ask(_ question: String, default: String?) -> String
    func confirm(_ question: String, default: Bool) -> Bool
}

/// What `noodled setup` does to the machine and learns about it.
public protocol SetupSystem {
    /// Runs `command`, showing its output, and returns how it ended.
    func run(_ command: [String], interactive: Bool) -> Int32
    /// Where a program is, if it is installed.
    func program(_ name: String) -> String?
    /// Whether `path` is a program that can be run.
    func isProgram(_ path: String) -> Bool
    func hasPackage(_ name: String) -> Bool
    func hasUser(_ name: String) -> Bool
    /// Why bubblewrap cannot make a bot's sandbox here, or nil.
    func sandboxProblem() -> String?
    func hostName() -> String
    /// `/etc/os-release`, for which of Microsoft's packages to use.
    func releaseInfo() -> String
    /// Waits for the server to answer on its socket after starting.
    func waitForServer(_ socket: URL) -> Bool
}

/// Where setup puts things: the file, the service, and noodled itself.
public struct SetupPaths: Sendable {
    public var configuration: URL
    public var service: URL
    /// Where the service runs noodled from.
    public var installed: URL
    /// The noodled running setup, which may be in a download's folder.
    public var running: URL

    public init(configuration: URL, service: URL, installed: URL, running: URL) {
        self.configuration = configuration
        self.service = service
        self.installed = installed
        self.running = running
    }

    public static func standard(running: URL) -> SetupPaths {
        SetupPaths(configuration: URL(fileURLWithPath: "/etc/noodled/noodled.yaml"),
                   service: URL(fileURLWithPath: "/etc/systemd/system/noodled.service"),
                   installed: URL(fileURLWithPath: "/usr/local/bin/noodled"), running: running)
    }
}

/// The service noodled runs as. The download carries the same file, which a test keeps identical.
public enum ServerService {
    public static let unit = """
    [Unit]
    Description=Noodle Server
    Documentation=https://github.com/pdparchitect/noodle/blob/main/Server/README.md
    Wants=network-online.target
    After=network-online.target

    [Service]
    User=noodled
    Group=noodled
    ExecStart=/usr/local/bin/noodled run --config /etc/noodled/noodled.yaml
    Restart=on-failure
    RestartSec=5
    # The data folder, kept for noodled alone.
    StateDirectory=noodled
    StateDirectoryMode=0700
    UMask=0077
    NoNewPrivileges=yes
    PrivateTmp=yes
    ProtectSystem=full

    [Install]
    WantedBy=multi-user.target

    """
}

public struct SetupError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// `noodled setup`: what the README's manual route does, asked for step by step. It checks the machine,
/// writes the file or keeps the one there, installs the account, folder and service, signs in, starts
/// the server and prints an invitation for its admin. Nothing is installed without a yes.
public struct ServerSetup {
    let conversation: any SetupConversation
    let system: any SetupSystem
    let paths: SetupPaths
    let now: Date

    public init(conversation: any SetupConversation, system: any SetupSystem, paths: SetupPaths, now: Date = Date()) {
        self.conversation = conversation
        self.system = system
        self.paths = paths
        self.now = now
    }

    /// Each harness setup can install, with the npm package it comes in.
    private static let installable: [(provider: HarnessProvider, program: String, package: String)] = [
        (.claudeCode, "claude", "@anthropic-ai/claude-code"),
        (.codex, "codex", "@openai/codex"),
    ]

    public func run() throws {
        try checkMachine()
        let configuration = try configure()
        try install(configuration)
        signIn(configuration)
        try start(configuration)
    }

    // MARK: The machine

    private func checkMachine() throws {
        if !system.hasPackage("bubblewrap") {
            guard system.program("apt-get") != nil,
                  conversation.confirm("Noodle Server keeps each bot in a sandbox made by bubblewrap. Install bubblewrap?", default: true) else {
                throw SetupError("Noodle Server needs bubblewrap. Install it with: sudo apt-get install bubblewrap")
            }
            try runOrFail(["apt-get", "install", "-y", "bubblewrap"])
        }
        if !system.hasPackage("libmsquic") {
            let packages = microsoftPackages()
            guard system.program("apt-get") != nil, let packages,
                  conversation.confirm("Devices connect to Noodle Server through msquic, from Microsoft's packages. Install msquic?", default: true) else {
                throw SetupError("Noodle Server needs msquic. Its README shows how to install it from Microsoft's packages.")
            }
            try runOrFail(["apt-get", "install", "-y", "curl", "ca-certificates"])
            try runOrFail(["curl", "-fsSL", packages, "-o", "/tmp/microsoft.deb"])
            try runOrFail(["dpkg", "-i", "/tmp/microsoft.deb"])
            try runOrFail(["apt-get", "update"])
            try runOrFail(["apt-get", "install", "-y", "libmsquic"])
        }
        if let problem = system.sandboxProblem() { throw SetupError(problem) }
    }

    /// Microsoft's package list for this system, which carries msquic.
    private func microsoftPackages() -> String? {
        var fields: [String: String] = [:]
        for line in system.releaseInfo().split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        guard let id = fields["ID"], ["ubuntu", "debian"].contains(id), let version = fields["VERSION_ID"] else { return nil }
        return "https://packages.microsoft.com/config/\(id)/\(version)/packages-microsoft-prod.deb"
    }

    // MARK: The file

    private func configure() throws -> ServerConfiguration {
        let file = paths.configuration
        if FileManager.default.fileExists(atPath: file.path) {
            conversation.say("\(file.path) is already there.")
            let answer = conversation.ask("Keep it, or start over with a new one? (keep/start over)", default: "keep")
            if !answer.lowercased().hasPrefix("start") {
                let configuration = try ServerConfiguration(contentsOf: file)
                let problems = configuration.problems(isProgram: system.isProgram)
                guard problems.isEmpty else {
                    throw SetupError("\(file.path) has problems to fix first:\n" + problems.map { "  \($0)" }.joined(separator: "\n"))
                }
                return configuration
            }
            let aside = file.deletingLastPathComponent().appendingPathComponent("noodled.yaml.\(Self.stamp(now))")
            try FileManager.default.moveItem(at: file, to: aside)
            conversation.say("The old file is now \(aside.path).")
        }

        let name = conversation.ask("What should devices call this server?", default: system.hostName())
        let address = conversation.ask("How do devices away from this network reach it, such as a domain name? Leave it empty for none.",
                                       default: "")
        var harnesses: [(HarnessProvider, String)] = []
        var hasNode = system.program("npm") != nil
        for harness in Self.installable {
            if let path = system.program(harness.program) {
                conversation.say("Found \(harness.provider.displayName) at \(path).")
                harnesses.append((harness.provider, path))
                continue
            }
            guard conversation.confirm("Install \(harness.provider.displayName)\(hasNode ? "" : ", with Node.js")?", default: true) else { continue }
            if !hasNode {
                try runOrFail(["apt-get", "install", "-y", "nodejs", "npm"])
                hasNode = true
            }
            try runOrFail(["npm", "install", "-g", harness.package])
            guard let path = system.program(harness.program) else {
                throw SetupError("\(harness.provider.displayName) was installed, but \(harness.program) is not where noodled can find it.")
            }
            harnesses.append((harness.provider, path))
        }
        guard !harnesses.isEmpty else {
            throw SetupError("Noodle Server needs Claude Code or Codex. Install either, then run noodled setup again.")
        }
        var admin = ""
        while admin.isEmpty {
            admin = conversation.ask("Your name, as the server's admin:", default: nil).trimmingCharacters(in: .whitespaces)
        }

        let text = Self.yaml(name: name, address: address, harnesses: harnesses, admin: admin)
        let configuration = try ServerConfiguration(yaml: text)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        conversation.say("Wrote \(file.path). Edit it to add people and plans.")
        return configuration
    }

    /// When a file was moved aside, to the minute, in the server's time zone.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    /// A first file: the harnesses found, one plan lending all of them, and the admin on it.
    static func yaml(name: String, address: String, harnesses: [(HarnessProvider, String)], admin: String) -> String {
        var lines = ["# Noodle Server's configuration, written by noodled setup. After changing it, run",
                     "# `noodled check`, then `sudo systemctl restart noodled`. The README explains every setting.", "",
                     "name: \(quoted(name))"]
        if !address.isEmpty { lines.append("address: \(quoted(address))") }
        lines += ["", "harnesses:"] + harnesses.map { "  \($0.0.rawValue): \(quoted($0.1))" }
        lines += ["", "plans:", "  Everyone:", "    harnesses: [\(harnesses.map(\.0.rawValue).joined(separator: ", "))]"]
        lines += ["", "users:", "  \(quoted(admin)):", "    plan: Everyone", "    admin: true", "    pair-devices: true", ""]
        return lines.joined(separator: "\n")
    }

    /// Text YAML reads back exactly, whatever it holds.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Installing and starting

    private func install(_ configuration: ServerConfiguration) throws {
        if paths.running.standardizedFileURL != paths.installed.standardizedFileURL {
            try runOrFail(["install", "-m", "755", paths.running.path, paths.installed.path])
        }
        if !system.hasUser("noodled") {
            try runOrFail(["useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", "noodled"])
        }
        try runOrFail(["install", "-d", "-m", "700", "-o", "noodled", "-g", "noodled", configuration.data.path])
        let current = try? String(contentsOf: paths.service, encoding: .utf8)
        if current != ServerService.unit {
            try FileManager.default.createDirectory(at: paths.service.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ServerService.unit.utf8).write(to: paths.service)
        }
    }

    /// Each login nobody signed in to, as the noodled account, so the server can read what it writes.
    private func signIn(_ configuration: ServerConfiguration) {
        let logins = ServerLogins(configuration: configuration, profiles: HarnessProfileStore(root: configuration.data))
        for provider in configuration.harnesses.keys.filter(ServerConfiguration.supported.contains).sorted(by: { $0.rawValue < $1.rawValue }) {
            for profile in [nil] + (configuration.profiles[provider] ?? []).map(Optional.some) {
                if let login = try? logins.login(provider, profile: profile), logins.isSignedIn(login) { continue }
                let name = profile.map { "\(provider.displayName)'s \($0) profile" } ?? provider.displayName
                guard conversation.confirm("Sign in to \(name) now?", default: true) else {
                    conversation.say("Later: sudo -u noodled noodled login \(provider.rawValue)" + (profile.map { " --profile \($0)" } ?? ""))
                    continue
                }
                var command = noodled(["login", provider.rawValue])
                if let profile { command.insert(contentsOf: ["--profile", profile], at: command.count - 2) }
                if system.run(command, interactive: true) != 0 { conversation.say("\(name) is not signed in yet.") }
            }
        }
    }

    private func start(_ configuration: ServerConfiguration) throws {
        try runOrFail(["systemctl", "daemon-reload"])
        try runOrFail(["systemctl", "enable", "--now", "noodled"])
        guard system.waitForServer(ServerControl.socket(in: configuration.data)) else {
            throw SetupError("noodled did not start. See why with: journalctl -u noodled")
        }
        let admin = configuration.users.first(where: \.isAdmin) ?? configuration.users.first
        guard let admin else {
            conversation.say("Noodle Server is running. Add someone under users in \(paths.configuration.path) to invite them.")
            return
        }
        conversation.say("Noodle Server is running. Pair your first device:")
        _ = system.run(noodled(["invite", admin.name, "--qr"]), interactive: true)
    }

    /// noodled, run as its own account with this file.
    private func noodled(_ arguments: [String]) -> [String] {
        ["runuser", "-u", "noodled", "--", paths.installed.path] + arguments + ["--config", paths.configuration.path]
    }

    private func runOrFail(_ command: [String]) throws {
        guard system.run(command, interactive: true) == 0 else {
            throw SetupError("This did not work: \(command.joined(separator: " "))")
        }
    }
}

/// Setup's questions in the terminal it was started in.
public struct ConsoleConversation: SetupConversation {
    public init() {}

    public func say(_ text: String) { print(text) }

    public func ask(_ question: String, default value: String?) -> String {
        print(question + (value.map { $0.isEmpty ? " " : " [\($0)] " } ?? " "), terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
        return answer.isEmpty ? value ?? "" : answer
    }

    public func confirm(_ question: String, default value: Bool) -> Bool {
        let answer = ask(question + (value ? " (Y/n)" : " (y/N)"), default: nil).lowercased()
        return answer.isEmpty ? value : answer.hasPrefix("y")
    }
}

/// The machine setup runs on.
public struct LiveSetupSystem: SetupSystem {
    public init() {}

    public func run(_ command: [String], interactive: Bool) -> Int32 {
        print("$ " + command.joined(separator: " "))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func program(_ name: String) -> String? {
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return folders.map { "\($0)/\(name)" }.first(where: isProgram)
    }

    public func isProgram(_ path: String) -> Bool { ServerConfiguration.isProgram(path) }

    public func hasPackage(_ name: String) -> Bool {
        switch name {
        case "bubblewrap": return program("bwrap") != nil
        case "libmsquic":
            return ["/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu", "/usr/lib64", "/usr/lib", "/usr/local/lib"]
                .contains { FileManager.default.fileExists(atPath: "\($0)/libmsquic.so.2") }
        default: return false
        }
    }

    public func hasUser(_ name: String) -> Bool { getpwnam(name) != nil }

    public func sandboxProblem() -> String? {
        #if os(Linux)
        HarnessSandbox().problem()
        #else
        "Noodle Server runs its bots on Linux."
        #endif
    }

    public func hostName() -> String {
        String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "Noodle Server")
    }

    public func releaseInfo() -> String { (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? "" }

    public func waitForServer(_ socket: URL) -> Bool {
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: socket.path) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
