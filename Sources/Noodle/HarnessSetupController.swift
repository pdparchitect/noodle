import Foundation
import Observation
import NoodleCore

@MainActor protocol HarnessInstalling {
    func manages(_ installation: HarnessInstallation) -> Bool
    /// Downloads the vendor's current release and has the Agent Host publish it.
    func install(_ provider: HarnessProvider, progress: @escaping @MainActor (HarnessDownloadProgress) -> Void) async throws
    func remove(_ provider: HarnessProvider) throws
    /// Installed versions, oldest first.
    func versions(_ provider: HarnessProvider) -> [String]
    func remove(_ provider: HarnessProvider, version: String) throws
}

@MainActor @Observable
final class HarnessSetupController {
    private(set) var authentication: [HarnessProvider: HarnessAuthenticationStatus] = [:]
    private(set) var errors: [HarnessProvider: String] = [:]
    private(set) var activity: [HarnessProvider: String] = [:]
    private(set) var challenges: [HarnessProvider: HarnessSignInChallenge] = [:]
    /// Download fraction while Noodle installs a harness; absent when indeterminate.
    private(set) var installProgress: [HarnessProvider: Double] = [:]
    private(set) var checking: Set<HarnessProvider> = []
    private(set) var snapshots: [HarnessProvider: HarnessPresentationSnapshot]
    private let providers: [HarnessProvider: any HarnessSetupProviding]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let versionChecker: (any HarnessVersionChecking)?
    @ObservationIgnored private let installer: (any HarnessInstalling)?
    @ObservationIgnored private var installs: [HarnessProvider: UUID] = [:]
    /// Counts installs and removals, so a refresh that looked earlier cannot undo one.
    @ObservationIgnored private var changes: [HarnessProvider: Int] = [:]
    /// Why the last install failed. A refresh clears a missing harness's error,
    /// and this is still the reason it is missing, until the next attempt.
    @ObservationIgnored private var installFailures: [HarnessProvider: String] = [:]
    private(set) var checkingVersions = false
    private(set) var refreshingAll = false
    @ObservationIgnored private(set) var operations: [HarnessProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var signInAttempts: [HarnessProvider: (id: UUID, installation: HarnessInstallation)] = [:]
    @ObservationIgnored private var statusChecks: [HarnessProvider: (id: UUID, installation: HarnessInstallation)] = [:]

    init(providers: [HarnessProvider: any HarnessSetupProviding]? = nil, defaults: UserDefaults = .standard,
         versionChecker: (any HarnessVersionChecking)? = nil, installer: (any HarnessInstalling)? = nil) {
        self.defaults = defaults
        self.versionChecker = versionChecker
        self.installer = installer
        let cached = HarnessPresentationCache.load(from: defaults)
        snapshots = cached
        authentication = cached.compactMapValues(\.authentication)
        self.providers = providers ?? [
            .apple: AppleSetupProvider(),
            .codex: CodexAccountProvider(codexHome: HarnessStorage.codexHome),
            .claudeCode: ClaudeCodeSetupProvider(),
            .fx: FxSetupProvider(),
            .grokBuild: GrokSetupProvider(),
            .muse: MuseSetupProvider(),
            .openCode: OpenCodeSetupProvider()
        ]
    }

    var displayedInstallations: [HarnessInstallation] {
        HarnessProvider.allCases.map { snapshots[$0]?.installation ?? HarnessInstallation(provider: $0, executablePath: nil) }
    }

    private func record(_ installation: HarnessInstallation, authentication status: HarnessAuthenticationStatus?) {
        let previous = snapshots[installation.provider]
        let snapshot = HarnessPresentationSnapshot(installation: installation, authentication: status,
            version: previous?.installation == installation ? previous?.version : nil)
        guard snapshots[installation.provider] != snapshot else { return }
        snapshots[installation.provider] = snapshot
        authentication[installation.provider] = snapshot.authentication
        HarnessPresentationCache.save(snapshots, to: defaults)
    }

    /// True when the harness's row shows an error, a required update, or an available update.
    func needsAttention(_ id: HarnessProvider) -> Bool {
        if errors[id] != nil { return true }
        guard let snapshot = snapshots[id], snapshot.installation.isAvailable else { return false }
        return snapshot.version?.compatibilityIssue != nil || snapshot.version?.updateAvailable == true
    }

    /// Rediscovers installations, then checks sign-in and versions.
    func refreshAll(_ runtime: AgentRuntimeCoordinator, forceLatest: Bool = false) async {
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

    func refreshVersions(_ installations: [HarnessInstallation], forceLatest: Bool = false) async {
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

    func refresh(_ installations: [HarnessInstallation], discoveryErrors: [HarnessProvider: String] = [:]) async {
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

    func installationGuide(for id: HarnessProvider) -> HarnessInstallationGuide? {
        providers[id]?.installationGuide
    }

    func signIn(_ installation: HarnessInstallation) {
        let id = installation.provider
        guard operations[id] == nil, let provider = providers[id] else { return }
        retireStatusCheck(id)
        let token = UUID()
        signInAttempts[id] = (token, installation)
        errors[id] = nil
        activity[id] = "Starting sign-in…"
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
            } catch {
                guard let self, self.signInAttempts[id]?.id == token else { return }
                if !(error is CancellationError), !Task.isCancelled { self.errors[id] = error.localizedDescription }
            }
        }
    }

    static let automaticUpdatesKey = "Noodle.harness.automaticUpdates"
    private static let rejectedVersionsKey = "Noodle.harness.rejectedVersions"

    /// Only for harnesses Noodle installed. One the user installed is theirs to update.
    var automaticUpdates: Bool {
        get { access(keyPath: \.automaticUpdates); return defaults.object(forKey: Self.automaticUpdatesKey) as? Bool ?? true }
        set { withMutation(keyPath: \.automaticUpdates) { defaults.set(newValue, forKey: Self.automaticUpdatesKey) } }
    }

    /// Releases that failed Noodle's compatibility check and were rolled back.
    private var rejectedVersions: [String: String] {
        get { defaults.dictionary(forKey: Self.rejectedVersionsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.rejectedVersionsKey) }
    }

    /// Checks the harnesses Noodle installed, and only those, for a newer release and installs it.
    func updateManagedHarnesses(_ runtime: AgentRuntimeCoordinator) async {
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

    func canInstall(_ id: HarnessProvider) -> Bool { installer != nil && id.supportsManagedInstallation }
    func isManaged(_ installation: HarnessInstallation) -> Bool { installer?.manages(installation) ?? false }

    /// Installs the vendor's current release, or updates the copy Noodle installed.
    func install(_ id: HarnessProvider, runtime: AgentRuntimeCoordinator) {
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
            self.finishInstall(id)
            if let failure { self.errors[id] = failure }
        }
    }

    func removeManaged(_ id: HarnessProvider, runtime: AgentRuntimeCoordinator) {
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
        let installation = runtime.refreshInstallation(id)
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
    func cancel(_ id: HarnessProvider) {
        operations[id]?.cancel()
        if let token = signInAttempts[id]?.id { finishSignIn(id, token: token) }
        if installs[id] != nil { finishInstall(id) }
    }
    func cancelAll() { for id in Array(operations.keys) { cancel(id) } }
}
