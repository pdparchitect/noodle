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
final class FxModelProbe {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<[HarnessModel], Error>?
    private var timeout: Task<Void, Never>?
    init() throws { connection = try ExtendedAgentConnection() }
    func load(path: String) async throws -> [HarnessModel] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
                }
                connection.fxModels(executablePath: path) { [weak self] data, error in
                    Task { @MainActor in
                        guard let self else { return }
                        do {
                            if let error { throw HarnessSetupError(error) }
                            guard let data else { throw HarnessSetupError("FX returned no models.") }
                            self.finish(.success(try JSONDecoder().decode([HarnessModel].self, from: data)))
                        } catch { self.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(65))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(HarnessSetupError("FX model discovery timed out.")))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<[HarnessModel], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
