import XCTest
import Darwin
@testable import NoodleCore

final class WorkspaceMailboxTests: XCTestCase {
    func testTraversalAndInvalidNamesCannotReachOutsideMailbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try WorkspaceMailbox(workspace: root, path: "own", create: true)
        try Data("private".utf8).write(to: root.appendingPathComponent("private"))
        for path in ["../outside", "/outside", "own/../outside", "own/./outside", "own/\0outside"] {
            XCTAssertThrowsError(try WorkspaceMailbox(workspace: root, path: path, create: true), path)
        }
        for name in ["", ".", "..", "../private", "/private", "nested/private", "private\0ignored", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try folder.read(name, limit: 100), name)
            XCTAssertThrowsError(try folder.writeData(Data("overwrite".utf8), named: name), name)
            folder.remove(name)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("private"), encoding: .utf8), "private")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }

    func testReadsRejectOversizedFilesDirectoriesAndNonblockingFIFOs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try WorkspaceMailbox(workspace: root, path: "")
        try folder.writeData(Data(repeating: 1, count: 8), named: "bounded")
        XCTAssertEqual(try folder.read("bounded", limit: 8).count, 8)
        XCTAssertThrowsError(try folder.read("bounded", limit: 7))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try folder.read("directory", limit: 100))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        // No writer: a blocking open would hang the suite instead of rejecting
        // the special file. O_NONBLOCK and the regular-file check are required.
        XCTAssertThrowsError(try folder.read("pipe", limit: 100))
    }

    func testRetainedDirectoryCannotBeRedirectedAfterOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mailbox = try WorkspaceMailbox(workspace: root, path: "own", create: true)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("own"), to: root.appendingPathComponent("retained"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("own"), withDestinationURL: outside)
        try mailbox.writeData(Data("safe".utf8), named: "result")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("result").path))
        XCTAssertEqual(try mailbox.read("result", limit: 10), Data("safe".utf8))
        XCTAssertThrowsError(try WorkspaceMailbox(workspace: root, path: "own"))
    }

    func testManagedInstructionsNeverReadOrWriteAnotherBotThroughLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let first = try repository.createAgent(named: "First").agent
        let second = try repository.createAgent(named: "Second", backstory: "private backstory").agent
        let workspace = repository.directory(for: first), outside = repository.directory(for: second)
        let original = try Data(contentsOf: outside.appendingPathComponent("AGENTS.md"))
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("AGENTS.md"), withDestinationURL: outside.appendingPathComponent("AGENTS.md"))
        XCTAssertThrowsError(try repository.loadAgentBackstory(first))
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(first))
        try repository.updateAgentBackstory(first, backstory: "own replacement")
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("AGENTS.md")), original)
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(".agents"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent(".agents"), withDestinationURL: outside.appendingPathComponent(".agents"))
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(first))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("AGENTS.md")), original)
    }

    func testReadsRejectHardlinksAndWritesReplaceLinkWithoutChangingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try WorkspaceMailbox(workspace: root, path: "own", create: true)
        let target = root.appendingPathComponent("private")
        try Data("private".utf8).write(to: target)
        let link = folder.url.appendingPathComponent("link")
        try FileManager.default.linkItem(at: target, to: link)
        XCTAssertThrowsError(try folder.read("link", limit: 100))
        try folder.writeData(Data("own".utf8), named: "link")
        XCTAssertEqual(try Data(contentsOf: target), Data("private".utf8))
    }
}
