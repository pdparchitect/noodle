import Foundation
import ProductIdentity

/// Agent launches accept only known installation locations and OpenAI-signed code.
public enum CodexExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let bundled = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        let standalone = [
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            home.appendingPathComponent(".local/bin/codex").path,
            "/usr/local/bin/codex", "/opt/homebrew/bin/codex"
        ]
        guard bundled.contains(path) || standalone.contains(path) else {
            throw HarnessSetupError("\(ProductIdentity.current.name) requires an official Codex installation.")
        }
        let requested = URL(fileURLWithPath: path)
        let executable = requested.resolvingSymlinksInPath()
        if bundled.contains(path) {
            guard executable.path == path else { throw HarnessSetupError("Bundled Codex must not be redirected.") }
        } else {
            // The official installer uses symlinks to a versioned package.
            guard executable.lastPathComponent == "codex",
                  executable.deletingLastPathComponent().lastPathComponent == "bin" else {
                throw HarnessSetupError("The standalone Codex package layout is unsupported.")
            }
        }
        try verifySignature(executable, identifier: "codex")
        return executable
    }

    public static func verifySignature(_ url: URL, identifier: String) throws {
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        try VerifiedExecutables.verify(url, requirement: rule) {
            guard HarnessSignatureVerification.unmet(url, requirement: rule) == nil else {
                throw HarnessSetupError("Codex’s OpenAI signature could not be verified.")
            }
        }
    }
}
