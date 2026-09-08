import Foundation
import Security

public enum GrokExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let canonical = home.appendingPathComponent(".grok/bin/grok").standardizedFileURL
        let alias = home.appendingPathComponent(".local/bin/grok").standardizedFileURL
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        let download = home.appendingPathComponent(".grok/downloads/grok-macos-aarch64").standardizedFileURL
        let intelDownload = home.appendingPathComponent(".grok/downloads/grok-macos-x86_64").standardizedFileURL
        guard [canonical, alias].contains(url),
              [canonical, download, intelDownload].contains(resolved) else {
            throw HarnessSetupError("Grok Build requires its official native installation at ~/.grok/bin/grok.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"xai-grok-pager\" and certificate leaf[subject.OU] = \"5Y6N3AJ54S\""
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw HarnessSetupError("Grok Build’s xAI signature could not be verified.")
        }
        return resolved
    }
}
