import Foundation
import NoodleCore

/// Claude account setup is checked by the isolated Agent Host so Noodle itself
/// never receives access to Claude's private configuration or credentials.
@MainActor
final class ClaudeCodeSetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        HarnessInstallationGuide(
            command: "curl -fsSL https://claude.ai/install.sh | bash",
            instructions: "Run Anthropic’s official installer in Terminal, then return here and check the installation. Claude Code opens your browser when you sign in.",
            documentationURL: URL(string: "https://code.claude.com/docs/en/quickstart")!
        )
    }

    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try await request(installation, signIn: false)
    }

    func signIn(
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
        let operation = try ClaudeSetupOperation()
        return try await operation.run(executablePath: executablePath, signIn: signIn)
    }
}

@MainActor
private final class ClaudeSetupOperation {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<HarnessAuthenticationStatus, Error>?
    private var finished = false

    init() throws { connection = try ExtendedAgentConnection() }

    func run(executablePath: String, signIn: Bool) async throws -> HarnessAuthenticationStatus {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let reply: (Bool, String?) -> Void = { [weak self] authenticated, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { self.finish(.failure(HarnessSetupError(error))) }
                        else { self.finish(.success(authenticated ? .authenticated : .unauthenticated)) }
                    }
                }
                if signIn {
                    connection.signIn(provider: .claudeCode, executablePath: executablePath, reply: reply)
                } else {
                    connection.checkAuthentication(provider: .claudeCode, executablePath: executablePath, reply: reply)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<HarnessAuthenticationStatus, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        connection.invalidate()
        continuation.resume(with: result)
    }
}
