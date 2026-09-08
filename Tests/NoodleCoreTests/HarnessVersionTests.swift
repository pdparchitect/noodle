import XCTest
@testable import NoodleCore

final class HarnessVersionTests: XCTestCase {
    func testUpdateVisibilityNeedsAConfirmedNewerVersion() {
        XCTAssertFalse(HarnessVersionReport().updateAvailable)
        XCTAssertFalse(HarnessVersionReport(installedVersion: "1.0.0", checkError: "Release unavailable").updateAvailable)
        XCTAssertFalse(HarnessVersionReport(installedVersion: "1.0.0", latestVersion: "1.0.0").updateAvailable)
        XCTAssertFalse(HarnessVersionReport(installedVersion: "2.0.0", latestVersion: "1.0.0").updateAvailable)
        XCTAssertFalse(HarnessVersionReport(installedVersion: "1.0.0", compatibilityIssue: "Missing option").updateAvailable)
        // A failed refresh does not erase an already confirmed update.
        XCTAssertTrue(HarnessVersionReport(installedVersion: "1.0.0", latestVersion: "1.0.1", checkError: "Refresh failed").updateAvailable)
        var updated = HarnessVersionReport(installedVersion: "1.0.0", latestVersion: "1.0.1")
        XCTAssertTrue(updated.updateAvailable)
        updated.installedVersion = "1.0.1"
        XCTAssertFalse(updated.updateAvailable)
    }

    func testVersionComparison() throws {
        let values = ["1.0.0-alpha", "1.0.0-alpha.2", "1.0.0-alpha.10", "1.0.0-beta", "1.0.0", "1.0.9", "1.0.10", "2.0.0"]
        let parsed = try values.map { try XCTUnwrap(HarnessVersion($0)) }
        XCTAssertEqual(parsed.reversed().sorted(), parsed)
        XCTAssertEqual(HarnessVersion("1.0.0+abc"), HarnessVersion("1.0.0+def"))
        for invalid in ["", "latest", "1.2", "<html>1.2.3</html>", "1.2.3; echo unsafe"] {
            XCTAssertNil(HarnessVersion(invalid))
        }
    }

    func testNativeVersionOutputs() {
        for (output, version) in [("codex-cli 0.153.4", "0.153.4"), ("2.1.263 (Claude Code)", "2.1.263"),
                                  ("0.0.8\n", "0.0.8"), ("grok 1.0.13 (5e9a58528b76) [stable]", "1.0.13")] {
            XCTAssertEqual(HarnessVersion.parseOutput(output)?.text, version)
        }
        XCTAssertNil(HarnessVersion.parseOutput("command failed"))
    }

    func testLatestResponses() {
        XCTAssertEqual(HarnessVersionPolicy.latestVersion(provider: .codex, data: Data(#"{"tag_name":"rust-v0.153.4"}"#.utf8)), "0.153.4")
        XCTAssertEqual(HarnessVersionPolicy.latestVersion(provider: .claudeCode, data: Data(#"{"tag_name":"v2.1.263"}"#.utf8)), "2.1.263")
        for provider in [HarnessProvider.fx, .grokBuild] {
            XCTAssertEqual(HarnessVersionPolicy.latestVersion(provider: provider, data: Data("1.2.3\n".utf8)), "1.2.3")
            XCTAssertNil(HarnessVersionPolicy.latestVersion(provider: provider, data: Data("<html>1.2.3</html>".utf8)))
        }
        for flag in ["prerelease", "draft"] {
            XCTAssertNil(HarnessVersionPolicy.latestVersion(provider: .codex, data: Data("{\"tag_name\":\"v1.2.3\",\"\(flag)\":true}".utf8)))
        }
        XCTAssertFalse(HarnessVersionReport(installedVersion: "2.0.0", latestVersion: "1.0.0").updateAvailable)
        XCTAssertFalse(HarnessVersionReport(latestVersion: "1.0.0").updateAvailable)
        XCTAssertTrue(HarnessVersionReport(installedVersion: "1.0.9", latestVersion: "1.0.10").updateAvailable)
    }

    func testConservativeCompatibilityChecks() {
        for provider in HarnessProvider.allCases {
            let options = HarnessVersionPolicy.requiredOptions(for: provider)
            XCTAssertNil(HarnessVersionPolicy.compatibilityIssue(provider: provider, help: "Usage: tool " + options.joined(separator: " ")))
            XCTAssertNotNil(HarnessVersionPolicy.compatibilityIssue(provider: provider, help: "Usage: tool"))
            XCTAssertNil(HarnessVersionPolicy.compatibilityIssue(provider: provider, help: "Could not load help"))
            XCTAssertNotNil(HarnessVersionPolicy.startupIssue(provider: provider, text: "error: unknown option '\(options[0])'"))
            for failure in ["Authentication expired", "Safety reviewer unavailable; action held", "unknown model 'opus'", "Network unavailable", "unknown option '--unrelated'"] {
                XCTAssertNil(HarnessVersionPolicy.startupIssue(provider: provider, text: failure))
            }
        }
        XCTAssertEqual(HarnessVersionPolicy.helpArguments(for: .grokBuild), ["agent", "--help"])
    }

    func testGuidesAndCache() throws {
        for provider in HarnessProvider.allCases {
            let installed = HarnessInstallation(provider: provider, executablePath: "/fixture/tool")
            XCTAssertNotNil(HarnessVersionPolicy.updateGuide(for: installed).command)
            XCTAssertEqual(HarnessVersionPolicy.latestURL(for: installed)?.scheme, "https")
            let snapshot = HarnessPresentationSnapshot(installation: installed, authentication: .authenticated,
                version: .init(installedVersion: "1.0.0", latestVersion: "2.0.0"))
            XCTAssertEqual(try JSONDecoder().decode(HarnessPresentationSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        }
        let bundled = HarnessInstallation(provider: .codex, executablePath: "/Applications/Codex.app/Contents/Resources/codex")
        XCTAssertNil(HarnessVersionPolicy.latestURL(for: bundled))
        XCTAssertNil(HarnessVersionPolicy.updateGuide(for: bundled).command)
        let removed = HarnessPresentationSnapshot(installation: .init(provider: .fx, executablePath: nil), authentication: .authenticated,
            version: .init(installedVersion: "1.0.0"))
        XCTAssertNil(removed.version)
    }
}
