import Foundation
import XCTest
import Darwin
@testable import LocalMacCore

final class RuntimeUpdateTests: XCTestCase {
    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.app"), destination = root.appendingPathComponent("desktop.app")
        try bundle(source, "new")
        try body(root, source, destination)
    }
    private func bundle(_ url: URL, _ version: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data(version.utf8).write(to: url.appendingPathComponent("signed-version"))
    }
    private func validate(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url.appendingPathComponent("signed-version"))
        guard [Data("old".utf8), Data("new".utf8)].contains(data) else { throw LocalMacError("Invalid signature fixture") }
        return data
    }
    func testInstallUpgradeIdempotenceAndRepairPreserveOtherFiles() throws {
        try fixture { root, source, destination in
            let documents = root.appendingPathComponent("user-document")
            try Data("preserve".utf8).write(to: documents)
            try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate)
            XCTAssertEqual(try validate(destination), Data("new".utf8))
            // No publication should be attempted when the signed image matches.
            try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate) { _, _, _ in XCTFail("Already current") }
            try Data("old".utf8).write(to: destination.appendingPathComponent("signed-version"))
            try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate)
            XCTAssertEqual(try validate(destination), Data("new".utf8))
            try FileManager.default.removeItem(at: destination.appendingPathComponent("signed-version"))
            try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate)
            XCTAssertEqual(try validate(destination), Data("new".utf8))
            XCTAssertEqual(try Data(contentsOf: documents), Data("preserve".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".noodle-desktop-update.app").path))
        }
    }
    func testRejectedSourceAndStagingLeavePreviousBundle() throws {
        try fixture { _, source, destination in
            try bundle(destination, "old")
            XCTAssertThrowsError(try LocalMacRuntimeUpdate.install(source: source, destination: destination) { url in
                if url == source { throw LocalMacError("Invalid source") }
                return try self.validate(url)
            })
            XCTAssertEqual(try validate(destination), Data("old".utf8))
            XCTAssertThrowsError(try LocalMacRuntimeUpdate.install(source: source, destination: destination) { url in
                if url.lastPathComponent == ".noodle-desktop-update.app" { throw LocalMacError("Damaged copy") }
                return try self.validate(url)
            })
            XCTAssertEqual(try validate(destination), Data("old".utf8))
        }
    }
    func testPublicationFailureAndPostPublicationFailureRollBack() throws {
        try fixture { _, source, destination in
            try bundle(destination, "old")
            XCTAssertThrowsError(try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate) { _, _, _ in
                throw LocalMacError("Publication failure")
            })
            XCTAssertEqual(try validate(destination), Data("old".utf8))
            XCTAssertThrowsError(try LocalMacRuntimeUpdate.install(source: source, destination: destination) { url in
                let data = try self.validate(url)
                if url == destination && data == Data("new".utf8) { throw LocalMacError("Post-publication failure") }
                return data
            })
            XCTAssertEqual(try validate(destination), Data("old".utf8))
        }
    }
    func testInterruptedUpdateRecoversPreviousCopyBeforeRetry() throws {
        try fixture { root, source, destination in
            try bundle(destination, "damaged")
            try bundle(root.appendingPathComponent(".noodle-desktop-update.app"), "old")
            // Fail the new copy after recovery, proving the recovered prior copy
            // remains usable even if the subsequent update cannot finish.
            var checkedStaging = false
            XCTAssertThrowsError(try LocalMacRuntimeUpdate.install(source: source, destination: destination) { url in
                if url.lastPathComponent == ".noodle-desktop-update.app" {
                    if checkedStaging { throw LocalMacError("Retry copy failed") }
                    checkedStaging = true
                }
                return try self.validate(url)
            })
            XCTAssertEqual(try validate(destination), Data("old".utf8))
            try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate)
            XCTAssertEqual(try validate(destination), Data("new".utf8))
        }
    }
    func testSymlinkAndConcurrentUpdateAreRejected() throws {
        try fixture { root, source, destination in
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            XCTAssertThrowsError(try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate))
            XCTAssertEqual(try validate(source), Data("new".utf8))
            try FileManager.default.removeItem(at: destination)
            let lock = open(root.appendingPathComponent(".noodle-desktop-update.lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(lock, 0); defer { Darwin.close(lock) }
            XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try LocalMacRuntimeUpdate.install(source: source, destination: destination, validate: validate))
        }
    }
}
