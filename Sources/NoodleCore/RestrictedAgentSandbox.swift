import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WindowsPOSIX
#endif

/// Applied by the signed Agent Host BEFORE executing a restricted harness. macOS
/// cannot stack a second Seatbelt sandbox inside the app's inherited sandbox.
/// The whole harness process tree receives this policy, including its tools.
public enum RestrictedAgentSandbox {
    /// Fixed provider directory inside the supplied home. Restricted launches
    /// supply a private home under the bot workspace.
    public static func accountDirectory(provider: HarnessProvider, home: URL) throws -> URL {
        let name: String
        switch provider {
        case .claudeCode: name = ".claude"
        case .fx: name = ".fx"
        case .grokBuild: name = ".grok"
        case .muse: name = ".config/muse"
        case .openCode: name = ".local/share/opencode"
        case .antigravity: name = ".gemini/antigravity-cli"
        case .copilot: name = ".copilot"
        case .devin: name = ".local/share/devin"
        default: throw HarnessSetupError("Unsupported restricted harness account.")
        }
        let directory = home.appendingPathComponent(name, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw HarnessSetupError("Restricted \(provider.displayName) requires an unredirected account directory.")
        }
        return directory
    }

    /// `package` is code the executable runs from outside its own file: Copilot's unpacked package, Devin's version folder.
    public static func profile(provider: HarnessProvider, workspace: URL, repository: URL, home: URL,
                               executable: URL, package: URL? = nil, application: URL, temporary: URL,
                               folders: [AgentFolder] = [], egressPort: UInt16? = nil) throws -> String {
        seatbelt(try policy(provider: provider, workspace: workspace, executable: executable, package: package,
                            application: application, folders: folders, egressPort: egressPort))
    }

    /// What `provider`'s restricted harness may reach, for whichever sandbox renders it.
    public static func policy(provider: HarnessProvider, workspace: URL, executable: URL, package: URL? = nil,
                              application: URL, folders: [AgentFolder] = [], egressPort: UInt16? = nil) throws -> HarnessSandboxPolicy {
        let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
        let account = try accountDirectory(provider: provider, home: privateHome)
        var readFiles = [String]()
        // These walk to their folders from / one directory at a time; Muse Code has since 1.4.2-R4684.1.
        if provider == .fx || provider == .openCode || provider == .muse {
            readFiles += ancestorDirectories(of: workspace) + ancestorDirectories(of: account)
            readFiles += folders.flatMap { ancestorDirectories(of: URL(fileURLWithPath: $0.path)) }
        }
        if provider == .fx || provider == .copilot { readFiles.append("/Library/Keychains/System.keychain") }
        // Muse Code 1.4.4 and later list these for system-wide settings and fail every session without them.
        if provider == .muse { readFiles += ["/Library", "/Library/Application Support"] }
        return HarnessSandboxPolicy(
            workspace: workspace,
            readable: [AgentStorageLayout(workspace: workspace).package.path, application.path, executable.path]
                + (package.map { [$0.path] } ?? []),
            readableFiles: Array(Set(readFiles)).sorted(), folders: folders, egressPort: egressPort, executable: executable.path,
            // OpenCode v2's ACP implementation and Antigravity's language server each listen on 127.0.0.1.
            listensLocally: provider == .openCode || provider == .antigravity,
            // Antigravity runs every shell command in a pseudo-terminal.
            pseudoTerminals: provider == .antigravity,
            // Copilot checks every certificate through macOS's Security service, so exporting the anchors, as for
            // Codex, does not help it.
            securityService: provider == .copilot)
    }

    public static func environment(provider: HarnessProvider, home: URL, workspace: URL? = nil) throws -> [String: String] {
        guard let workspace else { throw HarnessSetupError("A restricted harness requires its bot workspace.") }
        let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
        _ = try accountDirectory(provider: provider, home: privateHome)
        switch provider {
        case .claudeCode:
            return ["HOME": privateHome.path,
                "CLAUDE_CONFIG_DIR": privateHome.appendingPathComponent(".claude").path,
                "CLAUDE_CODE_TMPDIR": workspace.appendingPathComponent(".noodle/tmp").path]
        case .fx:
            var environment = ["HOME": privateHome.path, "FX_PERMISSION_MODE": "ask", "FX_DISABLE_KEYCHAIN": "1",
                "TMPPREFIX": workspace.appendingPathComponent(".noodle/tmp/zsh").path]
            let files = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.fx")
            if files.contains("api-key") {
                environment["AI_GATEWAY_API_KEY"] = String(decoding: try files.read("api-key", limit: 8192), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return environment
        case .grokBuild:
            return ["HOME": privateHome.path, "GROK_SANDBOX": "off"]
        case .openCode:
            return OpenCodeStorage.environment(workspace: workspace)
        case .antigravity:
            return ["HOME": privateHome.path, "AGY_CLI_DISABLE_AUTO_UPDATE": "true"]
        case .copilot:
            return CopilotLaunch.environment.merging(["HOME": privateHome.path]) { _, home in home }
        case .devin:
            return ["HOME": privateHome.path]
        case .muse:
            let storage = workspace.appendingPathComponent(".noodle/muse")
            return ["HOME": privateHome.path, "XDG_CONFIG_HOME": privateHome.appendingPathComponent(".config").path,
                "TBH_CREDENTIAL_BACKEND": "file",
                "XDG_DATA_HOME": storage.appendingPathComponent("data").path,
                "XDG_STATE_HOME": storage.appendingPathComponent("state").path,
                "XDG_RUNTIME_DIR": storage.appendingPathComponent("run").path]
        default: throw HarnessSetupError("Unsupported restricted harness environment.")
        }
    }

    public static func profile(workspace: URL, repository: URL, codexHome: URL,
                               executableDirectory: URL, application: URL, temporary: URL,
                               folders: [AgentFolder] = [], egressPort: UInt16? = nil) -> String {
        seatbelt(HarnessSandboxPolicy(
            workspace: workspace,
            readable: [AgentStorageLayout(workspace: workspace).package.path, application.path, executableDirectory.path],
            folders: folders, egressPort: egressPort))
    }

    /// `policy` as a Seatbelt profile, which the Agent Host applies before it runs the harness.
    public static func seatbelt(_ policy: HarnessSandboxPolicy) -> String {
        let base = baseProfile(policy)
        // That service also fronts the Keychain, so only the verified executable may reach it, never a tool it
        // runs. Its own home keeps the person's keychain out of its search, but not out of reach of a deliberate
        // request.
        if policy.securityService, let executable = policy.executable {
            return base + """

            (allow mach-lookup (require-all (global-name "com.apple.SecurityServer") (process-path \(quoted(sandboxPath(executable))))))
            """
        }
        guard policy.listensLocally, let executable = policy.executable else { return base }
        // The pty extension limits the tree to terminals it opened itself.
        let terminals = !policy.pseudoTerminals ? "" : """

        (allow pseudo-tty)
        (allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
        (allow file-read* file-write* file-ioctl
          (require-all (regex #"^/dev/ttys[0-9]+$") (extension "com.apple.sandbox.pty")))
        """
        // Only that verified executable can listen; tools cannot. Seatbelt's "localhost" token also matches this
        // machine's LAN addresses, so it must not be described as an OS-enforced loopback-only boundary.
        // Siloed, the executable still reaches its own server, which the open profile's outbound rule covered.
        let ownServer = policy.egressPort == nil ? "" : """

        (allow network-outbound
          (require-all
            (process-path \(quoted(sandboxPath(executable))))
            (remote ip "localhost:*")))
        """
        return base + terminals + """

        (allow network-bind network-inbound
          (require-all
            (process-path \(quoted(sandboxPath(executable))))
            (local ip "localhost:*")))
        """ + ownServer
    }

    private static func baseProfile(_ policy: HarnessSandboxPolicy) -> String {
        // The developer tools /usr/bin's python3, git and make run, which hold no one's data.
        let reads = ["/System", "/usr", "/bin", "/sbin", "/dev", "/Library/Apple",
                     "/Library/Preferences", "/private/etc", "/private/var/db/timezone"] + policy.readable
            + policy.folders.map(\.path) + (developerTools().map { [$0.path] } ?? [])
        let readFiles = policy.readableFiles + (FileManager.default.fileExists(atPath: selectedDeveloperLink) ? [selectedDeveloperLink] : [])
        let writes = policy.writable
        let workspace = policy.workspace
        // Unfiltered outbound would also reach every Unix socket on the Mac:
        // ssh-agent, Docker, other apps' daemons and Noodle's own bridges.
        // Name resolution needs mDNSResponder; harness sockets stay in the workspace.
        // Siloed, the only address is the Agent Host's proxy, which also looks names up, so
        // mDNSResponder goes too. "localhost" also matches this Mac's LAN addresses on that port.
        let internet = policy.egressPort.map { "(remote ip \"localhost:\($0)\")" }
            ?? "(remote ip)\n  (literal \"/private/var/run/mDNSResponder\")"
        return """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process-exec process-fork)
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (allow file-read-metadata)
        (allow file-read* file-map-executable
          \(reads.map { "(subpath \(quoted(sandboxPath($0))))" }.joined(separator: "\n  ")))
        \(readFiles.map { "(allow file-read-data (literal \(quoted(sandboxPath($0)))))" }.joined(separator: "\n"))
        (allow file-write*
          \(writes.map { "(subpath \(quoted(sandboxPath($0))))" }.joined(separator: "\n  ")))
        (allow file-read* file-write-data file-ioctl (literal "/dev/null") (literal "/dev/tty") (subpath "/dev/fd"))
        (allow network-outbound
          \(internet)
          (subpath \(quoted(sandboxPath(workspace.path)))))
        (allow mach-lookup
          (global-name "com.apple.system.logger")
          (global-name "com.apple.logd")
          (global-name "com.apple.system.notification_center")
          (global-name "com.apple.trustd")
          (global-name "com.apple.trustd.agent"))
        """
    }

    /// Where an agent's commands are looked for. The developer tools' own come before /usr/bin's stubs, which would
    /// otherwise look each tool up again on every run, as they cannot keep their cache inside the sandbox.
    public static func searchPath(home: URL) -> String {
        ([home.path + "/.local/bin"] + (developerDirectory().map { [$0.path + "/usr/bin"] } ?? [])
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]).joined(separator: ":")
    }

    /// What agents may read for the developer tools: all of Xcode, whose tools load its frameworks from beyond its
    /// Developer folder, or the Command Line Tools' own folder.
    static func developerTools() -> URL? {
        guard let developer = developerDirectory() else { return nil }
        let contents = developer.deletingLastPathComponent()
        guard developer.lastPathComponent == "Developer", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app" else { return developer }
        return contents.deletingLastPathComponent()
    }

    /// Where xcode-select keeps its choice, when one was made.
    private static let selectedDeveloperLink = "/private/var/db/xcode_select_link"

    /// The developer tools /usr/bin's stubs run, found as xcode-select finds them: its choice when one was made,
    /// otherwise Xcode, otherwise the Command Line Tools; nil when there are none.
    static func developerDirectory() -> URL? {
        let files = FileManager.default
        if let chosen = try? files.destinationOfSymbolicLink(atPath: selectedDeveloperLink), files.fileExists(atPath: chosen) {
            return URL(fileURLWithPath: chosen)
        }
        return ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
            .first(where: files.fileExists(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    // Foundation normalizes some /private/var URLs back to /var on macOS.
    // Seatbelt subpaths must use the kernel's actual resolved spelling.
    static func sandboxPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path)
        guard url.path != "/" else { return "/" }
        return sandboxPath(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    private static func ancestorDirectories(of directory: URL) -> [String] {
        // Walk the kernel spelling as text: URL may turn /private/var into
        // /var, accidentally omitting the /private directory component.
        var path = sandboxPath(directory.path)
        var paths = ["/"]
        while let separator = path.lastIndex(of: "/"), separator != path.startIndex {
            path = String(path[..<separator])
            paths.append(path)
        }
        return paths
    }
}
