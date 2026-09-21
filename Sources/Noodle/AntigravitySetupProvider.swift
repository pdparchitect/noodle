import Foundation
import NoodleCore

@MainActor
final class AntigravitySetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        .init(command: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
              instructions: "Run Google’s official Antigravity installer in Terminal, then run agy and sign in. Noodle uses your existing Antigravity sign-in; return here and choose Check Again.",
              documentationURL: URL(string: "https://antigravity.google/docs/cli/install")!)
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try await AntigravityHostProbe.load().authenticated ? .authenticated : .unauthenticated
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        throw HarnessSetupError("Run \(Self.command(for: installation)) in Terminal, complete sign-in, then choose Check Again here.")
    }

    /// Antigravity signs in from its interactive prompt. A copy Noodle installed is
    /// not on the shell's PATH, so name it in full. A profile is a separate home.
    static func command(for installation: HarnessInstallation, home: URL? = nil) -> String {
        let standard = HarnessStorage.userHome.appendingPathComponent(".local/bin/agy").path
        let command = installation.executablePath.map { $0 == standard ? "agy" : "'\($0)'" } ?? "agy"
        return home.map { "HOME='\($0.path)' \(command)" } ?? command
    }
}

@MainActor
enum AntigravityHostProbe {
    static func load() async throws -> AntigravityInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(60), noReply: "Antigravity returned no account information.",
            timedOut: "Antigravity inspection timed out.") { $0.inspectAntigravity(reply: $1) }
    }
}
