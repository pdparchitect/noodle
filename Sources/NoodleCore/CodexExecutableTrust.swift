import Foundation
import Security

/// Extended access accepts only known installation locations and OpenAI-signed code.
public enum CodexExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let bundled = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        let standalone = [
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            home.appendingPathComponent(".local/bin/codex").path,
            "/usr/local/bin/codex", "/opt/homebrew/bin/codex"
        ]
        guard bundled.contains(path) || standalone.contains(path) else {
            throw HarnessSetupError("Extended access requires an official Codex installation.")
        }
        let requested = URL(fileURLWithPath: path)
        let executable = requested.resolvingSymlinksInPath()
        if bundled.contains(path) {
            guard executable.path == path else { throw HarnessSetupError("Bundled Codex must not be redirected.") }
        } else {
            // The official installer uses symlinks to a versioned package. Validate
            // the resolved package, including tools the main executable can launch.
            guard executable.lastPathComponent == "codex",
                  executable.deletingLastPathComponent().lastPathComponent == "bin" else {
                throw HarnessSetupError("The standalone Codex package layout is unsupported.")
            }
            let package = executable.deletingLastPathComponent().deletingLastPathComponent()
            for (entry, identifier) in [
                "bin/codex": "codex",
                "bin/codex-code-mode-host": "codex-code-mode-host",
                "codex-path/rg": "com.openai.codex.rg",
                "codex-resources/zsh/bin/zsh": "com.openai.codex.zsh"
            ] {
                let tool = package.appendingPathComponent(entry)
                guard tool.resolvingSymlinksInPath().path == tool.standardizedFileURL.path else {
                    throw HarnessSetupError("Codex supporting tools must not be redirected.")
                }
                try verifySignature(tool, identifier: identifier)
            }
        }
        try verifySignature(executable, identifier: "codex")
        return executable
    }

    public static func verifySignature(_ url: URL, identifier: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw HarnessSetupError("Codex’s OpenAI signature could not be verified.")
        }
    }
}
