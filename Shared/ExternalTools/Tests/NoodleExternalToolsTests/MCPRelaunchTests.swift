import Darwin
import Foundation
@testable import NoodleExternalTools
import Testing

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Echoes, the first call only after a pause, so a hand-over that did not wait for it would come first.
private struct Slow: MCPToolSource {
    let finished: Box<Int>
    func tools() async throws -> Data { Data("[]".utf8) }
    func call(_ name: String, arguments: Data) async -> Data {
        if name == "slow" { try? await Task.sleep(for: .milliseconds(200)) }
        finished.value += 1
        return try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": name]], "isError": false])
    }
}

private func line(_ message: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
}

private func folder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relaunch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct MCPRelaunchTests {
    private let launched = MCPRelaunch.Identity(device: 1, inode: 10, size: 100, seconds: 1_000, nanoseconds: 0)
    private let updated = MCPRelaunch.Identity(device: 1, inode: 11, size: 120, seconds: 2_000, nanoseconds: 0)

    /// An update moves a new executable into the old one's place; until then, and while the file is missing
    /// halfway through, the server keeps running the one it started from.
    @Test func onlyAReplacedExecutableCountsAsChanged() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("noodle-tool")
        try Data("old".utf8).write(to: tool)
        let relaunch = try #require(MCPRelaunch(path: tool.path))
        #expect(!relaunch.changed)
        try FileManager.default.removeItem(at: tool)
        #expect(!relaunch.changed, "a file missing halfway through an update is not a new executable yet")
        let next = directory.appendingPathComponent("noodle-tool.new")
        try Data("newer".utf8).write(to: next)
        #expect(rename(next.path, tool.path) == 0)
        #expect(relaunch.changed)
    }

    /// The new executable learns that the client already initialised the server, in its environment, and reads
    /// the messages read but not yet answered from a descriptor that survives exec.
    @Test func theNewExecutableIsToldTheSessionIsInitialisedAndGetsThePendingMessages() throws {
        let pending = try line(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo"]])
        let descriptor = try MCPRelaunch.stash(pending)
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC == 0)
        let environment = MCPRelaunch.environment(["PATH": "/usr/bin"], resume: .init(protocolVersion: "2025-03-26", pending: descriptor))
        #expect(environment["PATH"] == "/usr/bin")
        let resume = try #require(MCPRelaunch.resume(from: environment))
        #expect(resume == MCPRelaunch.Resume(protocolVersion: "2025-03-26", pending: descriptor))
        #expect(MCPRelaunch.unstash(try #require(resume.pending)) == pending)
        #expect(MCPRelaunch.resume(from: ["PATH": "/usr/bin"]) == nil, "a server started by its client resumes nothing")
    }

    /// Calls already running are answered by the process that took them; the next message, and everything read
    /// after it, goes to the new executable with the version the client initialised with. A hand-over that fails
    /// leaves this process serving.
    @Test func aChangedExecutableTakesOverAfterTheRunningCallsAreAnswered() async throws {
        let finished = Box(0)
        let checks = Box(0)
        let handed = Box<(pending: Data, version: String?, finished: Int)?>(nil)
        let launched = self.launched, updated = self.updated
        let relaunch = MCPRelaunch(path: "/unused", launched: launched, identity: { _ in
            checks.value += 1
            return checks.value < 3 ? launched : updated
        }, replace: { pending, version in
            handed.value = (pending, version, finished.value)
            return "Not in a test."
        })
        let initialize = try line(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        let slow = try line(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "slow"]])
        let next = try line(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "next"]])
        let input = Pipe(), output = Pipe()
        input.fileHandleForWriting.write(initialize + slow + next)
        try input.fileHandleForWriting.close()
        let server = MCPServer(name: "noodle-tool", version: "1", instructions: "", source: Slow(finished: finished))
        await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting, relaunch: relaunch, resume: nil)
        try output.fileHandleForWriting.close()
        let handover = try #require(handed.value)
        #expect(handover.pending == next)
        #expect(handover.version == "2025-03-26")
        #expect(handover.finished == 1, "the slow call was answered before the hand-over")
        let answers = output.fileHandleForReading.readDataToEndOfFile().split(separator: UInt8(ascii: "\n"))
        #expect(answers.count == 3)
    }

    /// A resumed server answers the messages its predecessor read before it reads its own input.
    @Test func aResumedServerAnswersThePendingMessagesFirst() async throws {
        let pending = try line(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "next"]])
        let input = Pipe(), output = Pipe()
        try input.fileHandleForWriting.close()
        let server = MCPServer(name: "noodle-tool", version: "1", instructions: "", source: Slow(finished: Box(0)))
        await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting, relaunch: nil,
                         resume: .init(protocolVersion: "2025-03-26", pending: try MCPRelaunch.stash(pending)))
        try output.fileHandleForWriting.close()
        let answers = output.fileHandleForReading.readDataToEndOfFile().split(separator: UInt8(ascii: "\n"))
        let firstAnswer = try #require(answers.first)
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(firstAnswer)) as? [String: Any])
        #expect(answer["id"] as? Int == 3)
    }
}
