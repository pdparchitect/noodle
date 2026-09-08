import Foundation
import NoodleCore

@MainActor
final class GrokSetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        .init(command: "curl -fsSL https://x.ai/cli/install.sh | bash",
              instructions: "Run xAI’s official installer in Terminal, then run grok login. Noodle uses your existing Grok Build sign-in; return here and choose Check Again.",
              documentationURL: URL(string: "https://grok.com/build")!)
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await GrokHostProbe().load()
        return result.authenticated ? .authenticated : .unauthenticated
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        throw HarnessSetupError("Run grok login in Terminal, complete sign-in, then choose Check Again here.")
    }
}

@MainActor
final class GrokHostProbe {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<GrokInspectionResult, Error>?
    private var timeout: Task<Void, Never>?
    init() throws { connection = try ExtendedAgentConnection() }

    func load() async throws -> GrokInspectionResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
                }
                connection.inspectGrok { [weak self] data, error in
                    Task { @MainActor in
                        do {
                            if let error { throw HarnessSetupError(error) }
                            guard let data else { throw HarnessSetupError("Grok Build returned no account information.") }
                            self?.finish(.success(try JSONDecoder().decode(GrokInspectionResult.self, from: data)))
                        } catch { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(50))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(HarnessSetupError("Grok Build inspection timed out.")))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func finish(_ result: Result<GrokInspectionResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
