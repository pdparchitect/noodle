import Foundation
import NoodleCore
import ProductIdentity

public enum MuseSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://dev.meta.ai/install.sh | bash",
        instructions: "Run Meta’s official installer in Terminal, then return here, choose Check Again and sign in. \(ProductIdentity.current.name) keeps its own sign-in, separate from the one muse uses in Terminal.",
        documentationURL: URL(string: "https://dev.meta.ai/")!)
}

@MainActor
public enum MuseHostProbe {
    static func load() async throws -> MuseInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(40), noReply: "Muse Code returned no installation information.",
            timedOut: "Muse Code inspection timed out.") { $0.inspectMuse(reply: $1) }
    }
}
