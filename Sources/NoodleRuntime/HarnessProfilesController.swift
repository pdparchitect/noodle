import Foundation
import Observation
import NoodleCore

/// Noodle-owned harness logins. Each profile signs in through the same
/// account-only session as its harness's default login, pointed at its own home.
@MainActor @Observable
public final class HarnessProfilesController {
    public private(set) var profiles: [HarnessProfile] = []
    public private(set) var authentication: [UUID: HarnessAuthenticationStatus] = [:]
    public private(set) var errors: [UUID: String] = [:]
    public private(set) var activity: [UUID: String] = [:]
    public private(set) var challenges: [UUID: HarnessSignInChallenge] = [:]
    /// The command a profile signs in with from Terminal, once the person asks to.
    public private(set) var terminalSignIns: [UUID: String] = [:]
    @ObservationIgnored private let store: HarnessProfileStore
    /// Where a profile's plan limits go when its sign-in check reads them.
    @ObservationIgnored public var subscriptionUsage: SubscriptionUsageStore?
    /// Called with the profile once a sign-in here completes, so bots waiting on it retry at once.
    @ObservationIgnored public var onSignedIn: ((UUID) -> Void)?
    @ObservationIgnored private var operations: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Who each profile is signed in as, when its check could tell. Kept only while the app runs.
    public private(set) var accounts: [UUID: String] = [:]
    /// The name the check under way reported, until it returns.
    @ObservationIgnored private var reportedAccounts: [UUID: String] = [:]
    @ObservationIgnored private let signOutLogin: @MainActor (HarnessProfile) async throws -> Void

    /// `signOut` removes a profile's login; by default the Agent Host does, as it signs in.
    public init(store: HarnessProfileStore, signOut: (@MainActor (HarnessProfile) async throws -> Void)? = nil) {
        self.store = store
        signOutLogin = signOut ?? { try await HarnessAccountOperation().signOut(profile: $0.id) }
        reload()
    }

    public func profiles(for provider: HarnessProvider) -> [HarnessProfile] {
        profiles.filter { $0.provider == provider }
    }

    public func profile(_ id: UUID?) -> HarnessProfile? {
        profiles.first { $0.id == id }
    }

    /// `id` when it is a profile of the harness named by `harnessIdentifier`; nil otherwise, the harness's default login.
    public func validProfile(_ id: UUID?, harnessIdentifier: String?) -> UUID? {
        guard let profile = profile(id), profile.provider.rawValue == harnessIdentifier else { return nil }
        return profile.id
    }

    func reload() {
        profiles = (try? store.load()) ?? []
    }

    public func create(provider: HarnessProvider, named name: String) throws -> HarnessProfile {
        let profile = try store.create(provider: provider, named: name)
        reload()
        return profile
    }

    public func rename(_ profile: HarnessProfile, to name: String) throws {
        _ = try store.rename(profile, to: name)
        reload()
    }

    public func delete(_ profile: HarnessProfile) throws {
        cancel(profile)
        try store.delete(profile)
        subscriptionUsage?.forget(profile.provider, profile: profile.id)
        authentication[profile.id] = nil
        accounts[profile.id] = nil
        errors[profile.id] = nil
        terminalSignIns[profile.id] = nil
        reload()
    }

    /// Signs the profile out of this app, keeping it to sign in to again. `then` runs once
    /// its login is gone, so the bots that used it can stop using their copies.
    public func signOut(_ profile: HarnessProfile, then done: @escaping @MainActor () -> Void = {}) {
        guard operations[profile.id] == nil else { return }
        let id = profile.id, token = UUID(), signOut = signOutLogin
        errors[id] = nil
        terminalSignIns[id] = nil
        activity[id] = "Signing out…"
        let task = Task { [weak self] in
            defer { self?.finish(id, token: token) }
            do {
                try await signOut(profile)
                done()
                guard let self, self.operations[id]?.id == token else { return }
                self.record(id, .unauthenticated)
                self.subscriptionUsage?.forget(profile.provider, profile: id)
            } catch {
                guard let self, self.operations[id]?.id == token else { return }
                if !(error is CancellationError), !Task.isCancelled { self.errors[id] = error.localizedDescription }
            }
        }
        operations[id] = (token, task)
    }

    private func record(_ id: UUID, _ status: HarnessAuthenticationStatus) {
        authentication[id] = status
        let reported = reportedAccounts.removeValue(forKey: id)
        accounts[id] = status == .authenticated ? reported ?? accounts[id] : nil
    }

    public func refresh(_ installation: HarnessInstallation) async {
        for profile in profiles(for: installation.provider) where operations[profile.id] == nil {
            guard installation.isAvailable, let provider = setupProvider(for: profile) else {
                authentication[profile.id] = nil
                terminalSignIns[profile.id] = nil
                continue
            }
            do {
                let status = try await provider.status(for: installation)
                guard operations[profile.id] == nil, self.profile(profile.id) != nil else { continue }
                record(profile.id, status)
                errors[profile.id] = nil
                if status != .unauthenticated { terminalSignIns[profile.id] = nil }
            } catch is CancellationError { return }
            catch { errors[profile.id] = error.localizedDescription }
        }
    }

    /// A sign-in check for one profile, so a bot waiting on sign-in can ask in the background.
    public func signedIn(_ id: UUID, installation: HarnessInstallation) async -> Bool? {
        guard installation.isAvailable, operations[id] == nil, let profile = profile(id),
              let provider = setupProvider(for: profile),
              let status = try? await provider.status(for: installation),
              operations[id] == nil, self.profile(id) != nil else { return nil }
        record(id, status)
        if status != .unauthenticated { terminalSignIns[id] = nil }
        return status != .unauthenticated
    }

    public func signIn(_ profile: HarnessProfile, installation: HarnessInstallation) {
        guard operations[profile.id] == nil, installation.isAvailable, let provider = setupProvider(for: profile) else { return }
        let id = profile.id, token = UUID()
        errors[id] = nil
        if let command = terminalSignIn(for: profile, installation: installation) {
            terminalSignIns[id] = command
            return
        }
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
                self.record(id, status)
                if status != .unauthenticated { self.onSignedIn?(id) }
            } catch {
                guard let self, self.operations[id]?.id == token else { return }
                if !(error is CancellationError), !Task.isCancelled { self.errors[id] = error.localizedDescription }
            }
        }
        operations[id] = (token, task)
    }

    public func cancel(_ profile: HarnessProfile) {
        terminalSignIns[profile.id] = nil
        guard let operation = operations[profile.id] else { return }
        operation.task.cancel()
        finish(profile.id, token: operation.id)
    }

    public func cancelAll() { profiles.forEach(cancel) }

    private func finish(_ id: UUID, token: UUID) {
        guard operations[id]?.id == token else { return }
        operations[id] = nil; activity[id] = nil; challenges[id] = nil
    }

    private func setupProvider(for profile: HarnessProfile) -> (any HarnessProfileAccount)? {
        let provider = HarnessProfileAccounts.provider(for: profile, store: store)
        (provider as? CodexAccountProvider)?.onUsage = { [weak usage = self.subscriptionUsage] in
            usage?.record($0, provider: .codex, profile: profile.id)
        }
        // Each check runs on a provider of its own, so a name it reports is that check's.
        reportedAccounts[profile.id] = nil
        provider?.onAccount = { [weak self] in self?.reportedAccounts[profile.id] = $0 }
        return provider
    }

    private func terminalSignIn(for profile: HarnessProfile, installation: HarnessInstallation) -> String? {
        HarnessProfileAccounts.terminalSignIn(for: profile, installation: installation, store: store)
    }
}

/// How a profile's login is checked and signed in, for named profiles and default logins alike.
@MainActor enum HarnessProfileAccounts {
    fileprivate static func provider(for profile: HarnessProfile, store: HarnessProfileStore) -> (any HarnessProfileAccount)? {
        switch profile.provider {
        case .codex: CodexAccountProvider(codexHome: store.accountHome(profile), profile: profile.id)
        case .grokBuild, .muse, .claudeCode, .fx, .antigravity, .openCode, .copilot, .devin: HostProfileSetupProvider(profile: profile)
        default: nil
        }
    }

    /// Antigravity and OpenCode have no login the host can run; the person signs
    /// in from Terminal, pointed at the profile's folders.
    static func terminalSignIn(for profile: HarnessProfile, installation: HarnessInstallation,
                               store: HarnessProfileStore) -> String? {
        switch profile.provider {
        case .antigravity: AntigravitySetupProvider.command(for: installation, home: store.loginHome(profile))
        // A private server, so no background service is left running for the profile.
        case .openCode: OpenCodeSetupProvider.command(for: installation, environment: store.environment(profile)) + " auth login --standalone"
        default: nil
        }
    }

    /// Each harness's setup, signing in and checking its default login. Each folder is
    /// made when a check or sign-in first needs it.
    static func defaultLogins(_ store: HarnessProfileStore) -> [HarnessProvider: any HarnessSetupProviding] {
        let guides: [HarnessProvider: HarnessInstallationGuide] = [
            .claudeCode: ClaudeCodeSetupProvider.installationGuide, .fx: FxSetupProvider.installationGuide,
            .grokBuild: GrokSetupProvider.installationGuide, .muse: MuseSetupProvider.installationGuide,
            .openCode: OpenCodeSetupProvider.installationGuide, .antigravity: AntigravitySetupProvider.installationGuide,
            .copilot: CopilotSetupProvider.installationGuide, .devin: DevinSetupProvider.installationGuide
        ]
        var providers: [HarnessProvider: any HarnessSetupProviding] = [.apple: AppleSetupProvider()]
        for provider in HarnessProvider.allCases where provider.supportsProfiles {
            let profile = HarnessProfileStore.defaultRecord(provider)
            let prepare = { _ = try store.defaultProfile(provider) }
            if provider == .codex {
                providers[provider] = CodexAccountProvider(codexHome: store.accountHome(profile), profile: profile.id, prepare: prepare)
            } else if let guide = guides[provider], let account = Self.provider(for: profile, store: store) {
                providers[provider] = DefaultLoginSetupProvider(guide: guide, account: account, profile: profile, store: store, prepare: prepare)
            }
        }
        return providers
    }
}

/// A harness's installation guide, with sign-in and its check on the default login.
@MainActor private final class DefaultLoginSetupProvider: HarnessSetupProviding, HarnessAccountNaming {
    let installationGuide: HarnessInstallationGuide
    let account: any HarnessProfileAccount
    let profile: HarnessProfile
    let store: HarnessProfileStore
    let prepare: () throws -> Void

    init(guide: HarnessInstallationGuide, account: any HarnessProfileAccount, profile: HarnessProfile,
         store: HarnessProfileStore, prepare: @escaping () throws -> Void) {
        installationGuide = guide; self.account = account; self.profile = profile; self.store = store; self.prepare = prepare
    }

    var onAccount: (@MainActor (String) -> Void)? {
        get { account.onAccount }
        set { account.onAccount = newValue }
    }

    func terminalSignIn(for installation: HarnessInstallation) -> String? {
        try? prepare()
        return HarnessProfileAccounts.terminalSignIn(for: profile, installation: installation, store: store)
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try prepare()
        let status = try await account.status(for: installation)
        // OpenCode's free models need no account.
        return profile.provider == .openCode && status == .unauthenticated ? .notRequired : status
    }
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try prepare()
        return try await account.signIn(for: installation, onChallenge: onChallenge)
    }
}

/// The account half of harness setup; a profile has no installation of its own.
@MainActor private protocol HarnessProfileAccount: HarnessAccountNaming {
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus
}

extension CodexAccountProvider: HarnessProfileAccount {}

/// Grok Build, Muse Code, Claude Code, FX, Copilot and Devin sign in through the Agent Host, which
/// resolves the profile's folder itself and runs the harness's own login.
/// Antigravity and OpenCode have no such login: the host only checks the profile.
@MainActor private final class HostProfileSetupProvider: HarnessProfileAccount {
    private let profile: HarnessProfile
    var onAccount: (@MainActor (String) -> Void)?
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
                                                       profile: profile.id, onChallenge: onChallenge,
                                                       onAccount: onAccount)
    }
}
