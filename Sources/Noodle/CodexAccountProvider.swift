import Foundation
import NoodleCore

/// Codex reports its account by being run. The app does that itself for a Codex
/// it can execute. A copy Noodle installed sits in the app's container, where
/// the sandbox refuses the app execute access, so the Agent Host runs it instead.
@MainActor
final class CodexAccountProvider: HarnessSetupProviding {
    private let direct: CodexSetupProvider
    private let profile: UUID?

    init(codexHome: URL, profile: UUID? = nil) {
        direct = CodexSetupProvider(codexHome: codexHome)
        self.profile = profile
    }

    var installationGuide: HarnessInstallationGuide { direct.installationGuide }

    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        guard let path = hostPath(installation) else { return try await direct.status(for: installation) }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: false, provider: .codex, profile: profile)
    }

    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        guard let path = hostPath(installation) else { return try await direct.signIn(for: installation, onChallenge: onChallenge) }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: true, provider: .codex, profile: profile,
                                                       onChallenge: onChallenge)
    }

    private func hostPath(_ installation: HarnessInstallation) -> String? {
        guard installation.provider == .codex, let path = installation.executablePath,
              !FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
