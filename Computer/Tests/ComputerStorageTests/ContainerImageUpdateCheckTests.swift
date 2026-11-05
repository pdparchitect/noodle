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
