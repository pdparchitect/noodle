import Foundation
import NoodleCore
import ProductIdentity

public enum AntigravitySetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
        instructions: "Run Google’s official Antigravity installer in Terminal, then return here, choose Check Again and sign in. \(ProductIdentity.current.name) keeps its own sign-in, separate from the one agy uses in Terminal.",
        documentationURL: URL(string: "https://antigravity.google/docs/cli/install")!)

    /// Antigravity signs in from its interactive prompt. A copy Noodle installed is
    /// not on the shell's PATH, so name it in full. A profile is a separate home.
    public static func command(for installation: HarnessInstallation, home: URL? = nil) -> String {
        let standard = HarnessStorage.userHome.appendingPathComponent(".local/bin/agy").path
        let command = installation.executablePath.map { $0 == standard ? "agy" : "'\($0)'" } ?? "agy"
        return home.map { "HOME='\($0.path)' \(command)" } ?? command
    }
}

@MainActor
public enum AntigravityHostProbe {
    static func load() async throws -> AntigravityInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(60), noReply: "Antigravity returned no account information.",
            timedOut: "Antigravity inspection timed out.") { $0.inspectAntigravity(reply: $1) }
    }
}
