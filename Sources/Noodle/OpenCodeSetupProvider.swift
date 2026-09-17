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
        let result = try await OpenCodeHostProbe().load()
        return result.authenticated ? .authenticated : (result.models.isEmpty ? .unauthenticated : .notRequired)
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        throw HarnessSetupError("Run opencode auth login in Terminal, complete sign-in, then choose Check Again here.")
    }
}

@MainActor
final class OpenCodeHostProbe {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<OpenCodeInspectionResult, Error>?
    private var timeout: Task<Void, Never>?
    init() throws { connection = try ExtendedAgentConnection() }

    func load() async throws -> OpenCodeInspectionResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
                }
                connection.inspectOpenCode { [weak self] data, error in
                    Task { @MainActor in
                        do {
                            if let error { throw HarnessSetupError(error) }
                            guard let data else { throw HarnessSetupError("OpenCode returned no account information.") }
                            self?.finish(.success(try JSONDecoder().decode(OpenCodeInspectionResult.self, from: data)))
                        } catch { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(HarnessSetupError("OpenCode inspection timed out.")))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func finish(_ result: Result<OpenCodeInspectionResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
