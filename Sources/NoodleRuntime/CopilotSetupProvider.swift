import Foundation
import NoodleCore
import ProductIdentity

public enum CopilotSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://gh.io/copilot-install | bash",
        instructions: "Run GitHub’s official installer in Terminal, then return here, choose Check Again and sign in. \(ProductIdentity.current.name) keeps its own sign-in, separate from the one copilot uses in Terminal.",
        documentationURL: URL(string: "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli")!)
}

@MainActor
public enum CopilotHostProbe {
    static func load() async throws -> CopilotInspectionResult {
        // The first run unpacks Copilot's package before it answers.
        try await AgentHostRequest().load(timeout: .seconds(60), noReply: "Copilot returned no account information.",
            timedOut: "Copilot inspection timed out.") { $0.inspectCopilot(reply: $1) }
    }
}
