import XCTest
@testable import NoodleComputer

final class GuestHomeTests: XCTestCase {
    private func resolve(uid: String, account: String) throws -> (Int32, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // Supply NSS responses to the actual guest script, without creating an
        // OS account or relying on the test runner's own HOME.
        for (name, script) in ["id": "#!/bin/sh\nprintf '%s' \"$FIXTURE_UID\"\n",
                               "getent": "#!/bin/sh\n[ \"$1\" = passwd ] && [ \"$2\" = \"$FIXTURE_UID\" ] || exit 1\nprintf '%s' \"$FIXTURE_ACCOUNT\"\n"] {
            let url = root.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", GuestHome.command]
        process.environment = ["PATH": root.path + ":/usr/bin:/bin", "HOME": "/root",
                               "FIXTURE_UID": uid, "FIXTURE_ACCOUNT": account]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    func testHomeUsesAccountDatabaseInsteadOfStaleEnvironment() throws {
        for (uid, account, expected) in [
            ("0", "root:x:0:0:root:/root:/bin/sh", "/root"),
            ("1000", "agent:x:1000:1000:Agent:/home/agent:/bin/bash", "/home/agent"),
            ("1234", "worker:x:1234:1234:Worker:/srv/work space:/bin/sh", "/srv/work space")
        ] {
            let (status, home) = try resolve(uid: uid, account: account)
            XCTAssertEqual(status, 0); XCTAssertEqual(home, expected)
        }
    }
    func testWrongAccountAndRelativeHomeAreRejected() throws {
        for account in ["root:x:0:0:root:/root:/bin/sh", "agent:x:1000:1000:Agent:relative:/bin/sh"] {
            let (status, home) = try resolve(uid: "1000", account: account)
            XCTAssertNotEqual(status, 0); XCTAssertTrue(home.isEmpty)
        }
    }
}
