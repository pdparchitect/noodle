import Foundation
import NoodleCore

@MainActor package final class AppleSetupProvider: HarnessSetupProviding {
    package init() {}
    package var installationGuide: HarnessInstallationGuide {
        HarnessVersionPolicy.updateGuide(for: .init(provider: .apple, executablePath: nil))
    }
    package func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await AppleHostProbe.load()
        if let reason = result.unavailableReason { throw HarnessSetupError(reason) }
        return .notRequired
    }
    package func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try await status(for: installation)
    }
}

@MainActor package enum AppleHostProbe {
    package static func load() async throws -> AppleHarnessInspection {
        try await AgentHostRequest().load(timeout: .seconds(20), noReply: "The Apple harness returned no model information.",
            timedOut: "Apple model availability check timed out.") { $0.inspectApple(reply: $1) }
    }
}
