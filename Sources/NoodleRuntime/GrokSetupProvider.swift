import Foundation
import NoodleCore

@MainActor
package final class GrokSetupProvider: HarnessSetupProviding {
    package init() {}
    package var installationGuide: HarnessInstallationGuide {
        .init(command: "curl -fsSL https://x.ai/cli/install.sh | bash",
              instructions: "Run xAI’s official installer in Terminal, then run grok login. Noodle uses your existing Grok Build sign-in; return here and choose Check Again.",
              documentationURL: URL(string: "https://grok.com/build")!)
    }
    package func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await GrokHostProbe.load()
        return result.authenticated ? .authenticated : .unauthenticated
    }
    /// The Agent Host runs Grok Build's own device-code login, as it does for a profile.
    package func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        guard installation.provider == .grokBuild, let path = installation.executablePath else {
            throw HarnessSetupError("Install the harness first.")
        }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: true, provider: .grokBuild, onChallenge: onChallenge)
    }
}

@MainActor
package enum GrokHostProbe {
    static func load() async throws -> GrokInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(50), noReply: "Grok Build returned no account information.",
            timedOut: "Grok Build inspection timed out.") { $0.inspectGrok(reply: $1) }
    }
}
