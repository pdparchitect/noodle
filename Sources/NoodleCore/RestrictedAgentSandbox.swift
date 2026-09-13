import Foundation
import Darwin

/// Applied by the signed Agent Host BEFORE executing a restricted harness. macOS
/// cannot stack a second Seatbelt sandbox inside the app's inherited sandbox.
/// The whole harness process tree receives this policy, including its tools.
public enum RestrictedAgentSandbox {
    /// Fixed provider directory inside the supplied home. Restricted launches
    /// supply a private home under the bot workspace.
    public static func accountDirectory(provider: HarnessProvider, home: URL) throws -> URL {
        let name: String
        switch provider {
        case .fx: name = ".fx"
        case .grokBuild: name = ".grok"
        case .muse: name = ".config/muse"
        default: throw HarnessSetupError("Unsupported restricted harness account.")
        }
        let directory = home.appendingPathComponent(name, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw HarnessSetupError("Restricted \(provider.displayName) requires an unredirected account directory.")
        }
        return directory
    }

    public static func profile(provider: HarnessProvider, workspace: URL, repository: URL, home: URL,
                               executable: URL, application: URL, temporary: URL) throws -> String {
        let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
        let account = try accountDirectory(provider: provider, home: privateHome)
        var readFiles = [String]()
        if provider == .fx {
            readFiles += ancestorDirectories(of: workspace) + ancestorDirectories(of: account)
            readFiles.append("/Library/Keychains/System.keychain")
        }
        return profile(workspace: workspace,
            executablePaths: [executable.path], application: application,
            readFiles: Array(Set(readFiles)).sorted())
    }

    public static func environment(provider: HarnessProvider, home: URL, workspace: URL? = nil) throws -> [String: String] {
        guard let workspace else { throw HarnessSetupError("A restricted harness requires its bot workspace.") }
        let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
        _ = try accountDirectory(provider: provider, home: privateHome)
        switch provider {
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
                               executableDirectory: URL, application: URL, temporary: URL) -> String {
        profile(workspace: workspace,
                executablePaths: [executableDirectory.path], application: application)
    }

    private static func profile(workspace: URL, executablePaths: [String], application: URL,
                                readFiles: [String] = []) -> String {
        let reads = ["/System", "/usr", "/bin", "/sbin", "/dev", "/Library/Apple",
                     "/Library/Preferences", "/private/etc", "/private/var/db/timezone",
                     AgentStorageLayout(workspace: workspace).package.path, application.path] + executablePaths
        let writes = [workspace.path]
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
        (allow network-outbound)
        (allow mach-lookup
          (global-name "com.apple.system.logger")
          (global-name "com.apple.logd")
          (global-name "com.apple.system.notification_center")
          (global-name "com.apple.trustd")
          (global-name "com.apple.trustd.agent"))
        """
    }

    // Foundation normalizes some /private/var URLs back to /var on macOS.
    // Seatbelt subpaths must use the kernel's actual resolved spelling.
    private static func sandboxPath(_ path: String) -> String {
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
