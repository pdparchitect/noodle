import XCTest
@testable import NoodleCore

final class ManagedHarnessTests: XCTestCase {
    private var root: URL!
    private var store: ManagedHarnessStore { ManagedHarnessStore(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-managed-harness-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testEveryExternalHarnessIsInstallable() {
        XCTAssertEqual(HarnessProvider.allCases.filter { !$0.supportsManagedInstallation }, [.apple])
        for provider in HarnessProvider.allCases where provider != .apple {
            let distribution = HarnessDistribution(provider)
            XCTAssertEqual(distribution?.provider, provider)
            XCTAssertEqual(distribution.map { $0.allows($0.latest) }, true, "\(provider) cannot reach its own release pointer")
        }
    }

    func testGrokMuseAndOpenCodeRecipesMatchTheVendorInstallers() throws {
        let grok = try XCTUnwrap(HarnessDistribution.grokBuild.release(from: Data("1.0.34\n".utf8)))
        XCTAssertTrue(grok.artifact.absoluteString.hasPrefix("https://x.ai/cli/grok-1.0.34-macos-"))
        XCTAssertNil(grok.checksums)

        let muse = HarnessDistribution.muse
        let channel = Data(#"{"channel":"muse-stable","version":"1.3.0-R3401.1","manifest_url":"https://example.invalid","state":"public"}"#.utf8)
        let museRelease = try XCTUnwrap(muse.release(from: channel))
        XCTAssertEqual(museRelease.version, "1.3.0-R3401.1")
        XCTAssertTrue(muse.allows(museRelease.artifact))
        XCTAssertNil(muse.release(from: Data(#"{"channel":"muse-beta","version":"1.3.0-R3401.1","state":"public"}"#.utf8)))
        func museManifest(url: String, version: String = "1.3.0-R3401.1") -> Data {
            let entry = #"{"url":"\#(url)","checksum":"\#(String(repeating: "e", count: 64))","size":42}"#
            return Data(#"{"version":"\#(version)","checksum_algorithm":"sha256","artifacts":{"aarch64_macos":\#(entry),"x86_macos":\#(entry)}}"#.utf8)
        }
        XCTAssertEqual(muse.expectation(museRelease, museManifest(url: museRelease.artifact.absoluteString))?.byteCount, 42)
        XCTAssertNil(muse.expectation(museRelease, museManifest(url: "https://lookaside.facebook.com/elsewhere")),
                     "A manifest that points somewhere else is a layout Noodle does not know.")
        XCTAssertNil(muse.expectation(museRelease, museManifest(url: museRelease.artifact.absoluteString, version: "9.9.9-R1")))

        let openCode = HarnessDistribution.openCode
        let latest = Data(#"{"channel":"latest","name":"cli","distribution":"npm","version":"2.0.10"}"#.utf8)
        let openCodeRelease = try XCTUnwrap(openCode.release(from: latest))
        XCTAssertTrue(openCodeRelease.artifact.absoluteString.hasPrefix("https://registry.npmjs.org/@opencode/cli-darwin-"))
        XCTAssertTrue(openCodeRelease.artifact.absoluteString.hasSuffix("-2.0.10.tgz"))
        let integrity = "sha512-" + Data(repeating: 0xab, count: 64).base64EncodedString()
        func registry(tarball: String, integrity: String) -> Data {
            Data(#"{"version":"2.0.10","dist":{"tarball":"\#(tarball)","integrity":"\#(integrity)"}}"#.utf8)
        }
        let expected = openCode.expectation(openCodeRelease, registry(tarball: openCodeRelease.artifact.absoluteString, integrity: integrity))
        XCTAssertEqual(expected?.algorithm, .sha512)
        XCTAssertEqual(expected?.digest, String(repeating: "ab", count: 64))
        XCTAssertNil(openCode.expectation(openCodeRelease, registry(tarball: "https://registry.npmjs.org/other.tgz", integrity: integrity)))
        XCTAssertNil(openCode.expectation(openCodeRelease, registry(tarball: openCodeRelease.artifact.absoluteString, integrity: "sha1-abcd")))
    }

    /// A real tarball, built here, through the same unpack and SHA-512 check an OpenCode download takes.
    func testArchiveIsVerifiedAndUnpackedIntoStaging() async throws {
        let source = root.appendingPathComponent("source/package/bin/opencode")
        try executable(at: source)
        let archive = root.appendingPathComponent("package.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", root.appendingPathComponent("source").path, "package"]
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        let digest = try HarnessDownloader.digest(archive, .sha512)
        let bytes = stride(from: 0, to: digest.count, by: 2).map { offset -> UInt8 in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            return UInt8(digest[start..<digest.index(start, offsetBy: 2)], radix: 16)!
        }
        func downloader(integrity: String) -> HarnessDownloader {
            HarnessDownloader(fetchData: { url, distribution in
                if url == distribution.latest { return Data(#"{"channel":"latest","name":"cli","distribution":"npm","version":"2.0.10"}"#.utf8) }
                let tarball = distribution.release(from: Data(#"{"channel":"latest","name":"cli","distribution":"npm","version":"2.0.10"}"#.utf8))!.artifact
                return Data(#"{"version":"2.0.10","dist":{"tarball":"\#(tarball.absoluteString)","integrity":"\#(integrity)"}}"#.utf8)
            }, fetchFile: { _, destination, _, _, _ in try FileManager.default.copyItem(at: archive, to: destination) })
        }
        let staged = try await downloader(integrity: "sha512-" + Data(bytes).base64EncodedString()).stage(.openCode, into: store)
        let folder = store.staging(try XCTUnwrap(staged).staging)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("package/bin/opencode").path))
        XCTAssertEqual(staged?.version, "2.0.10")

        do {
            _ = try await downloader(integrity: "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()).stage(.openCode, into: store)
            XCTFail("A tarball that fails its SHA-512 must not be unpacked.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("verification"), error.localizedDescription) }
    }

    func testInstallStopsWhenTheDiskIsTooFull() async throws {
        let downloader = HarnessDownloader(fetchData: { _, _ in Data("1.0.34".utf8) },
                                           fetchFile: { _, _, _, _, _ in XCTFail("Nothing is downloaded without room for it.") },
                                           availableCapacity: { _ in 1_024 })
        do {
            _ = try await downloader.stage(.grokBuild, into: store)
            XCTFail("Expected a disk space error.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disk space"), error.localizedDescription) }
    }

    func testNewestInstalledVersionIsTheExecutable() throws {
        try place(.fx, version: "0.0.9")
        try place(.fx, version: "0.0.10")
        try FileManager.default.createDirectory(at: store.folder(.fx).appendingPathComponent("not-a-version"), withIntermediateDirectories: true)
        // Judged by file type and mode: the app's sandbox denies execute access to its own container.
        try place(.fx, version: "0.0.11")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.directory.appendingPathComponent("fx/0.0.11/fx").path)
        let linked = store.directory.appendingPathComponent("fx/0.0.12/fx")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: store.directory.appendingPathComponent("fx/0.0.10/fx"))
        XCTAssertEqual(store.versions(.fx).map(\.text), ["0.0.9", "0.0.10"])
        XCTAssertEqual(store.executable(.fx)?.path, store.directory.appendingPathComponent("fx/0.0.10/fx").path)
        XCTAssertNil(store.executable(.claudeCode))
        try store.remove(.fx)
        XCTAssertNil(store.executable(.fx))
    }

    func testOldVersionsArePrunedExceptOnesStillRunning() throws {
        for version in ["1.0.0", "1.0.1", "1.0.2", "1.0.3"] { try place(.codex, version: version) }
        let inUse = store.directory.appendingPathComponent("codex/1.0.0/codex-path/rg").path
        store.prune(.codex, running: [inUse, "/usr/bin/true"])
        XCTAssertEqual(store.versions(.codex).map(\.text), ["1.0.0", "1.0.2", "1.0.3"], "1.0.1 is idle and old; 1.0.0 still runs a tool.")
        store.prune(.codex, running: [])
        XCTAssertEqual(store.versions(.codex).map(\.text), ["1.0.2", "1.0.3"])
        try store.remove(.codex, version: "1.0.3")
        try store.remove(.codex, version: "../1.0.2")
        XCTAssertEqual(store.versions(.codex).map(\.text), ["1.0.2"])
        XCTAssertTrue(ManagedHarnessStore.runningExecutables().contains { $0.hasSuffix("/xctest") || $0.contains("xctest") },
                      "The host sees this user's processes, this test runner among them.")
    }

    func testUsersOwnInstallationWinsAndRetiresNoodlesCopy() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try place(.fx, version: "0.0.10")
        func discovery() -> HarnessDiscovery {
            HarnessDiscovery(homeDirectory: home, applicationsDirectory: root, executableSearchDirectories: [],
                             applicationBundleURL: root, managedHarnesses: store, environment: [:])
        }
        let managed = discovery().discover(.fx)
        XCTAssertTrue(store.manages(managed))
        discovery().removeSupersededManagedHarnesses()
        XCTAssertNotNil(store.executable(.fx), "Nothing supersedes the only installation.")

        let own = home.appendingPathComponent(".local/bin/fx")
        try executable(at: own)
        XCTAssertEqual(discovery().discover(.fx).executablePath, own.path)
        XCTAssertFalse(store.manages(discovery().discover(.fx)))
        discovery().removeSupersededManagedHarnesses()
        XCTAssertNil(store.executable(.fx))
    }

    func testTrustIgnoresOtherPathsAndRejectsUnsignedOrRedirectedCopies() throws {
        XCTAssertNil(try store.trustedExecutable(at: "/usr/local/bin/fx", provider: .fx))
        try place(.fx, version: "0.0.10")
        let path = try XCTUnwrap(store.executable(.fx)).path
        // Present and in the right place, but not signed by Vercel.
        XCTAssertThrowsError(try store.trustedExecutable(at: path, provider: .fx))
        XCTAssertThrowsError(try store.trustedExecutable(at: path, provider: .claudeCode))
        XCTAssertThrowsError(try store.trustedExecutable(at: store.directory.appendingPathComponent("fx/../fx/0.0.10/other").path, provider: .fx))

        let elsewhere = root.appendingPathComponent("elsewhere/fx")
        try executable(at: elsewhere)
        let redirected = store.folder(.fx).appendingPathComponent("0.0.11", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: elsewhere.deletingLastPathComponent())
        XCTAssertThrowsError(try store.trustedExecutable(at: redirected.appendingPathComponent("fx").path, provider: .fx))
    }

    func testPublishRejectsAnUnsignedDownloadAndLinksThatEscape() throws {
        let id = UUID()
        try executable(at: store.staging(id).appendingPathComponent("fx"))
        XCTAssertThrowsError(try store.publish(.fx, version: "0.0.10", staging: id))
        XCTAssertNil(store.executable(.fx))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.staging(id).path), "A rejected download is discarded.")

        let escaping = UUID()
        try executable(at: store.staging(escaping).appendingPathComponent("fx"))
        try FileManager.default.createSymbolicLink(at: store.staging(escaping).appendingPathComponent("out"), withDestinationURL: root)
        XCTAssertThrowsError(try store.publish(.fx, version: "0.0.10", staging: escaping)) {
            XCTAssertTrue($0.localizedDescription.contains("outside"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try store.publish(.fx, version: "../escape", staging: UUID()))
        XCTAssertThrowsError(try store.publish(.apple, version: "1.0.0", staging: UUID()))
    }

    func testReleaseRecipesMatchTheVendorInstallers() throws {
        let claude = try XCTUnwrap(HarnessDistribution(.claudeCode))
        let release = try XCTUnwrap(claude.release(from: Data("2.1.278\n".utf8)))
        XCTAssertEqual(release.version, "2.1.278")
        XCTAssertTrue(release.artifact.absoluteString.hasPrefix("https://downloads.claude.ai/claude-code-releases/2.1.278/darwin-"))
        XCTAssertNil(claude.release(from: Data("<html>unavailable</html>".utf8)))
        let manifest = Data(#"{"platforms":{"darwin-arm64":{"checksum":"\#(String(repeating: "a", count: 64))","size":12},"darwin-x64":{"checksum":"\#(String(repeating: "b", count: 64))","size":13}}}"#.utf8)
        XCTAssertNotNil(claude.expectation(release, manifest)?.byteCount)
        XCTAssertNil(claude.expectation(release, Data(#"{"platforms":{}}"#.utf8)))

        let codex = HarnessDistribution.codex
        let codexRelease = try XCTUnwrap(codex.release(from: Data(#"{"tag_name":"rust-v0.155.1"}"#.utf8)))
        XCTAssertEqual(codexRelease.version, "0.155.1")
        let name = codexRelease.artifact.lastPathComponent
        let sums = Data("\(String(repeating: "c", count: 64))  other.tar.gz\n\(String(repeating: "D", count: 64))  \(name)\n".utf8)
        XCTAssertEqual(codex.expectation(codexRelease, sums)?.digest, String(repeating: "d", count: 64))
        XCTAssertNil(codex.release(from: Data(#"{"tag_name":"rust-v0.156.0","prerelease":true}"#.utf8)))

        let fx = try XCTUnwrap(HarnessDistribution(.fx)?.release(from: Data("v0.0.10\n".utf8)))
        XCTAssertTrue(fx.artifact.absoluteString.hasPrefix("https://releases.fx.sh/v0.0.10/fx-macos-"))
        XCTAssertNil(fx.checksums)
        XCTAssertTrue(claude.allows(release.artifact))
        XCTAssertFalse(claude.allows(URL(string: "https://downloads.claude.ai.example.com/claude")!))
        XCTAssertFalse(claude.allows(URL(string: "http://downloads.claude.ai/claude")!))
    }

    func testStagingStopsAtAChecksumMismatchAndSkipsAnInstalledRelease() async throws {
        try place(.claudeCode, version: "2.1.0")
        let manifest = #"{"platforms":{"darwin-arm64":{"checksum":"\#(String(repeating: "a", count: 64))"},"darwin-x64":{"checksum":"\#(String(repeating: "a", count: 64))"}}}"#
        func downloader(latest: String) -> HarnessDownloader {
            HarnessDownloader(fetchData: { url, _ in Data((url.lastPathComponent == "latest" ? latest : manifest).utf8) },
                              fetchFile: { _, destination, _, _, _ in try Data("not the release".utf8).write(to: destination) })
        }
        let installed = try await downloader(latest: "2.1.0").stage(.claudeCode, into: store)
        XCTAssertNil(installed)
        do {
            _ = try await downloader(latest: "2.2.0").stage(.claudeCode, into: store)
            XCTFail("A download that fails its checksum must not be staged.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("verification"), error.localizedDescription) }
        let staging = store.directory.appendingPathComponent(ManagedHarnessStore.stagingName)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [], [])
    }

    /// Downloads real releases. The host's step runs here unsandboxed, as it does in the Agent Host.
    func testLiveInstallFromTheVendor() async throws {
        guard let names = ProcessInfo.processInfo.environment["NOODLE_TEST_HARNESS_INSTALL"] else {
            throw XCTSkip("Set NOODLE_TEST_HARNESS_INSTALL to harness identifiers, e.g. fx,codex, to download and verify real releases.")
        }
        for provider in names.split(separator: ",").compactMap({ HarnessProvider(rawValue: String($0)) }) {
            let staged = try await HarnessDownloader().stage(provider, into: store)
            let executable = try store.publish(provider, version: try XCTUnwrap(staged).version, staging: try XCTUnwrap(staged).staging)
            XCTAssertEqual(try store.trustedExecutable(at: executable.path, provider: provider), executable)
            XCTAssertEqual(store.executable(provider), executable)
            let report = try HarnessVersionInspection.inspect(provider: provider, executable: executable, environment: [
                "HOME": root.path, "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()])
            XCTAssertEqual(report.installedVersion, staged?.version)
            XCTAssertNil(report.compatibilityIssue)
            let again = try await HarnessDownloader().stage(provider, into: store)
            XCTAssertNil(again, "The installed release is not downloaded twice.")
        }
    }

    private func place(_ provider: HarnessProvider, version: String) throws {
        let path = try XCTUnwrap(HarnessDistribution(provider)).executablePath
        try executable(at: store.folder(provider).appendingPathComponent(version).appendingPathComponent(path))
    }

    private func executable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
