import XCTest
@testable import NoodleCore

/// The Agent Host's inspections look at the vendor's own location first, and
/// at the copy Noodle installed only when that is absent.
final class ManagedHarnessInspectionTests: XCTestCase {
    func testGrokAndMuseFallBackToNoodlesCopy() throws {
        let fixture = try InspectionProcessFixture(script: "exit 1")
        XCTAssertNil(try GrokInspection.inspect(home: fixture.home, environment: fixture.environment).executablePath)
        XCTAssertNil(try MuseInspection.inspect(home: fixture.home, environment: fixture.environment).executablePath)
        // The copy exits at once, so reaching it shows as an inspection error, not as Not installed.
        XCTAssertThrowsError(try GrokInspection.inspect(home: fixture.home, environment: fixture.environment, managed: fixture.executable))
        XCTAssertThrowsError(try MuseInspection.inspect(home: fixture.home, environment: fixture.environment, managed: fixture.executable))
    }

    /// Muse prints "1.3.0" for release 1.3.0-R3401.1, which is what the update check compares.
    func testMuseInstalledByNoodleReportsTheReleaseItWasInstalledAs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-managed-muse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (folder, expected) in [("1.3.0-R3401.1", "1.3.0-R3401.1"), ("not-a-release", "1.3.0")] {
            let executable = root.appendingPathComponent("\(folder)/muse")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'muse 1.3.0'; else echo 'Usage: muse serve schema'; fi\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            XCTAssertEqual(try HarnessVersionInspection.inspect(provider: .muse, executable: executable, environment: [:]).installedVersion, expected)
        }
    }

    func testOpenCodeFallsBackToNoodlesCopy() throws {
        let fixture = try InspectionProcessFixture(script: "exit 1")
        XCTAssertNil(try OpenCodeInspection.inspect(home: fixture.home, application: fixture.home).executablePath)
        XCTAssertThrowsError(try OpenCodeInspection.inspect(home: fixture.home, application: fixture.home, managed: fixture.executable))
    }
}
