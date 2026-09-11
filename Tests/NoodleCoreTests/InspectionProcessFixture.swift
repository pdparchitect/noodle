import XCTest
import Darwin
@testable import NoodleCore

/// A local stdio peer. It never launches a harness, reads a real home, or contacts a service.
final class InspectionProcessFixture {
    let home: URL
    let executable: URL
    private let pidFile: URL
    private let requestLog: URL
    private let argumentLog: URL
    var environment: [String: String] {
        ["HOME": home.path, "PID_FILE": pidFile.path, "REQUEST_LOG": requestLog.path, "ARGUMENT_LOG": argumentLog.path]
    }
    var wasLaunched: Bool { FileManager.default.fileExists(atPath: pidFile.path) }

    init(script: String, ignoreTermination: Bool = false) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-inspection-\(UUID())")
            .resolvingSymlinksInPath()
        executable = home.appendingPathComponent("stdio-fixture")
        pidFile = home.appendingPathComponent("process.pid")
        requestLog = home.appendingPathComponent("requests.jsonl")
        argumentLog = home.appendingPathComponent("arguments.txt")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let body = """
        #!/bin/sh
        \(ignoreTermination ? "trap '' TERM" : "")
        printf '%s\\n' "$$" > "$PID_FILE"
        printf '%s\\n' "$@" > "$ARGUMENT_LOG"
        read_request() {
          IFS= read -r request || exit 61
          printf '%s\\n' "$request" >> "$REQUEST_LOG"
        }
        \(script)
        # Remain available until inspection explicitly stops us; record unexpected requests too.
        while IFS= read -r request; do printf '%s\\n' "$request" >> "$REQUEST_LOG"; done
        """
        try Data(body.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        if let pid = processID, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: home)
    }

    static func emit(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "printf '%s\\n' " + quote(String(decoding: data, as: UTF8.self))
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var requests: [[String: Any]] {
        get throws {
            let data = try Data(contentsOf: requestLog)
            return try data.split(separator: 10).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }
    }
    var arguments: [String] {
        get throws { try String(contentsOf: argumentLog, encoding: .utf8).split(separator: "\n").map(String.init) }
    }
    private var processID: Int32? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }
    func assertStopped(file: StaticString = #filePath, line: UInt = #line) throws {
        let pid = try XCTUnwrap(processID, "The fixture must actually have launched", file: file, line: line)
        let result = kill(pid, 0), code = errno
        XCTAssertEqual(result, -1, "Inspection must reap its child process", file: file, line: line)
        XCTAssertEqual(code, ESRCH, file: file, line: line)
    }
}
