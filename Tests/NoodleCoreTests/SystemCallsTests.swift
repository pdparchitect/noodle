import Foundation
@testable import NoodleCore
import XCTest

/// The calls spelled differently on Darwin and Linux behave the same on both.
final class SystemCallsTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAnExclusiveRenameNeverReplacesAndHappensOnce() throws {
        let root = try folder()
        try Data("a".utf8).write(to: root.appendingPathComponent("a"))
        try Data("b".utf8).write(to: root.appendingPathComponent("b"))
        let descriptor = systemOpen(root.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { systemClose(descriptor) }

        XCTAssertEqual(renameExclusively(in: descriptor, "a", "b"), -1)
        XCTAssertEqual(errno, EEXIST)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b")), Data("b".utf8))

        XCTAssertEqual(renameExclusively(in: descriptor, "a", "c"), 0)
        XCTAssertEqual(renameExclusively(in: descriptor, "a", "d"), -1, "renamed what was already gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["b", "c"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("c")), Data("a".utf8))
    }

    func testSwappingTradesTwoFolders() throws {
        let root = try folder()
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try Data("1".utf8).write(to: first.appendingPathComponent("one"))
        try Data("2".utf8).write(to: second.appendingPathComponent("two"))
        XCTAssertEqual(swapItems(first.path, second.path), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), ["two"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.path), ["one"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["first", "second"])
    }

    func testFolderEntriesKeepTheirWholeNames() throws {
        let root = try folder()
        let long = String(repeating: "n", count: 200) + "é"
        try Data().write(to: root.appendingPathComponent(long))
        guard let directory = opendir(root.path) else { return XCTFail("could not open the folder") }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) { names.append(entryName(entry)) }
        XCTAssertEqual(Set(names), [".", "..", long])
    }

    func testThisProcessIsSeenRunning() {
        let expected = FileManager.default.currentDirectoryPath
        guard let found = currentDirectory(of: getpid()) else { return XCTFail("no current folder") }
        XCTAssertEqual(URL(fileURLWithPath: found).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: expected).resolvingSymlinksInPath().path)
        XCTAssertFalse(runningExecutablePaths().isEmpty)
    }

    func testFreeSpaceIsReported() throws {
        XCTAssertGreaterThan(try XCTUnwrap(availableCapacity(at: try folder())), 0)
    }
}
