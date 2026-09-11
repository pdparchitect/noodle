import XCTest
@testable import NoodleCore

final class HarnessPresentationCacheTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "Noodle.HarnessPresentationCacheTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testMissingOrCorruptCacheLoadsAsEmpty() {
        XCTAssertTrue(HarnessPresentationCache.load(from: defaults).isEmpty)
        for value in [Data("not JSON".utf8), Data("{}".utf8), Data("[{}]".utf8), "wrong value type"] as [Any] {
            defaults.set(value, forKey: HarnessPresentationCache.defaultsKey)
            XCTAssertTrue(HarnessPresentationCache.load(from: defaults).isEmpty)
        }
    }

    func testProviderStatusAndVersionSurviveReload() throws {
        let snapshots = Dictionary(uniqueKeysWithValues: HarnessProvider.allCases.map { provider in
            (provider, HarnessPresentationSnapshot(
                installation: .init(provider: provider, executablePath: "/fixture/\(provider.rawValue)"),
                authentication: provider == .codex ? .unauthenticated : .authenticated,
                version: .init(installedVersion: "1.2.3", latestVersion: "1.2.4",
                               latestCheckedAt: Date(timeIntervalSince1970: 1_700_000_000))))
        })
        HarnessPresentationCache.save(snapshots, to: defaults)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(HarnessPresentationCache.load(from: reloaded), snapshots)

        HarnessPresentationCache.save(snapshots, to: reloaded)
        XCTAssertEqual(HarnessPresentationCache.load(from: defaults), snapshots)
    }

    func testReplacingCacheRemovesOldProvidersAndCanClearEverything() {
        let snapshot = HarnessPresentationSnapshot(
            installation: .init(provider: .fx, executablePath: "/fixture/fx"), authentication: .authenticated)
        HarnessPresentationCache.save([.fx: snapshot], to: defaults)
        XCTAssertEqual(HarnessPresentationCache.load(from: defaults)[.fx], snapshot)

        let replacement = HarnessPresentationSnapshot(
            installation: .init(provider: .muse, executablePath: "/fixture/muse"), authentication: .managedExternally)
        HarnessPresentationCache.save([.muse: replacement], to: defaults)
        XCTAssertEqual(HarnessPresentationCache.load(from: defaults), [.muse: replacement])

        HarnessPresentationCache.save([:], to: defaults)
        XCTAssertTrue(HarnessPresentationCache.load(from: defaults).isEmpty)
    }

    func testLoadingUnavailableInstallationDiscardsStaleAuthenticationAndVersion() throws {
        // Decode a saved record directly: constructing a snapshot would already sanitize it.
        let stale = Data(#"[{"installation":{"provider":"fx"},"authentication":"authenticated","version":{"installedVersion":"1.2.3"}}]"#.utf8)
        defaults.set(stale, forKey: HarnessPresentationCache.defaultsKey)
        let restored = try XCTUnwrap(HarnessPresentationCache.load(from: defaults)[.fx])
        XCTAssertFalse(restored.installation.isAvailable)
        XCTAssertNil(restored.authentication)
        XCTAssertNil(restored.version)
    }

    func testLegacySnapshotWithoutVersionStillRestoresAuthentication() throws {
        let legacy = Data(#"[{"installation":{"provider":"codex","executablePath":"/fixture/codex"},"authentication":"authenticated"}]"#.utf8)
        defaults.set(legacy, forKey: HarnessPresentationCache.defaultsKey)
        let restored = try XCTUnwrap(HarnessPresentationCache.load(from: defaults)[.codex])
        XCTAssertEqual(restored.installation.executablePath, "/fixture/codex")
        XCTAssertEqual(restored.authentication, .authenticated)
        XCTAssertNil(restored.version)
    }
}
