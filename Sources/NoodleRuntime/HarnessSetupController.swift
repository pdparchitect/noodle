import Foundation
import Observation
import NoodleCore

@MainActor public protocol HarnessInstalling {
    func manages(_ installation: HarnessInstallation) -> Bool
    /// Downloads the vendor's current release and has the Agent Host publish it.
    func install(_ provider: HarnessProvider, progress: @escaping @MainActor (HarnessDownloadProgress) -> Void) async throws
    func remove(_ provider: HarnessProvider) throws
    /// Installed versions, oldest first.
    func versions(_ provider: HarnessProvider) -> [String]
    func remove(_ provider: HarnessProvider, version: String) throws
    /// Whether the person chose Noodle's copy over their own installation.
    func isPreferred(_ provider: HarnessProvider) -> Bool
    func setPreferred(_ preferred: Bool, for provider: HarnessProvider) throws
}

public extension HarnessInstalling {
    func isPreferred(_ provider: HarnessProvider) -> Bool { false }
    func setPreferred(_ preferred: Bool, for provider: HarnessProvider) throws {}
}

@MainActor @Observable
public final class HarnessSetupController {
    public private(set) var authentication: [HarnessProvider: HarnessAuthenticationStatus] = [:]
    public private(set) var errors: [HarnessProvider: String] = [:]
    public private(set) var activity: [HarnessProvider: String] = [:]
    public private(set) var challenges: [HarnessProvider: HarnessSignInChallenge] = [:]
    /// The command a harness signs in with from Terminal, once the person asks to.
    public private(set) var terminalSignIns: [HarnessProvider: String] = [:]
    /// Download fraction while Noodle installs a harness; absent when indeterminate.
    public private(set) var installProgress: [HarnessProvider: Double] = [:]
    public private(set) var checking: Set<HarnessProvider> = []
    public private(set) var snapshots: [HarnessProvider: HarnessPresentationSnapshot]
    private let providers: [HarnessProvider: any HarnessSetupProviding]
    /// Where the default login's plan limits go when a sign-in check reads them.
    @ObservationIgnored public var subscriptionUsage: SubscriptionUsageStore? {
        didSet {
            (providers[.codex] as? CodexAccountProvider)?.onUsage = { [weak usage = self.subscriptionUsage] in
                usage?.record($0, provider: .codex, profile: nil)
            }
        }
    }
    /// Called once a sign-in here completes, so bots waiting on the harness's Default login retry at once.
    @ObservationIgnored public var onSignedIn: ((HarnessProvider) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let versionChecker: (any HarnessVersionChecking)?
    @ObservationIgnored private let installer: (any HarnessInstalling)?
    @ObservationIgnored private var installs: [HarnessProvider: UUID] = [:]
    /// Counts installs and removals, so a refresh that looked earlier cannot undo one.
    @ObservationIgnored private var changes: [HarnessProvider: Int] = [:]
    /// Why the last install failed. A refresh clears a missing harness's error,
    /// and this is still the reason it is missing, until the next attempt.
    @ObservationIgnored private var installFailures: [HarnessProvider: String] = [:]
    public private(set) var checkingVersions = false
    public private(set) var refreshingAll = false
    @ObservationIgnored private(set) var operations: [HarnessProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var signInAttempts: [HarnessProvider: (id: UUID, installation: HarnessInstallation)] = [:]
    @ObservationIgnored private var statusChecks: [HarnessProvider: (id: UUID, installation: HarnessInstallation)] = [:]
    /// Who each harness's default login is signed in as, when its check could tell. Kept only
    /// while the app runs, never in the presentation cache.
    public private(set) var accounts: [HarnessProvider: String] = [:]
    /// The name the check under way reported, until it returns.
    @ObservationIgnored private var reportedAccounts: [HarnessProvider: String] = [:]
    @ObservationIgnored private let signOutLogin: @MainActor (HarnessProfile) async throws -> Void

    /// `signOut` removes a default login; by default the Agent Host does, as it signs in.
    public init(providers: [HarnessProvider: any HarnessSetupProviding]? = nil, defaults: UserDefaults = .standard,
         versionChecker: (any HarnessVersionChecking)? = nil, installer: (any HarnessInstalling)? = nil,
         profiles: HarnessProfileStore? = nil, signOut: (@MainActor (HarnessProfile) async throws -> Void)? = nil) {
        self.defaults = defaults
        self.versionChecker = versionChecker
        self.installer = installer
        let cached = HarnessPresentationCache.load(from: defaults)
        snapshots = cached
        authentication = cached.compactMapValues(\.authentication)
        // Bots without a profile use the app's own login, so that is the one a harness's row checks and signs in.
        self.providers = providers ?? profiles.map(HarnessProfileAccounts.defaultLogins) ?? [:]
        signOutLogin = signOut ?? { try await HarnessAccountOperation().signOut(profile: $0.id) }
        for (id, provider) in self.providers {
            (provider as? any HarnessAccountNaming)?.onAccount = { [weak self] in self?.reportedAccounts[id] = $0 }
        }
    }

    /// How the default login is named where it is a choice beside a harness's profiles.
    public func defaultLoginName(_ id: HarnessProvider) -> String {
        HarnessLoginName.defaultLogin(account: accounts[id], status: authentication[id])
    }

    public var displayedInstallations: [HarnessInstallation] {
        HarnessProvider.allCases.map { snapshots[$0]?.installation ?? HarnessInstallation(provider: $0, executablePath: nil) }
    }

    private func record(_ installation: HarnessInstallation, authentication status: HarnessAuthenticationStatus?) {
        if status != .unauthenticated { terminalSignIns[installation.provider] = nil }
        let reported = reportedAccounts.removeValue(forKey: installation.provider)
        accounts[installation.provider] = status == .authenticated ? reported ?? accounts[installation.provider] : nil
        let previous = snapshots[installation.provider]
        let snapshot = HarnessPresentationSnapshot(installation: installation, authentication: status,
            version: previous?.installation == installation ? previous?.version : nil)
        guard snapshots[installation.provider] != snapshot else { return }
        snapshots[installation.provider] = snapshot
        authentication[installation.provider] = snapshot.authentication
        HarnessPresentationCache.save(snapshots, to: defaults)
    }

    /// True when the harness's row shows an error, a required update, or an available update.
    public func needsAttention(_ id: HarnessProvider) -> Bool {
        if errors[id] != nil { return true }
        guard let snapshot = snapshots[id], snapshot.installation.isAvailable else { return false }
        return snapshot.version?.compatibilityIssue != nil || snapshot.version?.updateAvailable == true
    }

    /// Rediscovers installations, then checks sign-in and versions.
    public func refreshAll(_ runtime: AgentRuntimeCoordinator, forceLatest: Bool = false) async {
        guard !refreshingAll else { return }
        refreshingAll = true
        defer { refreshingAll = false }
        let changes = changes
        await runtime.refreshInstallations()
        guard !Task.isCancelled, !runtime.isRefreshingInstallations else { return }
        await refresh(runtime.installations.filter { changes[$0.provider] == self.changes[$0.provider] },
                      discoveryErrors: runtime.installationErrors)
        await refreshVersions(runtime.installations, forceLatest: forceLatest)
        installAvailableUpdates(runtime)
    }

    public func refreshVersions(_ installations: [HarnessInstallation], forceLatest: Bool = false) async {
        guard let versionChecker, !checkingVersions else { return }
        checkingVersions = true
        defer { checkingVersions = false }
        await withTaskGroup(of: (HarnessInstallation, HarnessVersionReport?).self) { group in
            for installation in installations where installation.isAvailable {
                let previous = snapshots[installation.provider]?.version
                group.addTask { @MainActor in
                    do { return (installation, try await versionChecker.check(installation, previous: previous, forceLatest: forceLatest)) }
                    catch is CancellationError { return (installation, nil) }
                    catch {
                        var report = previous ?? HarnessVersionReport()
                        report.checkError = "Could not inspect the harness version. Try Check Again."
                        return (installation, report)
                    }
                }
            }
            for await (installation, report) in group {
                guard !Task.isCancelled, let report,
                      let previous = snapshots[installation.provider], previous.installation == installation else { continue }
                let updated = HarnessPresentationSnapshot(installation: installation, authentication: previous.authentication, version: report)
                if updated != previous {
                    snapshots[installation.provider] = updated
                    HarnessPresentationCache.save(snapshots, to: defaults)
                }
            }
        }
    }

    public func refresh(_ installations: [HarnessInstallation], discoveryErrors: [HarnessProvider: String] = [:]) async {
        let changes = changes
        for installation in installations {
            let id = installation.provider
            guard let provider = providers[id], changes[id] == self.changes[id] else { continue }
            if let error = discoveryErrors[id] {
                retireStatusCheck(id)
                errors[id] = error
                continue // A failed check is not proof of uninstallation or sign-out.
            }
            if let attempt = signInAttempts[id] {
                guard attempt.installation != installation else { continue }
                cancel(id)
            }
            guard statusChecks[id]?.installation != installation else { continue }
            retireStatusCheck(id)
            guard installation.isAvailable else {
                record(installation, authentication: nil)
                errors[id] = installFailures[id]
                continue
            }
            installFailures[id] = nil
            checking.insert(id)
            let token = UUID()
            statusChecks[id] = (token, installation)
            defer { if statusChecks[id]?.id == token { retireStatusCheck(id) } }
            reportedAccounts[id] = nil
            do {
                let status = try await provider.status(for: installation)
                try Task.checkCancellation()
                guard statusChecks[id]?.id == token else { continue }
                record(installation, authentication: status)
                errors[id] = nil
            } catch is CancellationError { return }
            catch {
                guard statusChecks[id]?.id == token else { continue }
                if snapshots[id]?.installation != installation { record(installation, authentication: nil) }
                errors[id] = error.localizedDescription
            }
        }
    }

    public func installationGuide(for id: HarnessProvider) -> HarnessInstallationGuide? {
        providers[id]?.installationGuide
    }

    /// A sign-in check without the Checking state, so a bot waiting on sign-in can ask in the background.
    public func signedIn(_ installation: HarnessInstallation) async -> Bool? {
        let id = installation.provider
        reportedAccounts[id] = nil
        guard installation.isAvailable, operations[id] == nil, let provider = providers[id],
              let status = try? await provider.status(for: installation),
              operations[id] == nil else { return nil }
        record(installation, authentication: status)
        return status != .unauthenticated
    }

    public func signIn(_ installation: HarnessInstallation) {
        let id = installation.provider
        guard operations[id] == nil, let provider = providers[id] else { return }
        errors[id] = nil
        if let command = provider.terminalSignIn(for: installation) {
            terminalSignIns[id] = command
            return
        }
        retireStatusCheck(id)
        let token = UUID()
        signInAttempts[id] = (token, installation)
        activity[id] = "Starting sign-in…"
        reportedAccounts[id] = nil
        operations[id] = Task { [weak self] in
            defer { self?.finishSignIn(id, token: token) }
            do {
                let status = try await provider.signIn(for: installation) { [weak self] challenge in
                    guard let self, self.signInAttempts[id]?.id == token else { return }
                    self.challenges[id] = challenge
                    self.activity[id] = "Waiting for sign-in…"
                }
                try Task.checkCancellation()
                guard let self, self.signInAttempts[id]?.id == token else { return }
                self.record(installation, authentication: status)
                self.errors[id] = nil
                if status != .unauthenticated { self.onSignedIn?(id) }
            } catch {
                guard let self, self.signInAttempts[id]?.id == token else { return }
                if !(error is CancellationError), !Task.isCancelled { self.errors[id] = error.localizedDescription }
            }
        }
    }

    /// Signs this app's default login for the harness out, leaving the person's own login and
    /// every profile alone. `then` runs once the login is gone, so the bots that used it can
    /// stop using their copies.
    public func signOut(_ installation: HarnessInstallation, then done: @escaping @MainActor () -> Void = {}) {
        let id = installation.provider
        guard operations[id] == nil, id.supportsProfiles, let provider = providers[id] else { return }
        errors[id] = nil
        terminalSignIns[id] = nil
        retireStatusCheck(id)
        // Held like a sign-in, so a refresh under way cannot report the login it removes.
        let token = UUID(), signOut = signOutLogin
        signInAttempts[id] = (token, installation)
        activity[id] = "Signing out…"
        operations[id] = Task { [weak self] in
            defer { self?.finishSignIn(id, token: token) }
            do {
                try await signOut(HarnessProfileStore.defaultRecord(id))
                done()
                guard let self, self.signInAttempts[id]?.id == token else { return }
                self.subscriptionUsage?.forget(id, profile: nil)
                // Read again rather than assumed: OpenCode, for one, still runs its free models.
                self.reportedAccounts[id] = nil
                let status = (try? await provider.status(for: installation)) ?? .unauthenticated
                guard self.signInAttempts[id]?.id == token else { return }
                self.record(installation, authentication: status)
                self.errors[id] = nil
            } catch {
                guard let self, self.signInAttempts[id]?.id == token else { return }
                if !(error is CancellationError), !Task.isCancelled { self.errors[id] = error.localizedDescription }
            }
        }
    }

    static let automaticUpdatesKey = "Noodle.harness.automaticUpdates"
    private static let rejectedVersionsKey = "Noodle.harness.rejectedVersions"

    /// Only for harnesses Noodle installed. One the user installed is theirs to update.
    public var automaticUpdates: Bool {
        get { access(keyPath: \.automaticUpdates); return defaults.object(forKey: Self.automaticUpdatesKey) as? Bool ?? true }
        set { withMutation(keyPath: \.automaticUpdates) { defaults.set(newValue, forKey: Self.automaticUpdatesKey) } }
    }

    /// Releases that failed Noodle's compatibility check and were rolled back.
    private var rejectedVersions: [String: String] {
        get { defaults.dictionary(forKey: Self.rejectedVersionsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.rejectedVersionsKey) }
    }

    /// Checks the harnesses Noodle installed, and only those, for a newer release and installs it.
    public func updateManagedHarnesses(_ runtime: AgentRuntimeCoordinator) async {
        guard automaticUpdates, installer != nil else { return }
        let managed = runtime.installations.filter(isManaged)
        guard !managed.isEmpty else { return }
        await refresh(managed)
        await refreshVersions(managed)
        installAvailableUpdates(runtime)
    }

    private func installAvailableUpdates(_ runtime: AgentRuntimeCoordinator) {
        guard automaticUpdates else { return }
        for installation in runtime.installations where isManaged(installation) {
            let id = installation.provider
            guard let version = snapshots[id]?.version, version.updateAvailable,
                  version.latestVersion != rejectedVersions[id.rawValue] else { continue }
            install(id, runtime: runtime)
        }
    }

    /// Bumped when a harness changes between Noodle's copy and the person's own, which is kept in files.
    private var preferenceRevision = 0

    /// Whether the harness runs on the copy Noodle installed and updates, even beside the person's own.
    public func prefersManaged(_ id: HarnessProvider) -> Bool {
        _ = preferenceRevision
        return installer?.isPreferred(id) ?? false
    }

    /// Runs the harness on Noodle's copy, installing it first when there is none, or back on the
    /// person's own installation. `then` runs once the harness found has changed, so its bots
    /// can restart on it; Noodle's copy, once unused, goes when Noodle next opens.
    public func setPrefersManaged(_ managed: Bool, _ id: HarnessProvider, runtime: AgentRuntimeCoordinator,
                                  then done: @escaping @MainActor () -> Void = {}) {
        guard operations[id] == nil, let installer, canInstall(id), prefersManaged(id) != managed else { return }
        let before = runtime.installations.first { $0.provider == id }?.executablePath
        do { try installer.setPreferred(managed, for: id) } catch {
            errors[id] = error.localizedDescription
            return
        }
        preferenceRevision += 1
        errors[id] = nil
        let changed: @MainActor () -> Void = {
            if runtime.installations.first(where: { $0.provider == id })?.executablePath != before { done() }
        }
        if managed, installer.versions(id).isEmpty {
            install(id, runtime: runtime) { succeeded in if succeeded { changed() } }
            return
        }
        retireStatusCheck(id)
        activity[id] = "Switching…"
        operations[id] = Task { [weak self] in
            guard let self else { return }
            await self.refreshAfterChange(id, runtime: runtime)
            self.activity[id] = nil
            self.operations[id] = nil
            changed()
        }
    }

    public func canInstall(_ id: HarnessProvider) -> Bool { installer != nil && id.supportsManagedInstallation }
    public func isManaged(_ installation: HarnessInstallation) -> Bool { installer?.manages(installation) ?? false }

    /// Installs the vendor's current release, or updates the copy Noodle installed.
    /// `then` reports whether it succeeded.
    public func install(_ id: HarnessProvider, runtime: AgentRuntimeCoordinator,
                        then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard operations[id] == nil, let installer, canInstall(id) else { return }
        retireStatusCheck(id)
        let token = UUID()
        installs[id] = token
        installFailures[id] = nil
        errors[id] = nil
        activity[id] = "Downloading…"
        operations[id] = Task { [weak self] in
            var failure: String?
            do {
                try await installer.install(id) { [weak self] progress in
                    guard let self, self.installs[id] == token else { return }
                    self.installProgress[id] = progress.fraction
                    switch progress.phase {
                    case .downloading: self.activity[id] = "Downloading…"
                    case .verifying: self.activity[id] = "Verifying…"
                    case .unpacking: self.activity[id] = "Unpacking…"
                    case .installing: self.activity[id] = "Installing…"
                    }
                }
                try Task.checkCancellation()
            } catch {
                guard let self, self.installs[id] == token else { return }
                if !(error is CancellationError), !Task.isCancelled { failure = error.localizedDescription }
            }
            guard let self, self.installs[id] == token else { return }
            // Stay busy until the row can show the result, or it would offer Install again.
            self.installProgress[id] = nil
            self.installFailures[id] = failure
            await self.refreshAfterChange(id, runtime: runtime)
            guard self.installs[id] == token else { return }
            if failure == nil, runtime.installations.first(where: { $0.provider == id })?.isAvailable != true {
                // Never end silently on Not installed after reporting no error.
                failure = "\(id.displayName) was downloaded, but Noodle cannot find the installed harness."
                self.installFailures[id] = failure
            }
            let installed = installer.versions(id)
            if failure == nil, self.snapshots[id]?.version?.compatibilityIssue != nil, installed.count > 1, let newest = installed.last {
                // An update Noodle cannot drive must not replace one it can. Do not fetch it again.
                try? installer.remove(id, version: newest)
                self.rejectedVersions[id.rawValue] = newest
                await self.refreshAfterChange(id, runtime: runtime)
                guard self.installs[id] == token else { return }
                failure = "\(id.displayName) \(newest) does not work with this version of Noodle. The previous version was kept."
            }
            if failure != nil, installer.versions(id).isEmpty, installer.isPreferred(id) {
                // Nothing of Noodle's to run, so the person's own installation stays in use.
                try? installer.setPreferred(false, for: id)
                self.preferenceRevision += 1
                await self.refreshAfterChange(id, runtime: runtime)
            }
            self.finishInstall(id)
            if let failure { self.errors[id] = failure }
            done(failure == nil)
        }
    }

    public func removeManaged(_ id: HarnessProvider, runtime: AgentRuntimeCoordinator) {
        guard operations[id] == nil, let installer else { return }
        var failure: String?
        do { try installer.remove(id) } catch { failure = error.localizedDescription }
        Task {
            await refreshAfterChange(id, runtime: runtime)
            if let failure { errors[id] = failure }
        }
    }

    /// Only this harness changed, so only it is looked at again: a full refresh
    /// probes every other harness through the Agent Host and takes far longer.
    /// A refresh already in flight looked too early and must not undo the result.
    private func refreshAfterChange(_ id: HarnessProvider, runtime: AgentRuntimeCoordinator) async {
        changes[id, default: 0] += 1
        retireStatusCheck(id)
        let installation = await runtime.rediscover(id)
        await refresh([installation])
        await refreshVersions([installation], forceLatest: true)
    }

    private func finishInstall(_ id: HarnessProvider) {
        installs[id] = nil; installProgress[id] = nil; activity[id] = nil; operations[id] = nil
    }

    private func retireStatusCheck(_ id: HarnessProvider) { statusChecks[id] = nil; checking.remove(id) }
    private func finishSignIn(_ id: HarnessProvider, token: UUID) {
        guard signInAttempts[id]?.id == token else { return }
        signInAttempts[id] = nil; activity[id] = nil; challenges[id] = nil; operations[id] = nil
    }
    public func cancel(_ id: HarnessProvider) {
        terminalSignIns[id] = nil
        operations[id]?.cancel()
        if let token = signInAttempts[id]?.id { finishSignIn(id, token: token) }
        if installs[id] != nil { finishInstall(id) }
    }
    public func cancelAll() { for id in Array(operations.keys) { cancel(id) } }
}
