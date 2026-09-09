import XCTest
@testable import NoodleCore

final class GrokExecutableTrustTests: XCTestCase {
    func testOfficialLegacyAndVersionedLayoutsForBothArchitectures() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        for entry in [".grok/bin/grok", ".local/bin/grok"] {
            let requested = home.appendingPathComponent(entry)
            XCTAssertTrue(GrokExecutableTrust.supportsInstallation(requested: requested,
                resolved: home.appendingPathComponent(".grok/bin/grok"), home: home))
            for name in ["grok-1.0.13", "grok-12.34.567"] {
                XCTAssertTrue(GrokExecutableTrust.supportsInstallation(requested: requested,
                    resolved: home.appendingPathComponent(".grok/bin/\(name)"), home: home), name)
            }
            for name in ["grok-macos-aarch64", "grok-macos-x86_64",
                         "grok-1.0.24-macos-aarch64", "grok-1.0.24-macos-x86_64",
                         "grok-12.34.567-macos-aarch64"] {
                XCTAssertTrue(GrokExecutableTrust.supportsInstallation(requested: requested,
                    resolved: home.appendingPathComponent(".grok/downloads/\(name)"), home: home), name)
            }
        }
    }

    func testRejectsUnknownNamesLocationsAndEntryPoints() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let requested = home.appendingPathComponent(".grok/bin/grok")
        for destination in [
            ".grok/bin-other/grok-1.0.13",
            ".grok/bin/nested/grok-1.0.13",
            ".grok/bin/grok-1.0",
            ".grok/bin/grok-latest",
            ".grok/bin/grok-1.0.13.sh",
            ".grok/bin/grok-1.0.13\n",
            ".grok/downloads-other/grok-1.0.24-macos-aarch64",
            ".grok/downloads/nested/grok-1.0.24-macos-aarch64",
            ".grok/downloads/grok-1.0.24-linux-aarch64",
            ".grok/downloads/grok-1.0.24-macos-arm64",
            ".grok/downloads/grok-1.0.24-macos-aarch64.sh",
            ".grok/downloads/grok-latest-macos-aarch64",
            ".grok/downloads/grok-1.0-macos-aarch64",
            ".grok/downloads/grok-1.0.24-macos-aarch64\n",
            ".local/bin/grok"
        ] {
            XCTAssertFalse(GrokExecutableTrust.supportsInstallation(requested: requested,
                resolved: home.appendingPathComponent(destination), home: home), destination)
        }
        let download = home.appendingPathComponent(".grok/downloads/grok-1.0.24-macos-aarch64")
        for entry in [download, URL(fileURLWithPath: "/tmp/grok"), home.appendingPathComponent("bin/grok")] {
            XCTAssertFalse(GrokExecutableTrust.supportsInstallation(requested: entry, resolved: download, home: home))
        }
    }

    func testVersionedSymlinkStillRequiresSignatureAndRejectsEscapes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("grok-trust-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let link = root.appendingPathComponent(".grok/bin/grok")
        let download = root.appendingPathComponent(".grok/downloads/grok-1.0.24-macos-aarch64")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a signed executable".utf8).write(to: download)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../downloads/\(download.lastPathComponent)")
        XCTAssertEqual(link.resolvingSymlinksInPath(), download)
        XCTAssertThrowsError(try GrokExecutableTrust.executable(at: link.path, home: root)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Grok Build’s xAI signature could not be verified. macOS error "))
        }
        // A correctly named download that is itself a symlink outside downloads
        // must fail layout validation, before it reaches signature verification.
        try fm.removeItem(at: download)
        let outside = root.appendingPathComponent("grok-1.0.24-macos-aarch64")
        try Data().write(to: outside)
        try fm.createSymbolicLink(at: download, withDestinationURL: outside)
        XCTAssertThrowsError(try GrokExecutableTrust.executable(at: link.path, home: root)) {
            XCTAssertEqual($0.localizedDescription, "Grok Build requires its official native installation at ~/.grok/bin/grok.")
        }
        try fm.removeItem(at: download)
        try fm.removeItem(at: download.deletingLastPathComponent())
        let redirected = root.appendingPathComponent("redirected", isDirectory: true)
        try fm.createDirectory(at: redirected, withIntermediateDirectories: true)
        try Data().write(to: redirected.appendingPathComponent(download.lastPathComponent))
        try fm.createSymbolicLink(at: download.deletingLastPathComponent(), withDestinationURL: redirected)
        XCTAssertThrowsError(try GrokExecutableTrust.executable(at: link.path, home: root)) {
            XCTAssertEqual($0.localizedDescription, "Grok Build requires its official native installation at ~/.grok/bin/grok.")
        }
    }

    func testVersionedSiblingSymlinkRequiresSignatureAndRejectsRedirects() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("grok-sibling-trust-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let link = root.appendingPathComponent(".grok/bin/grok")
        let binary = root.appendingPathComponent(".grok/bin/grok-1.0.13")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a signed executable".utf8).write(to: binary)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: binary.lastPathComponent)
        XCTAssertEqual(link.resolvingSymlinksInPath(), binary)
        XCTAssertThrowsError(try GrokExecutableTrust.executable(at: link.path, home: root)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Grok Build’s xAI signature could not be verified. macOS error "))
        }
        try fm.removeItem(at: binary)
        let outside = root.appendingPathComponent("grok-1.0.13")
        try Data().write(to: outside)
        try fm.createSymbolicLink(at: binary, withDestinationURL: outside)
        XCTAssertThrowsError(try GrokExecutableTrust.executable(at: link.path, home: root)) {
            XCTAssertEqual($0.localizedDescription, "Grok Build requires its official native installation at ~/.grok/bin/grok.")
        }
    }

    func testInstalledGrokTrustAndAccountInspection() throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_GROK_INSPECTION"] == "1" else {
            throw XCTSkip("Opt-in local Grok signature and account inspection; no sessions, prompts or tools.")
        }
        let home = HarnessStorage.userHome
        let path = home.appendingPathComponent(".grok/bin/grok").path
        _ = try GrokExecutableTrust.executable(at: path, home: home)
        let report = try GrokInspection.inspect(home: home, environment: ProcessInfo.processInfo.environment)
        XCTAssertEqual(report.executablePath, path)
        XCTAssertTrue(report.authenticated)
        XCTAssertFalse(report.models.isEmpty)
    }
}
