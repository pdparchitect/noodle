import XCTest
@testable import NoodleCore

final class FxInspectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-fx-inspection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testStatusReportsAuthenticationAndOptionalModel() throws {
        let executable = try fixture(#"""
        [ "$*" = 'status --json' ] || exit 41
        if read -r input; then exit 42; fi
        printf '%s' "$STATUS"
        """#)
        for (auth, expected) in [("missing", false), ("", false), ("environment", true), ("stored", true)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "kind": "status", "auth": auth, "model": "provider/model", "token": "fixture-secret"
            ])
            let result = try FxInspection.status(executable: executable,
                environment: ["STATUS": String(decoding: data, as: UTF8.self)])
            XCTAssertEqual(result.authenticated, expected)
            XCTAssertEqual(result.model, "provider/model")
        }
        let noModel = try FxInspection.status(executable: executable,
            environment: ["STATUS": #"{"kind":"status","auth":"stored"}"#])
        XCTAssertTrue(noModel.authenticated)
        XCTAssertNil(noModel.model)
    }

    func testMalformedAndUnsupportedStatusCannotLookAuthenticated() throws {
        let executable = try fixture(#"printf '%s' "$STATUS""#)
        for response in ["not JSON", "[]", "{}", #"{"kind":"models","auth":"stored"}"#,
                         #"{"kind":"status"}"#, #"{"kind":"status","auth":true}"#] {
            XCTAssertThrowsError(try FxInspection.status(executable: executable, environment: ["STATUS": response]))
        }
    }

    func testModelsUseCurrentStatusAndPreserveValidUniqueIdentifiers() throws {
        let log = root.appendingPathComponent("commands.log")
        let executable = try fixture(#"""
        printf '%s\n' "$*" >> "$COMMAND_LOG"
        case "$*" in
          'status --json') printf '%s' '{"kind":"status","auth":"stored","model":"provider/second"}' ;;
          'models --json') printf '%s' '{"kind":"models","ids":["provider/first","provider/second","provider/first","--unsafe","bad model"]}' ;;
          *) exit 41 ;;
        esac
        """#)
        let models = try FxInspection.models(executable: executable, environment: ["COMMAND_LOG": log.path])
        XCTAssertEqual(models.map(\.id), ["provider/first", "provider/second"])
        XCTAssertEqual(models.map(\.isDefault), [false, true])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "status --json\nmodels --json\n")
    }

    func testFailedStatusStopsBeforeRequestingModels() throws {
        let log = root.appendingPathComponent("commands.log")
        let executable = try fixture(#"""
        printf '%s\n' "$*" >> "$COMMAND_LOG"
        printf '%s' '{"kind":"status","auth":"stored"}'
        exit 17
        """#)
        XCTAssertThrowsError(try FxInspection.models(executable: executable, environment: ["COMMAND_LOG": log.path]))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "status --json\n")
    }

    func testInvalidModelResponsesFailInsteadOfReturningAMisleadingCatalogue() throws {
        let executable = try fixture(#"""
        if [ "$1" = status ]; then printf '%s' '{"kind":"status","auth":"stored"}'; else printf '%s' "$MODELS"; fi
        """#)
        for response in ["not JSON", "[]", "{}", #"{"kind":"models","ids":"wrong type"}"#] {
            XCTAssertThrowsError(try FxInspection.models(executable: executable, environment: ["MODELS": response]))
        }
    }

    func testCommandFailuresDoNotEchoPrivateOutput() throws {
        let executable = try fixture(#"""
        printf '%s' '{"kind":"status","auth":"stored","token":"fixture-secret"}'
        printf '%s' 'private account fixture-secret' >&2
        exit 17
        """#)
        XCTAssertThrowsError(try FxInspection.status(executable: executable, environment: [:])) { error in
            XCTAssertTrue(error is HarnessSetupError)
            XCTAssertTrue(error.localizedDescription.contains("inspection failed"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
        }
    }

    func testOutputLimitAcceptsBoundaryAndRejectsOneAdditionalByte() throws {
        let payload = #"{"kind":"status","auth":"stored","model":"provider/model"}"#
        let executable = try fixture(#"""
        printf '%s' "$PAYLOAD"
        /usr/bin/head -c "$PADDING" /dev/zero | /usr/bin/tr '\000' ' '
        """#)
        let padding = 2_000_000 - payload.utf8.count
        let accepted = try FxInspection.status(executable: executable,
            environment: ["PAYLOAD": payload, "PADDING": String(padding)])
        XCTAssertTrue(accepted.authenticated)
        XCTAssertEqual(accepted.model, "provider/model")
        XCTAssertThrowsError(try FxInspection.status(executable: executable,
            environment: ["PAYLOAD": payload, "PADDING": String(padding + 1)])) { error in
            XCTAssertTrue(error is HarnessSetupError)
            XCTAssertTrue(error.localizedDescription.contains("response limit"))
        }
    }

    func testTeamsListWithoutChangingTheSelectedTeam() throws {
        let (executable, state, log) = try teamsFixture(selected: "acme")
        let teams = try FxInspection.teams(executable: executable, environment: ["STATE": state.path, "COMMAND_LOG": log.path])
        XCTAssertEqual(teams, [FxTeam(name: "Personal", slug: "me", isSelected: false),
                               FxTeam(name: "Acme (Labs)", slug: "acme", isSelected: true)])
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), "acme")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "teams <>\n")
    }

    func testSelectingATeamAnswersWithItsNumberFromTheCurrentList() throws {
        let (executable, state, log) = try teamsFixture(selected: "acme")
        let teams = try FxInspection.selectTeam("me", executable: executable,
                                                environment: ["STATE": state.path, "COMMAND_LOG": log.path])
        XCTAssertEqual(teams.filter(\.isSelected).map(\.slug), ["me"])
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), "me")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "teams <>\nteams <1>\n")
    }

    func testSelectingAnUnlistedTeamChangesNothing() throws {
        let (executable, state, log) = try teamsFixture(selected: "acme")
        XCTAssertThrowsError(try FxInspection.selectTeam("gone", executable: executable,
                                                         environment: ["STATE": state.path, "COMMAND_LOG": log.path]))
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), "acme")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "teams <>\n")
    }

    func testUnrecognizedTeamsOutputFails() throws {
        let executable = try fixture(#"printf '%s\n' "$OUTPUT""#)
        for output in ["", "Select a Vercel team for AI Gateway:", "  1. No slug here",
                       "  1. One (one) (default)\n  2. Two (two) (default)", "  2. Skipped (two)"] {
            XCTAssertThrowsError(try FxInspection.teams(executable: executable, environment: ["OUTPUT": output]), output)
        }
    }

    /// Prints FX 0.0.16's `teams` dialogue: the list, then a prompt whose empty answer keeps the selection.
    private func teamsFixture(selected: String) throws -> (URL, URL, URL) {
        let state = root.appendingPathComponent("team"), log = root.appendingPathComponent("commands.log")
        try Data(selected.utf8).write(to: state)
        let executable = try fixture(#"""
        [ "$*" = teams ] || exit 41
        current=$(cat "$STATE")
        printf '\nSelect a Vercel team for AI Gateway:\nModel requests will use the selected team.\n\n'
        mark() { [ "$current" = "$1" ] && printf ' (default)'; }
        printf '  1. Personal (me)%s\n' "$(mark me)"
        printf '  2. Acme (Labs) (acme)%s\n' "$(mark acme)"
        printf 'Team [%s]: ' "$([ "$current" = me ] && echo 1 || echo 2)"
        read -r answer
        printf 'teams <%s>\n' "$answer" >> "$COMMAND_LOG"
        case "$answer" in 1) current=me ;; 2) current=acme ;; '') ;; *) exit 3 ;; esac
        printf '%s' "$current" > "$STATE"
        name=$([ "$current" = me ] && echo Personal || echo 'Acme (Labs)')
        printf 'Selected Vercel team: %s (%s).\n' "$name" "$current"
        """#)
        return (executable, state, log)
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try FxInspection.status(executable: root.appendingPathComponent("missing"), environment: [:]))
    }

    private func fixture(_ body: String) throws -> URL {
        let executable = root.appendingPathComponent("fx-fixture")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
