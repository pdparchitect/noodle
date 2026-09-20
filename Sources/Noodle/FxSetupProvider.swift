import Foundation
import NoodleCore

@MainActor
final class FxSetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        .init(command: "curl -fsSL https://fx.sh/setup.sh | bash",
              instructions: "Run Vercel’s official FX installer in Terminal, then check the installation here. Sign in here with Vercel, or use fx login codex / fx login grok in Terminal for a subscription account.",
              documentationURL: URL(string: "https://fx.sh/docs")!)
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        guard let path = installation.executablePath else { throw HarnessSetupError("Install FX first.") }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: false, provider: .fx)
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        guard let path = installation.executablePath else { throw HarnessSetupError("Install FX first.") }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: true, provider: .fx, onChallenge: onChallenge)
    }
}

@MainActor
enum FxModelProbe {
    /// Codex only when the app cannot run it itself: a copy Noodle installed.
    static func load(path: String, provider: HarnessProvider = .fx) async throws -> [HarnessModel] {
        try await AgentHostRequest().load(timeout: .seconds(65), noReply: "\(provider.displayName) returned no models.",
            timedOut: "\(provider.displayName) model discovery timed out.") {
            if provider == .codex { $0.codexModels(executablePath: path, reply: $1) }
            else { $0.fxModels(executablePath: path, reply: $1) }
        }
    }
}
