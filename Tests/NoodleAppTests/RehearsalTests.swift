#if NOODLE_DEV_HOOKS
import Foundation
import XCTest
@testable import NoodleCore

final class RehearsalTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-rehearsal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    func testARehearsalKeepsDataAndLoginsApartAndStartsEmptyEachTime() throws {
        let data = support.appendingPathComponent("Noodle", isDirectory: true)
        XCTAssertEqual(HarnessStorage.dataRoot(applicationSupport: support), data)
        XCTAssertEqual(HarnessStorage.accountHome(applicationSupport: support), HarnessStorage.systemHome)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("bots".utf8).write(to: data.appendingPathComponent("kept"))

        try Rehearsal.begin(in: support)
        let home = HarnessStorage.accountHome(applicationSupport: support)
        let rehearsalData = HarnessStorage.dataRoot(applicationSupport: support)
        XCTAssertNotEqual(home, HarnessStorage.systemHome, "No harness finds the person's own installs or logins.")
        XCTAssertNotEqual(rehearsalData, data, "No bot of the person's is shown.")
        for folder in [home, rehearsalData] {
            XCTAssertTrue(folder.path.hasPrefix(support.path + "/"), "Everything stays in the app's own storage.")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }

        // What the last rehearsal downloaded and signed in to is gone at the next start.
        let login = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: login.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: login)
        try Data().write(to: rehearsalData.appendingPathComponent("workspace.json"))
        try Rehearsal.begin(in: support)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rehearsalData.path), [])

        Rehearsal.end(in: support)
        XCTAssertEqual(HarnessStorage.dataRoot(applicationSupport: support), data)
        XCTAssertEqual(HarnessStorage.accountHome(applicationSupport: support), HarnessStorage.systemHome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("kept")), Data("bots".utf8), "The real data is never touched.")
    }
}
#endif
