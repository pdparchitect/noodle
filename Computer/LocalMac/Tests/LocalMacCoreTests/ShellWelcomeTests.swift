import Foundation
import XCTest
@testable import LocalMacCore

final class ShellWelcomeTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Noodle Shell \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    func testExistingSettingsArePreservedAndReconnectDoesNotDuplicateWelcome() throws {
        try fixture { home in
            let rc = home.appendingPathComponent(".zshrc")
            let original = "PROMPT='custom > '\nNOODLE_BANNER=0\nalias example='echo preserved'"
            try original.write(to: rc, atomically: true, encoding: .utf8)
            try LocalMacShellWelcome.prepare(home: home.path)
            let installed = try String(contentsOf: rc, encoding: .utf8)
            XCTAssertTrue(installed.hasPrefix(original + "\n"))
            XCTAssertFalse(installed.contains("PROMPT='%1~ %# '"))
            try LocalMacShellWelcome.prepare(home: home.path)
            XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), installed)
        }
    }

    func testLinkedConfigurationIsLeftAlone() throws {
        try fixture { home in
            let custom = home.appendingPathComponent("custom.zshrc")
            let original = Data("PROMPT='linked > '\n".utf8)
            try original.write(to: custom)
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".zshrc"), withDestinationURL: custom)
            try LocalMacShellWelcome.prepare(home: home.path)
            XCTAssertEqual(try Data(contentsOf: custom), original)
        }
    }

    func testRealShellWelcomeUsesImageBannerAndHonoursInteractiveStartup() throws {
        try fixture { home in
            let resources = home.appendingPathComponent("Applications/Noodle Local Mac Desktop.app/Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let computer = (0..<4).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            try FileManager.default.copyItem(at: computer.appendingPathComponent("Images/shared/noodle-welcome"),
                                            to: resources.appendingPathComponent("noodle-welcome"))
            try LocalMacShellWelcome.prepare(home: home.path)
            let rc = home.appendingPathComponent(".zshrc")
            XCTAssertTrue(try String(contentsOf: rc, encoding: .utf8).contains("PROMPT='%1~ %# '"))

            func run(_ command: String, tty: Bool = true, interactive: Bool = true, term: String = "xterm-256color") throws -> String {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: tty ? "/usr/bin/script" : "/bin/zsh")
                process.arguments = (tty ? ["-q", "/dev/null", "/bin/zsh"] : []) + [interactive ? "-dic" : "-dc", command]
                process.currentDirectoryURL = home
                process.environment = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "TERM": term]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output; process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                return String(decoding: data, as: UTF8.self)
            }

            func count(_ output: String) -> Int { output.components(separatedBy: "N O O D L E").count - 1 }
            let welcome = try run("exit")
            XCTAssertEqual(count(welcome), 1)
            XCTAssertTrue(welcome.contains("Your own agentic workspace."))
            XCTAssertTrue(welcome.contains("\u{1b}[1m"))
            XCTAssertEqual(count(try run("source ~/.zshrc; source ~/.zshrc")), 1)
            XCTAssertEqual(count(try run("/bin/zsh -dic exit")), 2)
            XCTAssertEqual(count(try run("source ~/.zshrc", interactive: false)), 0)
            XCTAssertEqual(count(try run("exit", tty: false)), 0)
            let plain = try run("exit", term: "dumb")
            XCTAssertEqual(count(plain), 1)
            XCTAssertFalse(plain.contains("\u{1b}[1m"))
            let installed = try String(contentsOf: rc, encoding: .utf8)
            try ("NOODLE_BANNER=0\n" + installed).write(to: rc, atomically: true, encoding: .utf8)
            XCTAssertEqual(count(try run("exit")), 0)
        }
    }
}
