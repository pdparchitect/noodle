import Foundation
import NoodleCore

public enum ClaudeCodeSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(
        command: "curl -fsSL https://claude.ai/install.sh | bash",
        instructions: "Run Anthropic’s official installer in Terminal, then return here and check the installation. Claude Code opens your browser when you sign in.",
        documentationURL: URL(string: "https://code.claude.com/docs/en/quickstart")!
    )
}

@MainActor
public final class HarnessAccountOperation {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<HarnessAuthenticationStatus, Error>?
    private var finished = false
    private var timeout: Task<Void, Never>?

    public init() throws { connection = try ExtendedAgentConnection() }

    /// Account checks and sign-ins run in the isolated Agent Host, so Noodle itself never
    /// reads a harness's private configuration or credentials.
    public func run(executablePath: String, signIn: Bool, provider: HarnessProvider, profile: UUID,
             onChallenge: (@MainActor (HarnessSignInChallenge) -> Void)? = nil,
             onUsage: (@MainActor (SubscriptionUsage) -> Void)? = nil,
             onAccount: (@MainActor (String) -> Void)? = nil) async throws -> HarnessAuthenticationStatus {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
                }
                // Sent by an account check before its reply.
                connection.onAccountName = { name in
                    Task { @MainActor in if let name = HarnessAccountName.from(name) { onAccount?(name) } }
                }
                // Sent by a Codex account check before its reply.
                connection.onAccountUsage = { data in
                    Task { @MainActor in
                        if let usage = try? JSONDecoder().decode(SubscriptionUsage.self, from: data) { onUsage?(usage) }
                    }
                }
                connection.onSignInChallenge = { url, code in
                    Task { @MainActor in
                        // Each vendor's page is pinned; a challenge for any other address is dropped.
                        let challenge: HarnessSignInChallenge?
                        switch provider {
                        case .codex: challenge = CodexSetupProvider.relayedChallenge(url: url, code: code)
                        case .grokBuild, .muse, .copilot: challenge = HarnessProfileLogin.challenge(provider: provider, url: url, code: code)
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
                if signIn { connection.signInProfile(profile: profile, executablePath: executablePath, reply: reply) }
                else { connection.checkProfileAuthentication(profile: profile, executablePath: executablePath, reply: reply) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    /// Signs a profile, or a harness's default login, out in the Agent Host, which
    /// resolves its folder from the identifier and removes its Keychain item.
    public func signOut(profile: UUID) async throws {
        let _: HarnessAuthenticationStatus = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            connection.onFailure = { [weak self] error in
                Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(40))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(HarnessSetupError("Signing out timed out.")))
            }
            connection.signOutProfile(profile: profile) { [weak self] error in
                Task { @MainActor in
                    self?.finish(error.map { .failure(HarnessSetupError($0)) } ?? .success(.unauthenticated))
                }
            }
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
