import XCTest
import ComputerCore
import ContainerizationEXT4
import ContainerizationOCI
import SystemPackage
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

final class ContainerUpgradeSystemChangeTests: XCTestCase {
    private func disk(_ url: URL, files: [String: String], links: [String: String] = [:], owner: UInt32? = nil) throws {
        let formatter = try EXT4.Formatter(FilePath(url.path), minDiskSize: 64 * 1_048_576, journal: .default)
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let stream = InputStream(data: Data(text.utf8))
            stream.open()
            try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o640), buf: stream,
                                 uid: owner, gid: owner, recursion: true)
            stream.close()
        }
        for (path, target) in links {
            try formatter.create(path: FilePath(path), link: FilePath(target), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777), recursion: true)
        }
        try formatter.close()
    }

    // Images name their system in /etc/os-release, often a link into /usr/lib.
    func testAnImageNamesItsSystem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ubuntu = directory.appendingPathComponent("Ubuntu.ext4"), kali = directory.appendingPathComponent("Kali.ext4")
        try disk(ubuntu, files: ["/usr/lib/os-release": "NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_CODENAME=noble\n"],
                 links: ["/etc/os-release": "../usr/lib/os-release"])
        try disk(kali, files: ["/etc/os-release": "ID=kali\nID_LIKE=debian\nVERSION_ID=\"2026.4\"\nVERSION_CODENAME=kali-rolling\n"])
        XCTAssertEqual(ContainerComputer.imageSystem(ofDisk: ubuntu), "ubuntu noble")
        XCTAssertEqual(ContainerComputer.imageSystem(ofDisk: kali), "kali kali-rolling", "a rolling release is one system")
        XCTAssertNil(ContainerComputer.imageSystem(ofDisk: directory.appendingPathComponent("Missing.ext4")))
    }

    // On another system the old programs, package records and library index break the new one: nmap missing its
    // libraries, apt sure Ubuntu's packages are installed. Only people's own files come across.
    func testOnlyPeoplesFilesCrossToAnotherSystem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("Old.ext4"), new = directory.appendingPathComponent("New.ext4")
        try disk(old, files: [
            "/diff/etc/ld.so.cache": "ubuntu libraries", "/diff/usr/bin/nmap": "ubuntu nmap",
            "/diff/var/lib/dpkg/status": "Package: nmap", "/diff/home/agent/notes.txt": "findings",
            "/diff/workspace/report.md": "# Report", "/diff/root/.bash_history": "nmap -sV"
        ], links: ["/diff/home/agent/latest": "notes.txt"], owner: 1000)
        try ContainerComputer.keepPeoplesFiles(from: old, to: new, size: 64 * 1_048_576)
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(new.path))
        XCTAssertEqual(String(decoding: try reader.readFile(at: FilePath("/diff/home/agent/notes.txt")), as: UTF8.self), "findings")
        XCTAssertEqual(try reader.stat(FilePath("/diff/home/agent/notes.txt")).inode.uid, 1000)
        XCTAssertEqual(try reader.stat(FilePath("/diff/home/agent/notes.txt")).inode.mode & 0o777, 0o640)
        XCTAssertEqual(String(decoding: try reader.readFile(at: FilePath("/diff/home/agent/latest")), as: UTF8.self), "findings")
        XCTAssertTrue(reader.exists(FilePath("/diff/workspace/report.md")))
        XCTAssertTrue(reader.exists(FilePath("/diff/root/.bash_history")))
        for path in ["/diff/etc/ld.so.cache", "/diff/usr/bin/nmap", "/diff/var/lib/dpkg/status"] {
            XCTAssertFalse(reader.exists(FilePath(path)), path)
        }
    }
}

final class ComputerPanelOpacityTests: XCTestCase {
    // An app that sets one opacity for every computer's terminal and files, as Rook does, keeps each computer's colours;
    // without one, each computer's own appearance applies, as in Noodle Computer.
    func testAnAppMaySetEveryComputersPanelOpacity() {
        var stored = ComputerAppearance()
        stored.terminalBackground = "102030"
        stored.terminalOpacity = 1
        XCTAssertEqual(ComputerDetailView.panelAppearance(stored, opacity: nil), stored)
        let shown = ComputerDetailView.panelAppearance(stored, opacity: 0.85)
        XCTAssertEqual(shown.terminalOpacity, 0.85)
        XCTAssertEqual(shown.terminalBackground, "102030")
        XCTAssertEqual(ComputerDetailView.panelAppearance(nil, opacity: 0.85).terminalOpacity, 0.85)
    }
}
