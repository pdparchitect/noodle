import Foundation
import NoodleCore

@MainActor
final class MuseSetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        .init(command: "curl -fsSL https://dev.meta.ai/install.sh | bash",
              instructions: "Run Meta’s official installer in Terminal, then run muse login. Noodle uses Muse’s existing account configuration. Return here and choose Check Again.",
              documentationURL: URL(string: "https://dev.meta.ai/")!)
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await MuseHostProbe().load()
        return result.authentication ?? .managedExternally
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        throw HarnessSetupError("Run muse login in Terminal, then choose Check Again here.")
    }
}

@MainActor
final class MuseHostProbe {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<MuseInspectionResult, Error>?
    private var timeout: Task<Void, Never>?
    init() throws { connection = try ExtendedAgentConnection() }

    func load() async throws -> MuseInspectionResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
                }
                connection.inspectMuse { [weak self] data, error in
                    Task { @MainActor in
                        do {
                            if let error { throw HarnessSetupError(error) }
                            guard let data else { throw HarnessSetupError("Muse Code returned no installation information.") }
                            self?.finish(.success(try JSONDecoder().decode(MuseInspectionResult.self, from: data)))
                        } catch { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(40))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(HarnessSetupError("Muse Code inspection timed out.")))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<MuseInspectionResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
