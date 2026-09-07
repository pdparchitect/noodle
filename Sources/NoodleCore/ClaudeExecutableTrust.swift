import Foundation
import Security

/// Autonomous access accepts only Anthropic's signed native Claude Code install.
public enum ClaudeExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let officialLink = home.appendingPathComponent(".local/bin/claude").standardizedFileURL
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        guard requested == officialLink else {
            throw HarnessSetupError("Autonomous access requires Claude Code’s official native installation.")
        }

        let executable = requested.resolvingSymlinksInPath()
        let versions = home.appendingPathComponent(".local/share/claude/versions", isDirectory: true)
            .standardizedFileURL
        guard executable.deletingLastPathComponent().standardizedFileURL == versions,
              executable.lastPathComponent.range(
                of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?$"#,
                options: .regularExpression
              ) != nil,
              executable.resolvingSymlinksInPath() == executable.standardizedFileURL else {
            throw HarnessSetupError("The Claude Code installation layout is unsupported or redirected.")
        }

        try verifySignature(executable)
        return executable
    }

    public static func verifySignature(_ url: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess else {
            throw HarnessSetupError("Claude Code’s Anthropic signature could not be verified.")
        }
    }
}
