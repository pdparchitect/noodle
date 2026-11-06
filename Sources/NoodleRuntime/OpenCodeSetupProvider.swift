import Foundation
import NoodleCore
import ProductIdentity

public enum OpenCodeSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://opencode.ai/v2/install | bash",
        instructions: "Run OpenCode’s official v2 installer in Terminal, then return here, choose Check Again and sign in. \(ProductIdentity.current.name) keeps its own sign-in, separate from the one opencode uses in Terminal.",
        documentationURL: URL(string: "https://opencode.ai/v2/docs")!)

    /// A copy Noodle installed is not on the shell's PATH, so name it in full;
    /// Terminal can run it from there. `environment` points it at a profile.
    static func command(for installation: HarnessInstallation, environment: [String: String] = [:]) -> String {
        let standard = HarnessStorage.userHome.appendingPathComponent(".opencode/bin/opencode").path
        let command = installation.executablePath.map { $0 == standard ? "opencode" : "'\($0)'" } ?? "opencode"
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)='\($0.value)' " }.joined() + command
    }
}

@MainActor
public enum OpenCodeHostProbe {
    static func load() async throws -> OpenCodeInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(90), noReply: "OpenCode returned no account information.",
            timedOut: "OpenCode inspection timed out.") { $0.inspectOpenCode(reply: $1) }
    }
}
