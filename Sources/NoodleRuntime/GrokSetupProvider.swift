import Foundation
import NoodleCore
import ProductIdentity

public enum GrokSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://x.ai/cli/install.sh | bash",
        instructions: "Run xAI’s official installer in Terminal, then return here, choose Check Again and sign in. \(ProductIdentity.current.name) keeps its own sign-in, separate from the one grok uses in Terminal.",
        documentationURL: URL(string: "https://grok.com/build")!)
}

@MainActor
public enum GrokHostProbe {
    static func load() async throws -> GrokInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(50), noReply: "Grok Build returned no account information.",
            timedOut: "Grok Build inspection timed out.") { $0.inspectGrok(reply: $1) }
    }
}
