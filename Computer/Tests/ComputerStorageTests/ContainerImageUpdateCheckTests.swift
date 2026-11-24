import XCTest
import ComputerCore
import ContainerizationOCI
@testable import ComputerEngine
@testable import NoodleComputer

final class ContainerImageUpdateCheckTests: XCTestCase {
    private let old = "sha256:" + String(repeating: "a", count: 64)
    private let new = "sha256:" + String(repeating: "b", count: 64)
    private let synthesized = "sha256:" + String(repeating: "c", count: 64)

    func testMultiPlatformIndexComparesTheRootDigest() {
        let current = Descriptor(mediaType: MediaTypes.index, digest: old, size: 1)
        let newer = Descriptor(mediaType: MediaTypes.index, digest: new, size: 1)
        XCTAssertEqual(ContainerComputer.imageIsCurrent(stored: old, remote: current) { _ in nil }, true)
        XCTAssertEqual(ContainerComputer.imageIsCurrent(stored: old, remote: newer) { _ in nil }, false)
    }

    // A single-manifest image is stored under an index the pull synthesized,
    // so its digest never matches the registry's; look inside that index.
    func testSingleManifestComparesTheManifestInsideTheSynthesizedIndex() throws {
        let manifest = Descriptor(mediaType: MediaTypes.imageManifest, digest: old, size: 1)
        let index = try JSONEncoder().encode(Index(schemaVersion: 2, manifests: [manifest]))
        let content: (String) -> Data? = { $0 == self.synthesized ? index : nil }
        XCTAssertEqual(ContainerComputer.imageIsCurrent(stored: synthesized, remote: manifest, content: content), true)
        let newer = Descriptor(mediaType: MediaTypes.imageManifest, digest: new, size: 1)
        XCTAssertEqual(ContainerComputer.imageIsCurrent(stored: synthesized, remote: newer, content: content), false)
    }

    // Without the stored index the answer is unknown, never a false "update available".
    func testMissingLocalIndexIsUnknown() {
        let remote = Descriptor(mediaType: MediaTypes.dockerManifest, digest: new, size: 1)
        XCTAssertNil(ContainerComputer.imageIsCurrent(stored: synthesized, remote: remote) { _ in nil })
    }
}

@MainActor final class ContainerImageUpgradeOfferTests: XCTestCase {
    // Upgrade is offered only once the check has found a newer image.
    func testUpgradeIsOfferedOnlyWhenANewerImageIsAvailable() {
        let session = ComputerSession(Computer(name: "Container", kind: .container))
        XCTAssertFalse(session.offersImageUpgrade)
        session.imageUpdateAvailable = true
        XCTAssertTrue(session.offersImageUpgrade)
        let shell = ComputerSession(Computer(name: "SSH", kind: .ssh))
        shell.imageUpdateAvailable = true
        XCTAssertFalse(shell.offersImageUpgrade)
    }
}

@MainActor final class ContainerImageUpdateWatchTests: XCTestCase {
    // Every app that runs these computers keeps this watch going, so a newer image is offered without asking.
    func testWatchingMarksComputersWithANewerImageAndKeepsChecking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let session = ComputerSession(Computer(name: "Desktop", kind: .container))
        store.sessions = [session]
        var checks = 0
        store.imageIsCurrent = { _, _, _ in checks += 1; return false }
        let watch = Task { await store.watchImageUpdates(every: .milliseconds(10)) }
        defer { watch.cancel() }
        for _ in 0..<500 where checks < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertTrue(session.offersImageUpgrade)
    }
}

@MainActor final class ComputerImageUpgradeWindowTests: XCTestCase {
    // The upgrade's own window shows its result when it succeeds, and closes when it ends without one: the app reports
    // a failure itself, and a cancelled upgrade needs nothing more.
    func testTheUpgradeWindowShowsTheResultOrClosesWhenTheUpgradeEnds() async {
        let session = ComputerSession(Computer(name: "Desktop", kind: .container))
        var runs = 0
        let upgraded = ComputerImageUpgrade(session: session) { runs += 1; session.updateResult = "The computer image is up to date." }
        XCTAssertEqual(upgraded.stage, .upgrading)
        await upgraded.run()
        await upgraded.run()
        XCTAssertEqual(upgraded.stage, .finished("The computer image is up to date."))
        XCTAssertEqual(runs, 1, "Showing the window again must not start a second upgrade")
        let failed = ComputerImageUpgrade(session: session) { session.updateResult = nil }
        await failed.run()
        XCTAssertEqual(failed.stage, .closed)
    }
}
