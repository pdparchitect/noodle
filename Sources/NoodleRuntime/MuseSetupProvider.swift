import Foundation
import NoodleCore

@MainActor
public final class MuseSetupProvider: HarnessSetupProviding {
    public init() {}
    public var installationGuide: HarnessInstallationGuide {
        .init(command: "curl -fsSL https://dev.meta.ai/install.sh | bash",
              instructions: "Run Meta’s official installer in Terminal, then run muse login. Noodle uses Muse’s existing account configuration. Return here and choose Check Again.",
              documentationURL: URL(string: "https://dev.meta.ai/")!)
    }
    public func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await MuseHostProbe.load()
        return result.authentication ?? .managedExternally
    }
    /// The Agent Host runs Muse Code's own device-code login, as it does for a profile.
    public func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        guard installation.provider == .muse, let path = installation.executablePath else {
            throw HarnessSetupError("Install the harness first.")
        }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: true, provider: .muse, onChallenge: onChallenge)
    }
}

@MainActor
public enum MuseHostProbe {
    static func load() async throws -> MuseInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(40), noReply: "Muse Code returned no installation information.",
            timedOut: "Muse Code inspection timed out.") { $0.inspectMuse(reply: $1) }
    }
}
