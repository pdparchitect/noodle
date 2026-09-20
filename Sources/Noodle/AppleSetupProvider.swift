import Foundation
import NoodleCore

@MainActor final class AppleSetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        HarnessVersionPolicy.updateGuide(for: .init(provider: .apple, executablePath: nil))
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await AppleHostProbe.load()
        if let reason = result.unavailableReason { throw HarnessSetupError(reason) }
        return .notRequired
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try await status(for: installation)
    }
}

@MainActor enum AppleHostProbe {
    static func load() async throws -> AppleHarnessInspection {
        try await AgentHostRequest().load(timeout: .seconds(20), noReply: "The Apple harness returned no model information.",
            timedOut: "Apple model availability check timed out.") { $0.inspectApple(reply: $1) }
    }
}
