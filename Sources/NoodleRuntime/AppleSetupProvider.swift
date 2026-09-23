import Foundation
import NoodleCore

@MainActor public final class AppleSetupProvider: HarnessSetupProviding {
    public init() {}
    public var installationGuide: HarnessInstallationGuide {
        HarnessVersionPolicy.updateGuide(for: .init(provider: .apple, executablePath: nil))
    }
    public func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await AppleHostProbe.load()
        if let reason = result.unavailableReason { throw HarnessSetupError(reason) }
        return .notRequired
    }
    public func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try await status(for: installation)
    }
}

@MainActor public enum AppleHostProbe {
    public static func load() async throws -> AppleHarnessInspection {
        try await AgentHostRequest().load(timeout: .seconds(20), noReply: "The Apple harness returned no model information.",
            timedOut: "Apple model availability check timed out.") { $0.inspectApple(reply: $1) }
    }
}
