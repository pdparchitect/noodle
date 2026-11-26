#if os(macOS)
import Foundation
import NoodleCore

/// How a bot's harness runs on a Mac: under the Seatbelt profile Noodle's Agent Host gives a restricted bot,
/// applied by `sandbox-exec` before the harness starts, so the harness and every tool it runs keep to it. The
/// system, the developer tools, the harness's installation and the bot's package can be read, and only the
/// bot's workspace written. The rest of the server's data, the admin's home and every other bot are out of
/// reach. The network is open. Nothing ends a harness's tools when it goes, so the launcher ends its process group.
public struct SeatbeltSandbox: HarnessIsolation {
    public var sandboxExec: URL

    public init(sandboxExec: URL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")) {
        self.sandboxExec = sandboxExec
    }

    /// The profile for the bot at `workspace` running `program`. The one Noodle gives a restricted Codex names no
    /// harness's own folders, so it serves Claude Code too; the installation is readable as a whole, as bubblewrap
    /// mounts it.
    func profile(workspace: URL, program: URL) -> String {
        let installation = HarnessSandbox.installation(of: program)
        let repository = AgentStorageLayout(workspace: workspace).package.deletingLastPathComponent().deletingLastPathComponent()
        return RestrictedAgentSandbox.profile(workspace: workspace, repository: repository,
                                              codexHome: HarnessSandbox.home(workspace: workspace).appendingPathComponent(".codex"),
                                              executableDirectory: installation, application: installation,
                                              temporary: workspace.appendingPathComponent(".noodle/tmp", isDirectory: true))
    }

    public func launch(workspace: URL, program: URL, command: [String], environment: [String: String]) -> HarnessLaunchPlan {
        HarnessLaunchPlan(name: "sandbox-exec", executable: sandboxExec,
                          arguments: ["-p", profile(workspace: workspace, program: program), program.path] + command,
                          environment: environment, directory: workspace, endsGroup: true)
    }

    /// Codex cannot reach the system's certificates from inside the profile, so it gets the public ones in a file
    /// in the bot's package, as Noodle's Agent Host gives them to a restricted Codex.
    public func environment(provider: HarnessProvider, workspace: URL) throws -> [String: String] {
        guard provider == .codex else { return [:] }
        return ["CODEX_CA_CERTIFICATE": try RestrictedCodexCertificates.prepare(workspace: workspace).path]
    }

    /// Why a bot's sandbox cannot be made on this Mac, or nil when it can: a bot's whole sandbox is made around a
    /// program that does nothing.
    public func problem() -> String? {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodled-check-\(UUID().uuidString)/bot/workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent().deletingLastPathComponent()) }
        let probe = Process()
        let errors = Pipe()
        probe.standardError = errors
        probe.standardOutput = FileHandle.nullDevice
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let plan = launch(workspace: workspace, program: URL(fileURLWithPath: "/usr/bin/true"), command: [], environment: [:])
            probe.executableURL = plan.executable
            probe.arguments = plan.arguments
            probe.environment = plan.environment
            probe.currentDirectoryURL = plan.directory
            try probe.run()
        } catch {
            return "noodled could not check the sandbox for bots with \(sandboxExec.path): \(error.localizedDescription)"
        }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        probe.waitUntilExit()
        guard probe.terminationStatus != 0 else { return nil }
        return "macOS cannot make a sandbox for bots here (\(detail.isEmpty ? "status \(probe.terminationStatus)" : detail)). "
            + "Run noodled from a terminal or a service of its own, not from inside another app's sandbox."
    }
}
#endif
