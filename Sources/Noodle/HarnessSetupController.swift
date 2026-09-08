import Foundation
import Observation
import NoodleCore

@MainActor @Observable
final class HarnessSetupController {
    private(set) var authentication: [HarnessProvider: HarnessAuthenticationStatus] = [:]
    private(set) var errors: [HarnessProvider: String] = [:]
    private(set) var activity: [HarnessProvider: String] = [:]
    private(set) var challenges: [HarnessProvider: HarnessSignInChallenge] = [:]
    private(set) var checking: Set<HarnessProvider> = []
    private let providers: [HarnessProvider: any HarnessSetupProviding]
    @ObservationIgnored private var operations: [HarnessProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var checkedPaths: [HarnessProvider: String] = [:]

    init(providers: [HarnessProvider: any HarnessSetupProviding]? = nil) {
        self.providers = providers ?? [
            .codex: CodexSetupProvider(codexHome: HarnessStorage.codexHome),
            .claudeCode: ClaudeCodeSetupProvider(),
            .fx: FxSetupProvider()
        ]
    }

    func refresh(_ installations: [HarnessInstallation]) async {
        for installation in installations {
            let id = installation.provider
            guard operations[id] == nil, !checking.contains(id), let provider = providers[id] else { continue }
            guard installation.isAvailable else {
                authentication[id] = nil
                errors[id] = nil
                checkedPaths[id] = nil
                continue
            }
            if checkedPaths[id] != installation.executablePath {
                authentication[id] = nil
                errors[id] = nil
                checkedPaths[id] = installation.executablePath
            }
            checking.insert(id)
            defer { checking.remove(id) }
            do {
                let status = try await provider.status(for: installation)
                try Task.checkCancellation()
                authentication[id] = status
                errors[id] = nil
            } catch is CancellationError { return }
            catch {
                authentication[id] = nil
                errors[id] = error.localizedDescription
            }
        }
    }

    func installationGuide(for id: HarnessProvider) -> HarnessInstallationGuide? {
        providers[id]?.installationGuide
    }

    func signIn(_ installation: HarnessInstallation) {
        let id = installation.provider
        guard operations[id] == nil, let provider = providers[id] else { return }
        errors[id] = nil
        activity[id] = "Starting sign-in…"
        operations[id] = Task {
            defer { activity[id] = nil; challenges[id] = nil; operations[id] = nil }
            do {
                let status = try await provider.signIn(for: installation) { [weak self] challenge in
                    self?.challenges[id] = challenge
                    self?.activity[id] = "Waiting for sign-in…"
                }
                try Task.checkCancellation()
                authentication[id] = status
            } catch {
                if !(error is CancellationError), !Task.isCancelled { errors[id] = error.localizedDescription }
            }
        }
    }

    func cancel(_ id: HarnessProvider) { operations[id]?.cancel() }
    func cancelAll() { for operation in operations.values { operation.cancel() } }
}
