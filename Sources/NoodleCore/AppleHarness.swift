import Foundation
import Security
import Darwin

/// The app consumes this catalogue from the bundled harness. Model identifiers
/// belong to the harness and are deliberately not enumerated in UI code.
public struct AppleHarnessInspection: Codable, Sendable {
    public let models: [HarnessModel]
    public let unavailableReason: String?
    public let version: String
    public init(models: [HarnessModel], unavailableReason: String?, version: String) {
        self.models = models
        self.unavailableReason = unavailableReason
        self.version = version
    }
}

public enum AppleExecutableTrust {
    public static func executable(at path: String, application: URL, requirement: String) throws -> URL {
        let expected = application.appendingPathComponent("Contents/Helpers/NoodleAppleAgent").standardizedFileURL
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate == expected,
              candidate.resolvingSymlinksInPath() == candidate,
              FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw HarnessSetupError("The Apple harness must be the executable bundled with this copy of Noodle.")
        }
        var code: SecStaticCode?, rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let code, let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess else {
            throw HarnessSetupError("The bundled Apple harness signature is invalid. Reinstall Noodle.")
        }
        return candidate
    }
}

/// Applied by Agent Host, before exec. It does not inherit the UI sandbox.
/// Inspection uses the same system-service grants, without bot storage access.
public enum AppleAgentSandbox {
    public static func profile(application: URL, workspace: URL? = nil, repository: URL? = nil) -> String {
        var reads = ["/System", "/usr", "/bin", "/sbin", "/dev", "/Library/Apple",
                     "/Library/Preferences", "/private/etc", "/private/var/db/timezone", application.path]
        if let repository { reads.append(repository.path) }
        var writes: [String] = []
        if let workspace { reads.append(workspace.path); writes.append(workspace.path) }
        if let repository { writes.append(repository.appendingPathComponent("Conversations").path) }
        return """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process-exec process-fork)
        (allow signal (target same-sandbox))
        (allow sysctl-read file-read-metadata)
        (allow user-preference-read
          (preference-domain "kCFPreferencesAnyApplication")
          (preference-domain "com.apple.gms.availability"))
        (allow file-read* file-map-executable
          \(reads.map { "(subpath \(quote(canonical($0))))" }.joined(separator: "\n  ")))
        \(writes.isEmpty ? "" : "(allow file-write* " + writes.map { "(subpath \(quote(canonical($0))))" }.joined(separator: " ") + ")")
        (allow file-read* file-write-data file-ioctl (literal "/dev/null") (subpath "/dev/fd"))
        (allow mach-lookup
          (global-name "com.apple.system.logger")
          (global-name "com.apple.logd")
          (global-name "com.apple.system.notification_center")
          (global-name "com.apple.modelmanager"))
        """
    }

    private static func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path)
        guard url.path != "/" else { return "/" }
        return canonical(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
    }
    private static func quote(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}
