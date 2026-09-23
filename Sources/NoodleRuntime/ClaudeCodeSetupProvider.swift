import Foundation
import NoodleCore

/// Claude account setup is checked by the isolated Agent Host so Noodle itself
/// never receives access to Claude's private configuration or credentials.
@MainActor
package final class ClaudeCodeSetupProvider: HarnessSetupProviding {
    package init() {}
    package var installationGuide: HarnessInstallationGuide {
        HarnessInstallationGuide(
            command: "curl -fsSL https://claude.ai/install.sh | bash",
            instructions: "Run Anthropic’s official installer in Terminal, then return here and check the installation. Claude Code opens your browser when you sign in.",
            documentationURL: URL(string: "https://code.claude.com/docs/en/quickstart")!
        )
    }

    package func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try await request(installation, signIn: false)
    }

    package func signIn(
        for installation: HarnessInstallation,
        onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void
    ) async throws -> HarnessAuthenticationStatus {
        try await request(installation, signIn: true)
    }

    private func request(
        _ installation: HarnessInstallation,
        signIn: Bool
    ) async throws -> HarnessAuthenticationStatus {
        guard installation.provider == .claudeCode, let executablePath = installation.executablePath else {
            throw HarnessSetupError("Install the harness first.")
        }
        let operation = try HarnessAccountOperation()
        return try await operation.run(executablePath: executablePath, signIn: signIn)
    }
}

@MainActor
package final class HarnessAccountOperation {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<HarnessAuthenticationStatus, Error>?
    private var finished = false
    private var timeout: Task<Void, Never>?

    package init() throws { connection = try ExtendedAgentConnection() }

    package func run(executablePath: String, signIn: Bool, provider: HarnessProvider = .claudeCode, profile: UUID? = nil,
             onChallenge: (@MainActor (HarnessSignInChallenge) -> Void)? = nil) async throws -> HarnessAuthenticationStatus {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
                }
                connection.onSignInChallenge = { url, code in
                    Task { @MainActor in
                        // Each vendor's page is pinned; a challenge for any other address is dropped.
                        let challenge: HarnessSignInChallenge?
                        switch provider {
                        case .codex: challenge = CodexSetupProvider.relayedChallenge(url: url, code: code)
                        case .grokBuild, .muse: challenge = HarnessProfileLogin.challenge(provider: provider, url: url, code: code)
                        default: challenge = FxProtocol.loginChallenge("Open \(url)\nCode: \(code)\n")
                        }
                        if let challenge { onChallenge?(challenge) }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(signIn ? 600 : 40))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(HarnessSetupError("Harness account check timed out.")))
                }
                let reply: (Bool, String?) -> Void = { [weak self] authenticated, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { self.finish(.failure(HarnessSetupError(error))) }
                        else { self.finish(.success(authenticated ? .authenticated : .unauthenticated)) }
                    }
                }
                if let profile {
                    if signIn { connection.signInProfile(profile: profile, executablePath: executablePath, reply: reply) }
                    else { connection.checkProfileAuthentication(profile: profile, executablePath: executablePath, reply: reply) }
                } else if signIn {
                    connection.signIn(provider: provider, executablePath: executablePath, reply: reply)
                } else {
                    connection.checkAuthentication(provider: provider, executablePath: executablePath, reply: reply)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<HarnessAuthenticationStatus, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        timeout?.cancel()
        self.continuation = nil
        connection.invalidate()
        continuation.resume(with: result)
    }
}
