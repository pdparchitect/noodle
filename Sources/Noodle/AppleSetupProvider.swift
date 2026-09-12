import Foundation
import NoodleCore

@MainActor final class AppleSetupProvider: HarnessSetupProviding {
    var installationGuide: HarnessInstallationGuide {
        HarnessVersionPolicy.updateGuide(for: .init(provider: .apple, executablePath: nil))
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        let result = try await AppleHostProbe().load()
        if let reason = result.unavailableReason { throw HarnessSetupError(reason) }
        return .notRequired
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try await status(for: installation)
    }
}

@MainActor final class AppleHostProbe {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<AppleHarnessInspection, Error>?
    private var timeout: Task<Void, Never>?
    init() throws { connection = try ExtendedAgentConnection() }

    func load() async throws -> AppleHarnessInspection {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
                }
                connection.inspectApple { [weak self] data, error in
                    Task { @MainActor in
                        do {
                            if let error { throw HarnessSetupError(error) }
                            guard let data else { throw HarnessSetupError("The Apple harness returned no model information.") }
                            self?.finish(.success(try JSONDecoder().decode(AppleHarnessInspection.self, from: data)))
                        } catch { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(.failure(HarnessSetupError("Apple model availability check timed out.")))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func finish(_ result: Result<AppleHarnessInspection, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
