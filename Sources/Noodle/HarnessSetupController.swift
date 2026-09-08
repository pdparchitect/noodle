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
    private(set) var snapshots: [HarnessProvider: HarnessPresentationSnapshot]
    private let providers: [HarnessProvider: any HarnessSetupProviding]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let versionChecker: (any HarnessVersionChecking)?
    private(set) var checkingVersions = false
    @ObservationIgnored private var operations: [HarnessProvider: Task<Void, Never>] = [:]

    init(providers: [HarnessProvider: any HarnessSetupProviding]? = nil, defaults: UserDefaults = .standard,
         versionChecker: (any HarnessVersionChecking)? = nil) {
        self.defaults = defaults
        self.versionChecker = versionChecker
        let cached = HarnessPresentationCache.load(from: defaults)
        snapshots = cached
        authentication = cached.compactMapValues(\.authentication)
        self.providers = providers ?? [
            .codex: CodexSetupProvider(codexHome: HarnessStorage.codexHome),
            .claudeCode: ClaudeCodeSetupProvider(),
            .fx: FxSetupProvider(),
            .grokBuild: GrokSetupProvider()
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
        for installation in installations {
            let id = installation.provider
            guard operations[id] == nil, !checking.contains(id), let provider = providers[id] else { continue }
            if let error = discoveryErrors[id] {
                errors[id] = error
                continue // A failed check is not proof of uninstallation or sign-out.
            }
            guard installation.isAvailable else {
                record(installation, authentication: nil)
                errors[id] = nil
                continue
            }
            checking.insert(id)
            defer { checking.remove(id) }
            do {
                let status = try await provider.status(for: installation)
                try Task.checkCancellation()
                record(installation, authentication: status)
                errors[id] = nil
            } catch is CancellationError { return }
            catch {
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
                record(installation, authentication: status)
                errors[id] = nil
            } catch {
                if !(error is CancellationError), !Task.isCancelled { errors[id] = error.localizedDescription }
            }
        }
    }

    func cancel(_ id: HarnessProvider) { operations[id]?.cancel() }
    func cancelAll() { for operation in operations.values { operation.cancel() } }
}
