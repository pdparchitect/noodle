import Foundation
import NoodleCore
import ProductIdentity

public enum DevinSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://cli.devin.ai/install.sh | bash",
        instructions: "Run Cognition’s official installer in Terminal, then return here, choose Check Again and sign in. \(ProductIdentity.current.name) keeps its own sign-in, separate from the one in Terminal. Devin opens your browser when you sign in.",
        documentationURL: URL(string: "https://docs.devin.ai/cli")!)
}

public enum DevinHostProbe {
    static func load() async throws -> DevinInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(60), noReply: "Devin returned no account information.",
            timedOut: "Devin inspection timed out.") { $0.inspectDevin(reply: $1) }
    }
}
