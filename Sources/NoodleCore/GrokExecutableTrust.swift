import Foundation
import Security

public enum GrokExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        guard supportsInstallation(requested: url, resolved: resolved, home: home) else {
            throw HarnessSetupError("Grok Build requires its official native installation at ~/.grok/bin/grok.")
        }
        let rule = "anchor apple generic and identifier \"xai-grok-pager\" and certificate leaf[subject.OU] = \"5Y6N3AJ54S\""
        try HarnessSignatureVerification.verify(resolved, requirement: rule, signatureName: "Grok Build’s xAI signature")
        return resolved
    }

    /// Layout validation only. Every accepted executable must still pass the
    /// pinned xAI signature requirement above before inspection or execution.
    static func supportsInstallation(requested: URL, resolved: URL, home: URL) -> Bool {
        let canonical = home.appendingPathComponent(".grok/bin/grok").standardizedFileURL
        let alias = home.appendingPathComponent(".local/bin/grok").standardizedFileURL
        guard [canonical, alias].contains(requested.standardizedFileURL) else { return false }
        if resolved == canonical { return true }

        // Some installations keep the versioned binary beside the launcher.
        // Only direct, version-named siblings qualify; signature checks still apply.
        if resolved.deletingLastPathComponent().standardizedFileURL == canonical.deletingLastPathComponent() {
            return resolved.lastPathComponent.range(of: #"\Agrok-[0-9]+\.[0-9]+\.[0-9]+\z"#,
                                                     options: .regularExpression) != nil
        }

        let downloads = home.appendingPathComponent(".grok/downloads", isDirectory: true).standardizedFileURL
        // Compare the resolved parent, not a path prefix: a symlink out of this
        // directory (including a redirected downloads directory) is not trusted.
        return resolved.deletingLastPathComponent().standardizedFileURL == downloads &&
            resolved.lastPathComponent.range(
                of: #"\Agrok-(?:[0-9]+\.[0-9]+\.[0-9]+-)?macos-(?:aarch64|x86_64)\z"#,
                options: .regularExpression
            ) != nil
    }
}
