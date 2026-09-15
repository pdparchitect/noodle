import Foundation
import Security
import Darwin

/// The app consumes this catalogue from the bundled harness. Model identifiers
/// belong to the harness and are deliberately not enumerated in UI code.
public struct AppleHarnessInspection: Codable, Sendable {
    public let models: [HarnessModel]
    public let unavailableReason: String?
    public let version: String
    public let localModelsSupported: Bool?
    public init(models: [HarnessModel], unavailableReason: String?, version: String, localModelsSupported: Bool? = nil) {
        self.models = models
        self.unavailableReason = unavailableReason
        self.version = version
        self.localModelsSupported = localModelsSupported
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
    public static func profile(application: URL, workspace: URL? = nil, repository: URL? = nil,
                               modelsDirectory: URL? = nil, localModel: Bool = false) -> String {
        var reads = ["/System", "/usr", "/bin", "/sbin", "/dev", "/Library/Apple",
                     "/Library/Preferences", "/private/etc", "/private/var/db/timezone", application.path]
        if let workspace { reads.append(AgentStorageLayout(workspace: workspace).package.path) }
        var writes: [String] = []
        if let workspace { reads.append(workspace.path); writes.append(workspace.path) }
        let imagePreparation: String
        var usesGPU = localModel
        if #available(macOS 27, *) {
            // Foundation Models renders CGImage attachments through Core Image.
            // IOSurface alone allocates a buffer but cannot fill its pixels.
            usesGPU = true
            imagePreparation = "(allow iokit-open (iokit-user-client-class \"IOSurfaceRootUserClient\"))"
        } else { imagePreparation = "" }
        let metalDelegation: String
        if localModel, let cache = metalCacheDirectory {
            // MLX compiles specialized kernels. Apple's separately sandboxed
            // compiler needs extensions for resources this helper already owns.
            // Never delegate model weights, bot files or the wider user cache.
            metalDelegation = """
            (allow file-issue-extension
              (require-all (extension-class "com.apple.app-sandbox.read" "com.apple.app-sandbox.read-write") (subpath \(quote(cache.path)))))
            (allow file-issue-extension
              (require-all (extension-class "com.apple.app-sandbox.read") (subpath \(quote(canonical(application.path))))))
            """
        } else { metalDelegation = "" }
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
        \(modelsDirectory.map { "(allow file-read* (subpath \(quote(canonical($0.path)))))" } ?? "")
        \(writes.isEmpty ? "" : "(allow file-write* " + writes.map { "(subpath \(quote(canonical($0))))" }.joined(separator: " ") + ")")
        (allow file-read* file-write-data file-ioctl (literal "/dev/null") (subpath "/dev/fd"))
        (allow mach-lookup
          (global-name "com.apple.system.logger")
          (global-name "com.apple.logd")
          (global-name "com.apple.system.notification_center")
          (global-name "com.apple.modelmanager"))
        \(imagePreparation)
        \(metalDelegation)
        \(usesGPU ? """
        (allow mach-lookup (global-name "com.apple.MTLCompilerService"))
        (allow iokit-open (iokit-user-client-class "AGXDeviceUserClient"))
        \(metalCacheDirectory.map { "(allow file-read* file-write* (subpath \(quote($0.path))))" } ?? "")
        """ : "")
        """
    }

    /// Metal's binary-archive bookkeeping requires its per-bundle cache on
    /// macOS 27. Keep this identity aligned with AppleAgent-Info.plist; granting
    /// the whole Darwin user cache would expose other applications' data.
    private static var metalCacheDirectory: URL? {
        let count = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard count > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, count) > 1 else { return nil }
        // Resolve only the OS-owned parent. The helper-writable child must
        // never redirect a later launch's grant through a symbolic link.
        // URL.resolvingSymlinksInPath can retain /var on this SDK; Seatbelt
        // evaluates the real /private/var path. Use realpath for the OS parent.
        return URL(fileURLWithPath: canonical(String(cString: buffer)), isDirectory: true)
            .appendingPathComponent("com.pdparchitect.noodle.apple-agent", isDirectory: true)
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
