#if os(Windows)
import CWindowsSandbox
import Foundation
import NoodleCore

/// How a bot's harness runs on Windows: as a restricted, low-integrity copy of the server's account that must
/// also be granted, by a SID of the bot's own, everything it opens. It writes only its workspace, reads its
/// package and the harness's installation besides what Windows lets every user read, and reaches nothing of other
/// bots, the server's data or anyone's home. The network is shared, as with bubblewrap.
public struct RestrictedTokenSandbox: Sendable {
    public init() {}

    /// The name a bot's own SID is made from, after its package.
    static func botName(workspace: URL) -> String {
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

    /// The bot's own SID. Free it with `sandbox_free_sid`.
    static func bot(_ name: String) throws -> UnsafeMutableRawPointer {
        var sid: UnsafeMutableRawPointer?
        let error = name.withCString(encodedAs: UTF16.self) { sandbox_bot($0, &sid) }
        guard error == 0, let sid else { throw HarnessSetupError("noodled could not make the bot's sandbox: Windows error \(error).") }
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

    /// An environment block for CreateProcessAsUserW: each `name=value` ending in a zero, sorted as Windows
    /// expects, and one more zero after the last.
    static func environmentBlock(_ environment: [String: String]) -> [UInt16] {
        let entries = environment.sorted { $0.key.uppercased() < $1.key.uppercased() }
        return entries.flatMap { Array("\($0.key)=\($0.value)".utf16) + [0] } + [0]
    }

    /// What a Windows program needs to find Windows, with `home` standing in for the account's own folders.
    static func environment(home: URL, temporary: URL) -> [String: String] {
        [
            "HOME": native(home), "USERPROFILE": native(home),
            "APPDATA": native(home.appendingPathComponent("AppData/Roaming", isDirectory: true)),
            "LOCALAPPDATA": native(home.appendingPathComponent("AppData/Local", isDirectory: true)),
            "TEMP": native(temporary), "TMP": native(temporary), "TMPDIR": native(temporary),
            "SystemRoot": system, "windir": system, "ComSpec": system + #"\System32\cmd.exe"#,
            "PATHEXT": ".COM;.EXE;.BAT;.CMD", "PATH": searchPath,
        ]
    }

    static var system: String { ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"# }

    /// Windows's own programs, and Git's, which Claude Code runs its commands with.
    static var searchPath: String {
        let programs = ProcessInfo.processInfo.environment["ProgramFiles"] ?? #"C:\Program Files"#
        return [system + #"\System32"#, system, system + #"\System32\WindowsPowerShell\v1.0"#,
                programs + #"\Git\cmd"#, programs + #"\Git\usr\bin"#].joined(separator: ";")
    }
}

extension RestrictedTokenSandbox: HarnessIsolation {
    /// Why bots cannot be isolated here, or nil when they can: a bot's whole sandbox is made around a program
    /// that does nothing, as bubblewrap's check is.
    public func problem() -> String? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-check-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("bot/workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let program = URL(fileURLWithPath: Self.system).appendingPathComponent("System32/cmd.exe")
            let plan = try launch(policy: HarnessSandbox.policy(workspace: workspace, program: program), program: program,
                                  command: ["/c", "exit 7"], environment: try environment(provider: .claudeCode, workspace: workspace))
            let status = try Self.run(plan)
            guard status == 7 else { return "Windows ran the check in a bot's sandbox, but it ended with status \(status)." }
            return nil
        } catch {
            return "Windows cannot run bots in a sandbox here: \(error.localizedDescription)"
        }
    }

    public func launch(policy: HarnessSandboxPolicy, program: URL, command: [String], environment: [String: String]) throws -> HarnessLaunchPlan {
        // A restricted token shares the network; it cannot keep it to one local port.
        if policy.egressPort != nil { throw HarnessSetupError("noodled cannot keep a bot to the silo on Windows yet.") }
        let workspace = policy.workspace
        let name = Self.botName(workspace: workspace)
        let sid = try Self.bot(name)
        defer { sandbox_free_sid(sid) }
        try Self.grant(workspace, to: sid, writable: true)
        for path in policy.readable { try Self.grant(URL(fileURLWithPath: path), to: sid, writable: false) }
        for folder in policy.folders { try Self.grant(URL(fileURLWithPath: folder.path), to: sid, writable: folder.writable) }
        var plan = HarnessLaunchPlan(name: "the bot's sandbox", executable: program, arguments: command,
                                     environment: environment, directory: workspace, endsGroup: true)
        plan.sandbox = name
        return plan
    }

    /// Where Windows programs look for their home, settings and temporary files, all in the bot's own folders,
    /// and what they need to find Windows itself.
    public func environment(provider: HarnessProvider, workspace: URL) throws -> [String: String] {
        let home = HarnessSandbox.home(workspace: workspace)
        let temporary = workspace.appendingPathComponent(".noodle/tmp", isDirectory: true)
        for folder in [temporary, home.appendingPathComponent("AppData/Roaming"), home.appendingPathComponent("AppData/Local")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return Self.environment(home: home, temporary: temporary)
    }

    /// Runs a plan to its end and returns its status, for the check.
    static func run(_ plan: HarnessLaunchPlan) throws -> UInt32 {
        guard let name = plan.sandbox else { throw HarnessSetupError("The plan has no sandbox.") }
        let sid = try Self.bot(name)
        defer { sandbox_free_sid(sid) }
        var child = sandbox_child()
        let error = spawn(plan, sid: sid, into: &child)
        guard error == 0 else { throw HarnessSetupError("Windows error \(error)") }
        sandbox_close(child.input)
        let status = sandbox_wait(child.process)
        sandbox_end(child.job, status)
        sandbox_close_console(child.console, child.consoleInput)
        for handle in [child.output, child.errors, child.process, child.job] { sandbox_close(handle) }
        return status
    }

    static func spawn(_ plan: HarnessLaunchPlan, sid: UnsafeMutableRawPointer, into child: inout sandbox_child) -> UInt32 {
        let program = native(plan.executable)
        var commandLine = Array(Self.commandLine(program, plan.arguments).utf16) + [0]
        var environment = environmentBlock(plan.environment)
        let directory = plan.directory.map(native)
        return program.withCString(encodedAs: UTF16.self) { application in
            func start(_ folder: UnsafePointer<UInt16>?) -> UInt32 {
                sandbox_spawn(sid, application, &commandLine, &environment, folder, &child)
            }
            guard let directory else { return start(nil) }
            return directory.withCString(encodedAs: UTF16.self) { start($0) }
        }
    }
}
#endif
