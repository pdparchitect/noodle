import Foundation
import Darwin

/// Applied by the signed Agent Host BEFORE executing a restricted harness. macOS
/// cannot stack a second Seatbelt sandbox inside the app's inherited sandbox.
/// The whole harness process tree receives this policy, including its tools.
public enum RestrictedAgentSandbox {
    /// FX and Grok discover their existing account through HOME. Only that
    /// provider's directory is granted, never the surrounding home directory.
    public static func accountDirectory(provider: HarnessProvider, home: URL) throws -> URL {
        let name: String
        switch provider {
        case .fx: name = ".fx"
        case .grokBuild: name = ".grok"
        default: throw HarnessSetupError("Unsupported restricted ACP harness.")
        }
        let directory = home.appendingPathComponent(name, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw HarnessSetupError("Restricted \(provider.displayName) requires an unredirected account directory.")
        }
        return directory
    }

    public static func profile(provider: HarnessProvider, workspace: URL, repository: URL, home: URL,
                               executable: URL, application: URL, temporary: URL) throws -> String {
        let account = try accountDirectory(provider: provider, home: home)
        // Grok keeps executable code inside its account directory. Account and
        // session writes must never permit replacing its signed installation.
        let protected = provider == .grokBuild
            ? ["bin", "downloads", "bundled", "vendor"].map { account.appendingPathComponent($0).path }
            : []
        var readFiles = [home.path]
        if provider == .fx {
            // FX opens each directory component with O_NOFOLLOW while
            // discovering skills. Permit traversing the exact workspace and
            // account ancestors, without reading their other child files.
            readFiles += ancestorDirectories(of: workspace) + ancestorDirectories(of: account)
            // Zig's TLS certificate scanner reads both macOS certificate
            // stores directly. SystemRootCertificates is already under
            // /System; the second store needs this exact read-only grant.
            readFiles.append("/Library/Keychains/System.keychain")
            // FX's native OAuth store uses Security.framework through its
            // JavaScript helper. securityd checks read access to the backing
            // login Keychain even for metadata queries. Grant the two standard
            // filenames only, with no Keychain writes or directory-wide grant.
            for name in ["login.keychain", "login.keychain-db"] {
                let file = home.appendingPathComponent("Library/Keychains/\(name)")
                guard file.resolvingSymlinksInPath().path == file.path else {
                    throw HarnessSetupError("Restricted FX requires an unredirected login Keychain.")
                }
                readFiles.append(file.path)
            }
        }
        return profile(workspace: workspace, repository: repository, account: account,
                       executablePaths: [executable.path], application: application, temporary: temporary,
                       protectedWrites: protected, protectAccountRoot: true, readFiles: Array(Set(readFiles)).sorted(),
                       services: provider == .fx ? ["com.apple.securityd.xpc"] : [])
    }

    public static func environment(provider: HarnessProvider, home: URL) throws -> [String: String] {
        _ = try accountDirectory(provider: provider, home: home)
        switch provider {
        case .fx:
            // ACP approvals authorize an action; the outer OS sandbox still
            // enforces its paths. Avoid a separate model review for every tool.
            return ["HOME": home.path, "FX_PERMISSION_MODE": "ask"]
        case .grokBuild:
            // Seatbelt cannot be stacked. Agent Host already applied the
            // non-optional outer policy before Grok starts.
            return ["HOME": home.path, "GROK_SANDBOX": "off"]
        default: throw HarnessSetupError("Unsupported restricted ACP harness.")
        }
    }

    public static func profile(workspace: URL, repository: URL, codexHome: URL,
                               executableDirectory: URL, application: URL, temporary: URL) -> String {
        profile(workspace: workspace, repository: repository, account: codexHome,
                executablePaths: [executableDirectory.path], application: application, temporary: temporary)
    }

    private static func profile(workspace: URL, repository: URL, account: URL, executablePaths: [String],
                                application: URL, temporary: URL, protectedWrites: [String] = [],
                                protectAccountRoot: Bool = false, readFiles: [String] = [], services: [String] = []) -> String {
        let reads = ["/System", "/usr", "/bin", "/sbin", "/dev", "/Library/Apple",
                     "/Library/Preferences", "/private/etc", "/private/var/db/timezone",
                     repository.path, account.path, application.path] + executablePaths
        let writes = [workspace.path, repository.appendingPathComponent("Conversations").path,
                      account.path, temporary.path]
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
        \(protectedWrites.map { "(deny file-write* (subpath \(quoted(sandboxPath($0)))))" }.joined(separator: "\n"))
        \(protectAccountRoot ? "(deny file-write-unlink (literal \(quoted(sandboxPath(account.path)))))" : "")
        (allow file-read* file-write-data file-ioctl (literal "/dev/null") (literal "/dev/tty") (subpath "/dev/fd"))
        (allow network-outbound)
        (allow mach-lookup
          (global-name "com.apple.system.logger")
          (global-name "com.apple.logd")
          (global-name "com.apple.system.notification_center")
          (global-name "com.apple.trustd")
          (global-name "com.apple.trustd.agent")
          (global-name "com.apple.SecurityServer")
          \(services.map { "(global-name \(quoted($0)))" }.joined(separator: "\n  ")))
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
