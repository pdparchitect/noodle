import Foundation
import Darwin

/// Applied by the signed Agent Host BEFORE executing restricted Codex. macOS
/// cannot stack a second Seatbelt sandbox inside the app's inherited sandbox.
/// The whole harness process tree receives this policy, including its tools.
public enum RestrictedAgentSandbox {
    public static func profile(workspace: URL, repository: URL, codexHome: URL,
                               executableDirectory: URL, application: URL, temporary: URL) -> String {
        let reads = ["/System", "/usr", "/bin", "/sbin", "/dev", "/Library/Apple",
                     "/Library/Preferences", "/private/etc", "/private/var/db/timezone",
                     repository.path, codexHome.path, executableDirectory.path, application.path]
        let writes = [workspace.path, repository.appendingPathComponent("Conversations").path,
                      codexHome.path, temporary.path]
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
        (allow file-write*
          \(writes.map { "(subpath \(quoted(sandboxPath($0))))" }.joined(separator: "\n  ")))
        (allow file-read* file-write-data file-ioctl (literal "/dev/null") (literal "/dev/tty") (subpath "/dev/fd"))
        (allow network-outbound)
        (allow mach-lookup
          (global-name "com.apple.system.logger")
          (global-name "com.apple.logd")
          (global-name "com.apple.system.notification_center")
          (global-name "com.apple.trustd")
          (global-name "com.apple.trustd.agent")
          (global-name "com.apple.SecurityServer"))
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
}
