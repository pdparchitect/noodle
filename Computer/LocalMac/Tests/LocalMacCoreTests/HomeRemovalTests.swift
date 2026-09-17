import Darwin
import Foundation
import LocalMacPrivate
import XCTest
@testable import LocalMacCore

final class HomeRemovalTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var parent: Int32 = -1
    private let accountName = "noodle_0123456789abcdef0123"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMacRemoval-" + UUID().uuidString)
        home = root.appendingPathComponent(accountName)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(parent, 0)
    }
    override func tearDownWithError() throws {
        if parent >= 0 { close(parent) }
        try FileManager.default.removeItem(at: root)
    }
    private func remove(_ accountName: String, uid: uid_t) throws {
        var error: NSError?
        guard NLMRemoveManagedHomeAt(parent, accountName, uid, &error) else {
            throw error ?? NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
    }
    private func write(_ path: String) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: file)
    }
    private func failure(_ body: () throws -> Void) throws -> LocalMacRemovalFailure {
        do { try body(); XCTFail("Expected deletion to be refused") }
        catch { return LocalMacRemovalFailure(error as NSError) }
        throw NSError(domain: "MissingTestFailure", code: 1)
    }
    func testRemovesEntireTreeAfterPreflightAndMissingHomeIsIdempotent() throws {
        try write("workspace/nested/file")
        try write("Library/Preferences/.hidden")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try remove(accountName, uid: getuid())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try remove(accountName, uid: getuid())
    }
    func testUnreadableFolderStopsBeforeAnyFilesAreRemoved() throws {
        try write("first")
        try write("Desktop/retained")
        let desktop = home.appendingPathComponent("Desktop").path
        XCTAssertEqual(chmod(desktop, 0), 0)
        defer { chmod(desktop, 0o700) }
        let error = try failure { try remove(accountName, uid: getuid()) }
        XCTAssertEqual(error.code, Int(EACCES))
        XCTAssertEqual(error.operation, "open")
        XCTAssertEqual(error.path, "Desktop")
        XCTAssertTrue(error.preflight)
        XCTAssertFalse(error.offersPrivacySettings)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("first")), Data("first".utf8))
    }
    func testLockedItemStopsBeforeCleanupWithoutSuggestingPrivacyPermission() throws {
        try write("first")
        try write("locked")
        let locked = home.appendingPathComponent("locked").path
        XCTAssertEqual(chflags(locked, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(locked, 0) }
        let error = try failure { try remove(accountName, uid: getuid()) }
        XCTAssertEqual(error.operation, "locked")
        XCTAssertTrue(error.preflight)
        XCTAssertFalse(error.offersPrivacySettings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("first").path))
    }
    func testSymlinksAndHardLinksDoNotChangeOutsideContents() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("external"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("missing").path, withDestinationPath: "/nonexistent/noodle-removal-target")
        XCTAssertEqual(link(sentinel.path, home.appendingPathComponent("hardlink").path), 0)
        try remove(accountName, uid: getuid())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testRefusesWrongOwnerAndInvalidAccountName() throws {
        try write("retained")
        let error = try failure { try remove(accountName, uid: getuid() + 1) }
        XCTAssertEqual(error.operation, "identity")
        XCTAssertFalse(error.offersPrivacySettings)
        for invalid in ["../" + accountName, "noodle_0123456789abcdef012g", "pdp", "noodle_0123456789abcdef012/"] {
            XCTAssertThrowsError(try remove(invalid, uid: getuid()))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("retained").path))
    }
    func testRefusesSymlinkInPlaceOfHome() throws {
        let original = root.appendingPathComponent("retained-home")
        try write("retained")
        try FileManager.default.moveItem(at: home, to: original)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: original)
        XCTAssertThrowsError(try remove(accountName, uid: getuid()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("retained").path))
    }
    func testPrivacyFailureRoundTripAndBuildSpecificRecovery() throws {
        let failure = LocalMacRemovalFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: [
            "LocalMacRemovalPath": "Desktop", "LocalMacRemovalOperation": "open", "LocalMacRemovalPreflight": true
        ]))
        let decoded = try JSONDecoder().decode(LocalMacRemovalFailure.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(decoded, failure)
        XCTAssertTrue(decoded.offersPrivacySettings)
        XCTAssertTrue(decoded.message(appName: "Noodle Computer Dev").contains("allow Noodle Computer Dev in System Settings"))
        XCTAssertTrue(decoded.message(appName: "Noodle Computer Dev").contains("No files were removed by this attempt"))
        let partial = LocalMacRemovalFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTEMPTY), userInfo: [
            "LocalMacRemovalPath": "Downloads", "LocalMacRemovalOperation": "remove", "LocalMacRemovalPreflight": false
        ]))
        XCTAssertFalse(partial.offersPrivacySettings)
        XCTAssertTrue(partial.localizedDescription.contains("some files may already have been removed"))
    }
}
