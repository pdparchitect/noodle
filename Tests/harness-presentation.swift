import Foundation
import NoodleCore

// Only deterministic providers are used; this fixture never launches a real harness.
@MainActor final class FixtureSetupProvider: HarnessSetupProviding {
    var statusValue: HarnessAuthenticationStatus = .authenticated
    var hold = false
    var failure = false
    var continuation: CheckedContinuation<Void, Never>?
    var installationGuide: HarnessInstallationGuide {
        .init(command: nil, instructions: "Fixture", documentationURL: URL(string: "https://example.com")!)
    }
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        if hold { await withCheckedContinuation { continuation = $0 } }
        if failure { throw HarnessSetupError("Test check failed") }
        return statusValue
    }
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        statusValue
    }
    func resume() { continuation?.resume(); continuation = nil; hold = false }
}
typealias ClaudeCodeSetupProvider = FixtureSetupProvider
typealias FxSetupProvider = FixtureSetupProvider
typealias GrokSetupProvider = FixtureSetupProvider
typealias MuseSetupProvider = FixtureSetupProvider

@MainActor final class FixtureVersionChecker: HarnessVersionChecking {
    var failure = false
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    var forced = false
    func check(_ installation: HarnessInstallation, previous: HarnessVersionReport?, forceLatest: Bool) async throws -> HarnessVersionReport {
        forced = forceLatest
        if hold { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        if failure { throw HarnessSetupError("Fixture unavailable") }
        return .init(installedVersion: "1.0.0", latestVersion: "2.0.0")
    }
    func resume() { continuation?.resume(); continuation = nil; hold = false }
}

@main struct HarnessPresentationChecks {
    @MainActor static func main() async throws {
        let suite = "noodle-harness-presentation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = FixtureSetupProvider()
        let versions = FixtureVersionChecker()
        let installed = HarnessInstallation(provider: .grokBuild, executablePath: "/fixture/grok")
        let absent = HarnessInstallation(provider: .grokBuild, executablePath: nil)
        func controller() -> HarnessSetupController {
            HarnessSetupController(providers: [.grokBuild: provider], defaults: defaults, versionChecker: versions)
        }
        let initial = controller()
        precondition(initial.snapshots.isEmpty, "No cache must mean unknown, not confirmed missing")
        await initial.refresh([installed])
        let reopened = controller()
        precondition(reopened.authentication[.grokBuild] == .authenticated)
        precondition(reopened.snapshots[.grokBuild]?.installation == installed)
        let saved = defaults.data(forKey: HarnessPresentationCache.defaultsKey)

        provider.hold = true
        let refresh = Task { await reopened.refresh([installed]) }
        while provider.continuation == nil { await Task.yield() }
        precondition(reopened.authentication[.grokBuild] == .authenticated)
        precondition(reopened.snapshots[.grokBuild]?.installation == installed)
        provider.resume()
        await refresh.value
        precondition(defaults.data(forKey: HarnessPresentationCache.defaultsKey) == saved, "Unchanged checks must not rewrite presentation")

        await reopened.refresh([absent], discoveryErrors: [.grokBuild: "Probe unavailable"])
        precondition(reopened.snapshots[.grokBuild]?.installation == installed)
        precondition(reopened.authentication[.grokBuild] == .authenticated)
        provider.failure = true
        await reopened.refresh([installed])
        precondition(reopened.authentication[.grokBuild] == .authenticated, "A failed check is not a sign-out")
        provider.failure = false

        provider.hold = true
        provider.statusValue = .unauthenticated
        let cancelled = Task { await reopened.refresh([installed]) }
        while provider.continuation == nil { await Task.yield() }
        cancelled.cancel()
        provider.resume()
        await cancelled.value
        precondition(reopened.authentication[.grokBuild] == .authenticated)

        await reopened.refresh([installed])
        precondition(reopened.authentication[.grokBuild] == .unauthenticated)
        precondition(controller().authentication[.grokBuild] == .unauthenticated)
        precondition(reopened.errors[.grokBuild] == nil)
        await reopened.refreshVersions([installed], forceLatest: true)
        precondition(versions.forced)
        precondition(reopened.snapshots[.grokBuild]?.version?.updateAvailable == true)
        precondition(controller().snapshots[.grokBuild]?.version?.installedVersion == "1.0.0")
        precondition(reopened.authentication[.grokBuild] == .unauthenticated, "Version checks cannot change sign-in")
        versions.failure = true
        await reopened.refreshVersions([installed])
        precondition(reopened.snapshots[.grokBuild]?.version?.installedVersion == "1.0.0")
        precondition(reopened.snapshots[.grokBuild]?.version?.checkError != nil)
        versions.failure = false
        versions.hold = true
        let beforeCancel = reopened.snapshots
        let versionRefresh = Task { await reopened.refreshVersions([installed]) }
        while versions.continuation == nil { await Task.yield() }
        precondition(reopened.snapshots == beforeCancel, "Pending probes retain the last result")
        versionRefresh.cancel()
        versions.resume()
        await versionRefresh.value
        precondition(reopened.snapshots == beforeCancel)
        await reopened.refresh([absent])
        precondition(reopened.snapshots[.grokBuild]?.version == nil)
        precondition(reopened.authentication[.grokBuild] == nil)
        precondition(controller().snapshots[.grokBuild]?.installation == absent)
        defaults.set(Data("corrupt cache".utf8), forKey: HarnessPresentationCache.defaultsKey)
        precondition(controller().snapshots.isEmpty)
        print("Harness presentation cache, stable refresh, failure, cancellation and removal checks passed")
    }
}
