import XCTest
import Darwin
import NoodleCore
import NoodleAppleRuntime

final class AppleSandboxTests: XCTestCase {
    func testRestrictedNetworkCannotReachAnOtherwiseWorkingLocalServer() throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, length) }
        }, 0)
        XCTAssertEqual(listen(server, 1), 0)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }, 0)
        let url = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/"
        let served = expectation(description: "unrestricted request reached fixture")
        DispatchQueue.global().async {
            let connection = accept(server, nil, nil)
            if connection >= 0 {
                var buffer = [UInt8](repeating: 0, count: 4_096)
                _ = read(connection, &buffer, buffer.count)
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                response.withCString { _ = Darwin.write(connection, $0, response.utf8.count) }
                close(connection)
            }
            served.fulfill()
        }
        func fetch(restricted: Bool) throws -> Int32 {
            let child = Process()
            let args = ["--silent", "--fail", "--noproxy", "*", "--max-time", "2", url]
            if restricted {
                child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                child.arguments = ["-p", AppleAgentSandbox.profile(application: project), "/usr/bin/curl"] + args
            } else { child.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); child.arguments = args }
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            return child.terminationStatus
        }
        XCTAssertNotEqual(try fetch(restricted: true), 0)
        XCTAssertEqual(try fetch(restricted: false), 0)
        wait(for: [served], timeout: 3)
    }

    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAvailabilityThroughSeparateSandbox() throws {
        let helper = project.appendingPathComponent(".build/debug/NoodleAppleAgent")
        let result = try AppleHarnessProbe.inspect(executable: helper, application: helper.deletingLastPathComponent())
        XCTAssertEqual(result.models.map(\.id), ["default"])
        XCTAssertEqual(result.unavailableReason, AppleModel.inspection(version: "test").unavailableReason)
    }

    func testRestrictedFilesystemAndCommandDescendants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-sandbox-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let bot = try repository.createAgent(named: "Boundary")
        let other = try repository.createAgent(named: "Other")
        let privateFile = repository.directory(for: other.agent).appendingPathComponent("private.txt")
        try Data("other bot".utf8).write(to: privateFile)
        let broker = MessengerBroker(repository: repository)
        try broker.start(agents: [bot.agent, other.agent])
        defer { broker.stop() }
        let layout = repository.storage(for: bot.agent.id)
        let protected = root.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: protected)
        let policy = AppleAgentSandbox.profile(application: project.appendingPathComponent(".build/debug"), workspace: layout.workspace, repository: repository.rootURL)
        let child = Process(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", policy, "/bin/sh", "-c", """
        set -eu
        printf allowed > "$1/allowed.txt"
        if cat "$2"; then exit 11; fi
        if printf changed > "$2"; then exit 12; fi
        if printf changed > "$3"; then exit 13; fi
        if touch "$4/forged"; then exit 14; fi
        ln -s "$2" "$1/link"
        if cat "$1/link"; then exit 15; fi
        if /bin/sh -c 'cat "$1"' nested "$2"; then exit 16; fi
        if cat "$5"; then exit 17; fi
        if cat "$6/conversation.json"; then exit 18; fi
        if printf changed > "$6/messages.json"; then exit 19; fi
        "$7" --agent-directory "$1" --list-conversations > "$1/conversations.json"
        """, "probe", layout.workspace.path, protected.path, layout.configuration.path, layout.runtime.path, privateFile.path,
            repository.conversationDirectory(id: bot.conversation.id).path, project.appendingPathComponent(".build/debug/NoodleMessenger").path]
        child.standardError = errors
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "secret")
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("allowed.txt"), encoding: .utf8), "allowed")
    }
}
