import Foundation
import NoodleCore

@MainActor
final class OpenCodeSetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        .init(command: "curl -fsSL https://opencode.ai/v2/install | bash",
              instructions: "Run OpenCode’s official v2 installer in Terminal, then run opencode auth login. Noodle uses your existing OpenCode sign-in; return here and choose Check Again.",
              documentationURL: URL(string: "https://opencode.ai/v2/docs")!)
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await OpenCodeHostProbe.load()
        return result.authenticated ? .authenticated : (result.models.isEmpty ? .unauthenticated : .notRequired)
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        // OpenCode's login is an interactive prompt. A copy Noodle installed is not
        // on the shell's PATH, so name it in full; Terminal can run it from there.
        let standard = HarnessStorage.userHome.appendingPathComponent(".opencode/bin/opencode").path
        let command = installation.executablePath.map { $0 == standard ? "opencode" : "'\($0)'" } ?? "opencode"
        throw HarnessSetupError("Run \(command) auth login in Terminal, complete sign-in, then choose Check Again here.")
    }
}

@MainActor
enum OpenCodeHostProbe {
    static func load() async throws -> OpenCodeInspectionResult {
        try await AgentHostRequest().load(timeout: .seconds(90), noReply: "OpenCode returned no account information.",
            timedOut: "OpenCode inspection timed out.") { $0.inspectOpenCode(reply: $1) }
    }
}
