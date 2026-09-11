import XCTest
import Darwin
@testable import NoodleCore

final class HarnessVersionInspectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-version-inspection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testEachProviderUsesReadOnlyVersionAndHelpCommandsWithUpdatesDisabled() throws {
        let executable = try fixture(#"""
        [ "$DISABLE_AUTOUPDATER" = 1 ] && [ "$NO_COLOR" = 1 ] || exit 41
        if read -r input; then exit 42; fi
        printf '%s\n' "$*" >> "$PROBE_LOG"
        case "$*" in
          --version) printf '%s\n' 'tool 1.2.3' ;;
          "$HELP_ARGUMENTS") printf '%s\n' "$HELP_TEXT" ;;
          *) exit 43 ;;
        esac
        """#)
        let cases: [(HarnessProvider, String, String)] = [
            (.codex, "--help", "Usage: codex app-server"),
            (.claudeCode, "--help", "Usage: claude --input-format --output-format --permission-mode --permission-prompts --session-id"),
            (.fx, "--help", "Usage: fx acp"),
            (.grokBuild, "agent --help", "Usage: grok agent stdio --no-leader"),
            (.muse, "--help", "Usage: muse serve schema")
        ]
        for (provider, arguments, help) in cases {
            let log = root.appendingPathComponent(provider.rawValue + ".log")
            let report = try HarnessVersionInspection.inspect(provider: provider, executable: executable, environment: [
                "DISABLE_AUTOUPDATER": "0", "NO_COLOR": "0", "PROBE_LOG": log.path,
                "HELP_ARGUMENTS": arguments, "HELP_TEXT": help
            ])
            XCTAssertEqual(report.installedVersion, "1.2.3", provider.rawValue)
            XCTAssertNil(report.checkError, provider.rawValue)
            XCTAssertNil(report.compatibilityIssue, provider.rawValue)
            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "--version\n\(arguments)\n")
        }
    }

    func testMissingVersionDoesNotHideACompatibilityProblem() throws {
        let executable = try fixture(#"""
        case "$1" in
          --version) printf '%s\n' 'version unavailable' ;;
          --help) printf '%s\n' 'Usage: codex' ;;
        esac
        """#)
        let report = try HarnessVersionInspection.inspect(provider: .codex, executable: executable, environment: [:])
        XCTAssertNil(report.installedVersion)
        XCTAssertNotNil(report.checkError)
        XCTAssertTrue(try XCTUnwrap(report.compatibilityIssue).contains("app-server"))
    }

    func testFailedHelpDistinguishesIncompatibleCLIFromAccountErrors() throws {
        let executable = try fixture(#"""
        if [ "$1" = --version ]; then printf '%s\n' '1.2.3'; exit 0; fi
        printf '%s\n' "$HELP_ERROR" >&2
        exit 1
        """#)
        let unsupported = try HarnessVersionInspection.inspect(provider: .codex, executable: executable,
            environment: ["HELP_ERROR": "error: unknown command 'app-server'"])
        XCTAssertEqual(unsupported.installedVersion, "1.2.3")
        XCTAssertNotNil(unsupported.compatibilityIssue)
        XCTAssertNil(unsupported.checkError)

        let account = try HarnessVersionInspection.inspect(provider: .codex, executable: executable,
            environment: ["HELP_ERROR": "Authentication expired: private-account-detail"])
        XCTAssertEqual(account.installedVersion, "1.2.3")
        XCTAssertNil(account.compatibilityIssue)
        XCTAssertNotNil(account.checkError)
        XCTAssertFalse(try XCTUnwrap(account.checkError).contains("private-account-detail"))
    }

    func testSuccessfulHelpWithoutUsageCannotConfirmCompatibility() throws {
        let executable = try fixture(#"""
        if [ "$1" = --version ]; then printf '%s\n' '1.2.3'; else printf '%s\n' 'please sign in'; fi
        """#)
        let report = try HarnessVersionInspection.inspect(provider: .codex, executable: executable, environment: [:])
        XCTAssertEqual(report.installedVersion, "1.2.3")
        XCTAssertNil(report.compatibilityIssue)
        XCTAssertNotNil(report.checkError)
    }

    func testMuseUsesValidInstalledFilenameVersionWithoutAcceptingInvalidSuffixes() throws {
        let body = #"""
        if [ "$1" = --version ]; then printf '%s\n' '0.0.0'; else printf '%s\n' 'Usage: muse serve schema'; fi
        """#
        let installed = try fixture(body, name: "muse-bin-1.2.3-R42.1")
        let report = try HarnessVersionInspection.inspect(provider: .muse, executable: installed, environment: [:])
        XCTAssertEqual(report.installedVersion, "1.2.3-R42.1")
        XCTAssertNil(report.checkError)

        let invalid = try fixture(body, name: "muse-bin-invalid")
        let fallback = try HarnessVersionInspection.inspect(provider: .muse, executable: invalid, environment: [:])
        XCTAssertEqual(fallback.installedVersion, "0.0.0")
    }

    func testLargeOutputIsDrainedButContentBeyondLimitIsNotParsed() throws {
        let executable = try fixture(#"""
        if [ "$1" = --version ]; then
          /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\000' x
          printf '\n1.2.3\n'
        else
          printf '%s\n' 'Usage: codex app-server' >&2
        fi
        """#)
        let report = try HarnessVersionInspection.inspect(provider: .codex, executable: executable, environment: [:])
        XCTAssertNil(report.installedVersion, "Only the bounded prefix should be inspected")
        XCTAssertNotNil(report.checkError)
        XCTAssertNil(report.compatibilityIssue, "Large version output must not prevent the help probe")
    }

    func testUnlaunchableExecutableThrowsInsteadOfReportingAnInstalledVersion() {
        XCTAssertThrowsError(try HarnessVersionInspection.inspect(provider: .codex,
            executable: root.appendingPathComponent("missing"), environment: [:]))
    }

    func testStalledProbeTimesOutAndTerminatesItsProcess() throws {
        let pidFile = root.appendingPathComponent("probe.pid")
        let executable = try fixture(#"""
        printf '%s\n' "$$" > "$PID_FILE"
        exec /bin/sleep 30
        """#)
        XCTAssertThrowsError(try HarnessVersionInspection.inspect(provider: .codex, executable: executable,
            environment: ["PID_FILE": pidFile.path])) { error in
            XCTAssertTrue(error is HarnessSetupError)
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        let rawPID = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(rawPID))
        guard pid > 0 else { return XCTFail("Expected the fixture's process ID") }
        let status = kill(pid, 0), probeError = errno
        if status == 0 { kill(pid, SIGKILL) }
        XCTAssertEqual(status, -1, "The timed-out probe must not remain running")
        XCTAssertEqual(probeError, ESRCH)
    }

    private func fixture(_ body: String, name: String = "harness") throws -> URL {
        let executable = root.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
