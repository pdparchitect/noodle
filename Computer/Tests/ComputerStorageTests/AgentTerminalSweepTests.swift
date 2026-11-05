import Foundation
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

final class AgentTerminalSweepTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }

    func testAShellIdleAtItsPromptClosesAfterHalfAnHourUnused() {
        XCTAssertFalse(AgentTerminalSweep.suspect(used: start, person: false, watched: false, exited: false, at: minutes(29)))
        XCTAssertTrue(AgentTerminalSweep.suspect(used: start, person: false, watched: false, exited: false, at: minutes(30)))
        XCTAssertFalse(AgentTerminalSweep.closes(used: start, running: false, at: minutes(29)))
        XCTAssertTrue(AgentTerminalSweep.closes(used: start, running: false, at: minutes(30)))
    }

    func testACommandStillRunningKeepsItsShellHoweverLongItRuns() {
        XCTAssertFalse(AgentTerminalSweep.closes(used: start, running: true, at: minutes(60 * 24 * 7)))
    }

    func testWhereTheComputerCannotTellAShellIsKeptSixHours() {
        XCTAssertFalse(AgentTerminalSweep.closes(used: start, running: nil, at: minutes(6 * 60 - 1)))
        XCTAssertTrue(AgentTerminalSweep.closes(used: start, running: nil, at: minutes(6 * 60)))
    }

    func testThePersonsTerminalsWatchedComputersAndEndedShellsAreLeftAlone() {
        let late = minutes(60 * 24)
        XCTAssertFalse(AgentTerminalSweep.suspect(used: start, person: true, watched: false, exited: false, at: late))
        XCTAssertFalse(AgentTerminalSweep.suspect(used: start, person: false, watched: true, exited: false, at: late))
        XCTAssertFalse(AgentTerminalSweep.suspect(used: start, person: false, watched: false, exited: true, at: late))
    }

    /// The guest finds an agent's shell by its variable and compares the terminal's foreground
    /// group with the shell's own. Run here against a made-up proc directory.
    func testTheGuestTellsWhetherAShellRunsACommand() throws {
        let proc = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: proc) }
        let id = UUID().uuidString.lowercased()
        func process(_ pid: Int, environment: [String], stat: String) throws {
            let directory = proc.appendingPathComponent(String(pid))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(environment.joined(separator: "\0").utf8 + [0]).write(to: directory.appendingPathComponent("environ"))
            try Data((stat + "\n").utf8).write(to: directory.appendingPathComponent("stat"))
        }
        func check(_ terminal: String) throws -> Bool? {
            let task = Process(), output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", GuestShell.foregroundCheck, "sh", terminal, proc.path]
            task.standardOutput = output
            try task.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            return GuestShell.runsCommand(text)
        }
        let mine = "\(GuestShell.terminalVariable)=\(id)"
        // Another bot's shell, and a daemon that left this shell's terminal behind.
        try process(7, environment: ["HOME=/home/agent", "\(GuestShell.terminalVariable)=\(UUID().uuidString.lowercased())"],
                    stat: "7 (bash) S 1 7 7 34817 7 4194560 0 0 0 0")
        try process(9, environment: [mine], stat: "9 (my daemon) S 1 9 9 0 -1 4194560 0 0 0 0")
        try process(12, environment: ["HOME=/home/agent", mine], stat: "12 (bash) S 1 12 12 34816 12 4194560 0 0 0 0")
        XCTAssertEqual(try check(id), false, "at its prompt")

        try process(12, environment: ["HOME=/home/agent", mine], stat: "12 (bash) S 1 12 12 34816 40 4194560 0 0 0 0")
        try process(40, environment: ["HOME=/home/agent", mine], stat: "40 (make) R 12 40 12 34816 40 4194560 0 0 0 0")
        XCTAssertEqual(try check(id), true, "a command in a group of its own holds the terminal")

        XCTAssertNil(try check(UUID().uuidString.lowercased()), "no such shell")
    }
}
