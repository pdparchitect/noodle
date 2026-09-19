import Foundation
import Observation
import NoodleCore

/// Noodle-owned harness logins. Each profile signs in through the same
/// account-only session as the system profile, pointed at its own home.
@MainActor @Observable
final class HarnessProfilesController {
    private(set) var profiles: [HarnessProfile] = []
    private(set) var authentication: [UUID: HarnessAuthenticationStatus] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var activity: [UUID: String] = [:]
    private(set) var challenges: [UUID: HarnessSignInChallenge] = [:]
    @ObservationIgnored private let store: HarnessProfileStore
    @ObservationIgnored private var operations: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    init(store: HarnessProfileStore) {
        self.store = store
        reload()
    }

    func profiles(for provider: HarnessProvider) -> [HarnessProfile] {
        profiles.filter { $0.provider == provider }
    }

    func profile(_ id: UUID?) -> HarnessProfile? {
        profiles.first { $0.id == id }
    }

    func reload() {
        profiles = (try? store.load()) ?? []
    }

    func create(provider: HarnessProvider, named name: String) throws -> HarnessProfile {
        let profile = try store.create(provider: provider, named: name)
        reload()
        return profile
    }

    func rename(_ profile: HarnessProfile, to name: String) throws {
        _ = try store.rename(profile, to: name)
        reload()
    }

    func delete(_ profile: HarnessProfile) throws {
        cancel(profile)
        try store.delete(profile)
        authentication[profile.id] = nil
        errors[profile.id] = nil
        reload()
    }

    func refresh(_ installation: HarnessInstallation) async {
        for profile in profiles(for: installation.provider) where operations[profile.id] == nil {
            guard installation.isAvailable, let provider = setupProvider(for: profile) else {
                authentication[profile.id] = nil
                continue
            }
            do {
                let status = try await provider.status(for: installation)
                guard operations[profile.id] == nil, self.profile(profile.id) != nil else { continue }
                authentication[profile.id] = status
                errors[profile.id] = nil
            } catch is CancellationError { return }
            catch { errors[profile.id] = error.localizedDescription }
        }
    }

    func signIn(_ profile: HarnessProfile, installation: HarnessInstallation) {
        guard operations[profile.id] == nil, installation.isAvailable, let provider = setupProvider(for: profile) else { return }
        let id = profile.id, token = UUID()
        errors[id] = nil
        activity[id] = "Starting sign-in…"
        let task = Task { [weak self] in
            defer { self?.finish(id, token: token) }
            do {
                let status = try await provider.signIn(for: installation) { [weak self] challenge in
                    guard let self, self.operations[id]?.id == token else { return }
                    self.challenges[id] = challenge
                    self.activity[id] = "Waiting for sign-in…"
                }
                try Task.checkCancellation()
                guard let self, self.operations[id]?.id == token else { return }
                self.authentication[id] = status
            } catch {
                guard let self, self.operations[id]?.id == token else { return }
                if !(error is CancellationError), !Task.isCancelled { self.errors[id] = error.localizedDescription }
            }
        }
        operations[id] = (token, task)
    }

    func cancel(_ profile: HarnessProfile) {
        guard let operation = operations[profile.id] else { return }
        operation.task.cancel()
        finish(profile.id, token: operation.id)
    }

    func cancelAll() { profiles.forEach(cancel) }

    private func finish(_ id: UUID, token: UUID) {
        guard operations[id]?.id == token else { return }
        operations[id] = nil; activity[id] = nil; challenges[id] = nil
    }

    private func setupProvider(for profile: HarnessProfile) -> (any HarnessProfileAccount)? {
        switch profile.provider {
        case .codex: CodexSetupProvider(codexHome: store.accountHome(profile))
        case .grokBuild, .muse: HostProfileSetupProvider(profile: profile)
        default: nil
        }
    }
}

/// The account half of harness setup; a profile has no installation of its own.
@MainActor private protocol HarnessProfileAccount {
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus
}

extension CodexSetupProvider: HarnessProfileAccount {}

/// Grok Build and Muse Code sign in through the Agent Host, which resolves the
/// profile's folder itself and runs the harness's own device-code login.
@MainActor private final class HostProfileSetupProvider: HarnessProfileAccount {
    private let profile: HarnessProfile
    init(profile: HarnessProfile) { self.profile = profile }

    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try await run(installation, signIn: false, onChallenge: nil)
    }
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try await run(installation, signIn: true, onChallenge: onChallenge)
    }
    private func run(_ installation: HarnessInstallation, signIn: Bool,
                     onChallenge: (@MainActor (HarnessSignInChallenge) -> Void)?) async throws -> HarnessAuthenticationStatus {
        guard installation.provider == profile.provider, let path = installation.executablePath else {
            throw HarnessSetupError("Install the harness first.")
        }
        return try await HarnessAccountOperation().run(executablePath: path, signIn: signIn, provider: profile.provider,
                                                       profile: profile.id, onChallenge: onChallenge)
    }
}
