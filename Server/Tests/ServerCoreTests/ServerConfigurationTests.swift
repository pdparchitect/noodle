import Foundation
import NoodleCore
@testable import ServerCore
import XCTest

final class ServerConfigurationTests: XCTestCase {
    private let example = """
    name: Home Server
    data: /srv/noodled
    port: 39000
    harnesses:
      claude-code: /opt/claude/bin/claude
      codex: /usr/local/bin/codex
    plans:
      Family:
        harnesses: [claude-code, codex]
        models:
          claude-code: [sonnet, opus]
        tokens:
          limit: 2000000
          per: week
      Guests:
        harnesses: [codex]
        tokens:
          limit: 50000
          per: 2 days
    users:
      Ada:
        plan: Family
        admin: true
        pair-devices: true
      Bob:
        plan: Guests
      Cleo: {}
    """

    func testAWholeFileReadsAsWritten() throws {
        let configuration = try ServerConfiguration(yaml: example)
        XCTAssertEqual(configuration.name, "Home Server")
        XCTAssertEqual(configuration.data, URL(fileURLWithPath: "/srv/noodled"))
        XCTAssertEqual(configuration.port, 39000)
        XCTAssertEqual(configuration.harnesses, [.claudeCode: "/opt/claude/bin/claude", .codex: "/usr/local/bin/codex"])
        XCTAssertEqual(configuration.plans, [
            .init(name: "Family", harnesses: [.claudeCode, .codex], models: [.claudeCode: ["sonnet", "opus"]],
                  tokens: TokenLimit(tokens: 2_000_000, length: 1, unit: .weeks)),
            .init(name: "Guests", harnesses: [.codex], models: [:], tokens: TokenLimit(tokens: 50_000, length: 2, unit: .days)),
        ])
        XCTAssertEqual(configuration.users, [
            .init(name: "Ada", plan: "Family", isAdmin: true, canPairDevices: true),
            .init(name: "Bob", plan: "Guests", isAdmin: false, canPairDevices: false),
            .init(name: "Cleo", plan: "Default", isAdmin: false, canPairDevices: false),
        ])
    }

    func testAlmostEverythingHasADefault() throws {
        let configuration = try ServerConfiguration(yaml: "users:\n  Ada: {}\n")
        XCTAssertEqual(configuration.data, URL(fileURLWithPath: "/var/lib/noodled"))
        XCTAssertEqual(configuration.port, 38_415)
        XCTAssertFalse(configuration.name.isEmpty)
        XCTAssertEqual(configuration.harnesses, [:])
        XCTAssertEqual(configuration.plans, [])
        XCTAssertEqual(configuration.users.map(\.plan), ["Default"])
    }

    /// A misspelt setting or a wrong kind of value is named with where it is, never left out quietly.
    func testMistakesInTheFileSayWhereTheyAre() {
        let cases: [(String, String)] = [
            ("users:\n  Ada:\n    admn: true\n", "users.Ada.admn: noodled has no such setting."),
            ("port: lots\n", "port: expected a number from 1 to 65535."),
            ("port: 70000\n", "port: expected a number from 1 to 65535."),
            ("plans:\n  Family:\n    tokens:\n      limit: 10\n      per: fortnight\n",
             "plans.Family.tokens.per: expected a period such as week, 2 days or month."),
            ("plans:\n  Family:\n    tokens:\n      limit: 0\n      per: week\n", "plans.Family.tokens.limit: expected a number above 0."),
            ("harnesses:\n  claude-code: [a, b]\n", "harnesses.claude-code: expected the path to the harness."),
            ("users: [Ada]\n", "users: expected each user by name, with their settings."),
            ("name: [\n", "noodled.yaml is not valid YAML"),
        ]
        for (yaml, message) in cases {
            XCTAssertThrowsError(try ServerConfiguration(yaml: yaml), yaml) {
                XCTAssertTrue($0.localizedDescription.hasPrefix(message), "\($0.localizedDescription) — \(yaml)")
            }
        }
    }

    /// What reads fine can still not work here: each problem is listed, so one check finds them all.
    func testACheckListsEveryProblem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), notes = root.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: claude.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: notes.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let configuration = try ServerConfiguration(yaml: """
        harnesses:
          claude-code: \(claude.path)
          codex: \(notes.path)
          muse: /usr/bin/muse
        plans:
          Family:
            harnesses: [claude-code, opencode]
        users:
          Ada:
            plan: Familly
          Bob:
            plan: Family
        """)
        XCTAssertEqual(configuration.problems(), [
            "harnesses.codex: \(notes.path) is not a program noodled can run.",
            "harnesses.muse: noodled runs only claude-code and codex for now.",
            "plans.Family.harnesses: opencode is not one of the harnesses this server has.",
            "users.Ada.plan: there is no plan named Familly.",
        ])
        XCTAssertEqual(try ServerConfiguration(yaml: "harnesses:\n  claude-code: \(claude.path)\n").problems(), [])
    }
}
