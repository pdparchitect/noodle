import Foundation
@testable import ServerCore
import XCTest

/// `noodled setup`: it checks the machine, asks a few questions, writes the file and starts the server,
/// doing exactly what the README's manual route does.
final class ServerSetupTests: XCTestCase {
    /// Answers given in order, and everything setup said, ran and wrote.
    private final class Machine: SetupConversation, SetupSystem, @unchecked Sendable {
        var answers: [String]
        var said: [String] = []
        var ran: [[String]] = []
        var programs: [String: String]
        var packages: Set<String>
        var users: Set<String> = []
        var sandbox: String?
        let osRelease = "ID=ubuntu\nVERSION_ID=\"24.04\"\n"

        init(answers: [String], programs: [String: String] = [:], packages: Set<String> = ["bubblewrap", "libmsquic"]) {
            self.answers = answers
            self.programs = programs
            self.packages = packages
        }

        func say(_ text: String) { said.append(text) }
        func ask(_ question: String, default value: String?) -> String {
            said.append(question)
            let answer = answers.isEmpty ? "" : answers.removeFirst()
            return answer.isEmpty ? value ?? "" : answer
        }
        func confirm(_ question: String, default value: Bool) -> Bool {
            let answer = ask(question, default: value ? "y" : "n")
            return answer.lowercased().hasPrefix("y")
        }

        func run(_ command: [String], interactive: Bool) -> Int32 {
            ran.append(command)
            if command.starts(with: ["apt-get", "install", "-y"]) { packages.formUnion(command.dropFirst(3)) }
            if command.first == "npm" {
                if command.contains("@anthropic-ai/claude-code") { programs["claude"] = "/usr/local/bin/claude" }
                if command.contains("@openai/codex") { programs["codex"] = "/usr/local/bin/codex" }
            }
            if command.first == "useradd", let name = command.last { users.insert(name) }
            return 0
        }
        func program(_ name: String) -> String? { name == "apt-get" ? "/usr/bin/apt-get" : programs[name] }
        func isProgram(_ path: String) -> Bool { programs.values.contains(path) }
        func hasPackage(_ name: String) -> Bool { packages.contains(name) }
        func hasUser(_ name: String) -> Bool { users.contains(name) }
        func sandboxProblem() -> String? { sandbox }
        func hostName() -> String { "studio" }
        func releaseInfo() -> String { osRelease }
        func waitForServer(_ socket: URL) -> Bool { true }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func paths() -> SetupPaths {
        SetupPaths(configuration: root.appendingPathComponent("etc/noodled/noodled.yaml"),
                   service: root.appendingPathComponent("etc/systemd/system/noodled.service"),
                   installed: root.appendingPathComponent("usr/local/bin/noodled"),
                   running: root.appendingPathComponent("download/noodled"))
    }

    func testAFreshMachineEndsWithARunningServerAndAnInvitation() throws {
        // Install bubblewrap and msquic, the name, the address, install both harnesses, the admin's name, and
        // sign in to each.
        let machine = Machine(answers: ["y", "y", "", "noodle.example.com", "y", "y", "Ada", "y", "y"],
                              packages: [])
        try ServerSetup(conversation: machine, system: machine, paths: paths(), now: Date(timeIntervalSince1970: 0)).run()

        let configuration = try ServerConfiguration(contentsOf: paths().configuration)
        XCTAssertEqual(configuration.name, "studio")
        XCTAssertEqual(configuration.address, "noodle.example.com")
        XCTAssertEqual(configuration.harnesses, [.claudeCode: "/usr/local/bin/claude", .codex: "/usr/local/bin/codex"])
        XCTAssertEqual(configuration.users.map(\.name), ["Ada"])
        XCTAssertEqual(configuration.users.first?.isAdmin, true)
        XCTAssertEqual(configuration.problems(isProgram: { _ in true }), [])
        XCTAssertEqual(try String(contentsOf: paths().service, encoding: .utf8), ServerService.unit)

        let ran = machine.ran.map { $0.joined(separator: " ") }
        let expected = [
            "apt-get install -y bubblewrap",
            "dpkg -i", // Microsoft's packages, for msquic
            "apt-get install -y libmsquic",
            "apt-get install -y nodejs npm",
            "npm install -g @anthropic-ai/claude-code",
            "npm install -g @openai/codex",
            "useradd --system --no-create-home --shell /usr/sbin/nologin noodled",
            "install -d -m 700 -o noodled -g noodled /var/lib/noodled",
            "runuser -u noodled -- \(paths().installed.path) login claude-code --config \(paths().configuration.path)",
            "runuser -u noodled -- \(paths().installed.path) login codex --config \(paths().configuration.path)",
            "systemctl daemon-reload",
            "systemctl enable --now noodled",
            "runuser -u noodled -- \(paths().installed.path) invite Ada --qr --config \(paths().configuration.path)",
        ]
        var remaining = ran[...]
        for step in expected {
            guard let found = remaining.firstIndex(where: { $0.hasPrefix(step) }) else {
                return XCTFail("\(step) did not run in order; ran:\n\(ran.joined(separator: "\n"))")
            }
            remaining = ran[(found + 1)...]
        }
        // noodled itself is put where the service runs it from.
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths().installed.path) || ran.contains { $0.hasPrefix("install -m 755") })
    }

    /// Setup does what it is asked and no more: nothing is installed without a yes.
    func testNothingIsInstalledWithoutAYes() throws {
        let machine = Machine(answers: ["n"], packages: ["libmsquic"])
        XCTAssertThrowsError(try ServerSetup(conversation: machine, system: machine, paths: paths(), now: Date()).run()) {
            XCTAssertEqual($0.localizedDescription, "Noodle Server needs bubblewrap. Install it with: sudo apt-get install bubblewrap")
        }
        XCTAssertEqual(machine.ran, [])
    }

    func testAMachineThatCannotSandboxBotsIsToldWhy() throws {
        let machine = Machine(answers: [])
        machine.sandbox = "bubblewrap cannot make a sandbox for bots here."
        XCTAssertThrowsError(try ServerSetup(conversation: machine, system: machine, paths: paths(), now: Date()).run()) {
            XCTAssertEqual($0.localizedDescription, "bubblewrap cannot make a sandbox for bots here.")
        }
    }

    /// A server already set up keeps its file: setup only fills in what is missing and starts it.
    func testAnExistingFileIsKeptUnlessAskedToStartOver() throws {
        let file = paths().configuration
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mine = "name: Mine\nharnesses:\n  codex: /usr/local/bin/codex\nusers:\n  Bob:\n    admin: true\n"
        try Data(mine.utf8).write(to: file)
        // Keep the file, and no sign-in now.
        let kept = Machine(answers: ["", "n"], programs: ["codex": "/usr/local/bin/codex"])
        kept.users = ["noodled"]
        try ServerSetup(conversation: kept, system: kept, paths: paths(), now: Date()).run()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), mine)
        XCTAssertTrue(kept.ran.contains { $0.joined(separator: " ").hasSuffix("invite Bob --qr --config \(file.path)") })

        // Starting over moves the old file aside with the date, and writes a new one.
        // Start over, the name, no address, not Claude Code, the admin, and no sign-in now.
        let fresh = Machine(answers: ["start over", "", "", "n", "Ada", "n"], programs: ["codex": "/usr/local/bin/codex"])
        fresh.users = ["noodled"]
        let now = ISO8601DateFormatter().date(from: "2026-11-11T22:40:00Z")!
        try ServerSetup(conversation: fresh, system: fresh, paths: paths(), now: now).run()
        let aside = file.deletingLastPathComponent().appendingPathComponent("noodled.yaml.2026-11-11-2240")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), mine)
        XCTAssertEqual(try ServerConfiguration(contentsOf: file).users.map(\.name), ["Ada"])
    }

    /// The service setup installs is the one the download carries.
    func testTheInstalledServiceIsTheShippedOne() throws {
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("noodled.service")
        XCTAssertEqual(try String(contentsOf: shipped, encoding: .utf8), ServerService.unit)
    }
}
