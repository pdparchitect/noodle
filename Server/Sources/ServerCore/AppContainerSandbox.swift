#if os(Windows)
import CWindowsSandbox
import Foundation
import NoodleCore

/// How a bot's harness runs on Windows: in an AppContainer of its own, with the bot's workspace writable, its
/// package and the harness's installation readable, the internet reachable and nothing else: not the local
/// network, not loopback, not other bots, the server's data or anyone's home. Less privileged, as it is by
/// default, it does not even get what Windows lets every app read, only what it grants restricted apps.
public struct AppContainerSandbox: Sendable {
    public var lessPrivileged: Bool

    public init(lessPrivileged: Bool = true) {
        self.lessPrivileged = lessPrivileged
    }

    /// One container per bot, named after its package.
    static func containerName(workspace: URL) -> String {
        "noodled." + AgentStorageLayout(workspace: workspace).package.lastPathComponent
    }

    /// The path as Windows spells it, with backslashes.
    static func native(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }

    private static func grant(_ url: URL, to sid: UnsafeMutableRawPointer, writable: Bool) throws {
        let error = native(url).withCString(encodedAs: UTF16.self) { sandbox_grant($0, sid, writable ? 1 : 0) }
        guard error == 0 else { throw HarnessSetupError("noodled could not let the bot reach \(url.path): Windows error \(error).") }
    }

    /// The container named `name`, made when first asked for. Free it with `sandbox_free_sid`.
    static func container(_ name: String) throws -> UnsafeMutableRawPointer {
        var sid: UnsafeMutableRawPointer?
        let error = name.withCString(encodedAs: UTF16.self) { sandbox_container($0, &sid) }
        guard error == 0, let sid else { throw HarnessSetupError("noodled could not make the bot's AppContainer: Windows error \(error).") }
        return sid
    }

    /// One command line from a program and its arguments, quoted as Windows programs split them again.
    static func commandLine(_ program: String, _ arguments: [String]) -> String {
        ([program] + arguments).map(quote).joined(separator: " ")
    }

    static func quote(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) else { return argument }
        var quoted = "\"", backslashes = 0
        for character in argument {
            switch character {
            case "\\":
                backslashes += 1
            case "\"":
                quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            default:
                quoted += String(repeating: "\\", count: backslashes) + String(character)
                backslashes = 0
            }
        }
        return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    /// An environment block for CreateProcessW: each `name=value` ending in a zero, sorted as Windows expects,
    /// and one more zero after the last.
    static func environmentBlock(_ environment: [String: String]) -> [UInt16] {
        let entries = environment.sorted { $0.key.uppercased() < $1.key.uppercased() }
        return entries.flatMap { Array("\($0.key)=\($0.value)".utf16) + [0] } + [0]
    }
}

extension AppContainerSandbox: HarnessIsolation {
    /// Why bots cannot be isolated here, or nil when they can: a bot's whole container is made around a
    /// program that does nothing, as bubblewrap's check is.
    public func problem() -> String? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-check-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("bot/workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let program = URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe")
            let plan = try launch(workspace: workspace, program: program, command: ["/c", "exit 7"],
                                  environment: try environment(provider: .claudeCode, workspace: workspace))
            let status = try Self.run(plan)
            guard status == 7 else { return "Windows ran the check in an AppContainer, but it ended with status \(status)." }
            return nil
        } catch {
            return "Windows cannot run bots in an AppContainer here: \(error.localizedDescription)"
        }
    }

    public func launch(workspace: URL, program: URL, command: [String], environment: [String: String]) throws -> HarnessLaunchPlan {
        let name = Self.containerName(workspace: workspace)
        let sid = try Self.container(name)
        defer { sandbox_free_sid(sid) }
        try Self.grant(workspace, to: sid, writable: true)
        try Self.grant(AgentStorageLayout(workspace: workspace).package, to: sid, writable: false)
        try Self.grant(HarnessSandbox.installation(of: program), to: sid, writable: false)
        var plan = HarnessLaunchPlan(name: "AppContainer", executable: program, arguments: command,
                                     environment: environment, directory: workspace, endsGroup: true)
        plan.container = AppContainerPlan(name: name, lessPrivileged: lessPrivileged)
        return plan
    }

    /// Where Windows programs look for their home, settings and temporary files, all in the bot's own folders,
    /// and what they need to find Windows itself.
    public func environment(provider: HarnessProvider, workspace: URL) throws -> [String: String] {
        let home = HarnessSandbox.home(workspace: workspace)
        let temporary = workspace.appendingPathComponent(".noodle/tmp", isDirectory: true)
        let roaming = home.appendingPathComponent("AppData/Roaming", isDirectory: true)
        let local = home.appendingPathComponent("AppData/Local", isDirectory: true)
        for folder in [temporary, roaming, local] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        return [
            "HOME": Self.native(home), "USERPROFILE": Self.native(home), "APPDATA": Self.native(roaming),
            "LOCALAPPDATA": Self.native(local), "TEMP": Self.native(temporary), "TMP": Self.native(temporary),
            "TMPDIR": Self.native(temporary), "SystemRoot": system, "windir": system,
            "ComSpec": system + #"\System32\cmd.exe"#, "PATHEXT": ".COM;.EXE;.BAT;.CMD",
        ]
    }

    /// Runs a plan to its end and returns its status, for the check.
    static func run(_ plan: HarnessLaunchPlan) throws -> UInt32 {
        guard let container = plan.container else { throw HarnessSetupError("The plan has no AppContainer.") }
        let sid = try Self.container(container.name)
        defer { sandbox_free_sid(sid) }
        var child = sandbox_child()
        let error = spawn(plan, sid: sid, lessPrivileged: container.lessPrivileged, into: &child)
        guard error == 0 else { throw HarnessSetupError("Windows error \(error)") }
        sandbox_close(child.input)
        let status = sandbox_wait(child.process)
        for handle in [child.output, child.errors, child.process, child.job] { sandbox_close(handle) }
        return status
    }

    static func spawn(_ plan: HarnessLaunchPlan, sid: UnsafeMutableRawPointer, lessPrivileged: Bool,
                      into child: inout sandbox_child) -> UInt32 {
        let program = native(plan.executable)
        var commandLine = Array(Self.commandLine(program, plan.arguments).utf16) + [0]
        var environment = environmentBlock(plan.environment)
        let directory = plan.directory.map(native)
        return program.withCString(encodedAs: UTF16.self) { application in
            func start(_ folder: UnsafePointer<UInt16>?) -> UInt32 {
                sandbox_spawn(sid, lessPrivileged ? 1 : 0, application, &commandLine, &environment, folder, &child)
            }
            guard let directory else { return start(nil) }
            return directory.withCString(encodedAs: UTF16.self) { start($0) }
        }
    }
}
#endif
