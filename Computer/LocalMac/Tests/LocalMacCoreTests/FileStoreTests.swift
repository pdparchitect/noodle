import Foundation
import XCTest
import Darwin
@testable import LocalMacCore

final class FileStoreTests: XCTestCase {
    func testPermissionFailuresAreNotReportedAsLinks() throws {
        try fixture { store, root in
            let denied = root.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(denied.path, 0), 0)
            defer { chmod(denied.path, 0o700) }
            XCTAssertThrowsError(try store.list("/Documents")) { error in
                XCTAssertTrue(error.localizedDescription.contains("permission"))
                XCTAssertFalse(error.localizedDescription.contains("symbolic-link"))
            }
            XCTAssertThrowsError(try store.list("/missing")) { error in
                XCTAssertTrue(error.localizedDescription.contains("no longer exists"))
            }
            let privacy = LocalMacFileStore.accessError(EPERM, path: "/Documents").localizedDescription
            XCTAssertTrue(privacy.contains("Files & Folders"))
            XCTAssertTrue(privacy.contains("this Local Mac account"))
            XCTAssertFalse(privacy.contains("symbolic-link"))
        }
    }
    private func fixture(_ body: (LocalMacFileStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalMacFileStore(home: root.path)
        defer { store.close() }
        try body(store, root)
    }
    private func upload(_ store: LocalMacFileStore, _ path: String, _ data: Data) throws {
        let id = try store.beginUpload(path, size: Int64(data.count))
        _ = try store.write(id, offset: 0, data: data)
        try store.commit(id)
    }
    func testBrowserNavigationMetadataAndFileOperations() throws {
        try fixture { store, root in
            try store.mkdir("/folder")
            try upload(store, "/folder/file.txt", Data("contents".utf8))
            let listed = try store.list("/folder")
            XCTAssertEqual(listed.map(\.name), ["file.txt"])
            let file = try XCTUnwrap(listed.first)
            XCTAssertEqual(file.kind, "file"); XCTAssertEqual(file.size, 8)
            XCTAssertEqual(try store.read("/folder/file.txt", version: file.version, offset: 0), Data("contents".utf8))
            try store.copy("/folder/file.txt", version: file.version, to: "/folder/copy.txt")
            try store.rename("/folder/copy.txt", to: "/moved.txt")
            XCTAssertEqual(try store.statFile(root.path + "/moved.txt").size, 8)
            XCTAssertThrowsError(try store.remove("/folder"))
            try store.remove("/folder/file.txt"); try store.remove("/folder")
            XCTAssertEqual(try store.list("/").map(\.name), ["moved.txt"])
            XCTAssertEqual(try store.list("/").map(\.name), ["moved.txt"], "Refreshing root must retain its listing")
            XCTAssertEqual(try store.list(store.homeDirectory).map(\.name), ["moved.txt"])
        }
    }
    func testUploadPublicationCancellationAndNoOverwrite() throws {
        try fixture { store, root in
            let id = try store.beginUpload("/new.txt", size: 6)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
            _ = try store.write(id, offset: 0, data: Data("abc".utf8))
            XCTAssertThrowsError(try store.commit(id))
            XCTAssertThrowsError(try store.write(id, offset: 0, data: Data("def".utf8)))
            _ = try store.write(id, offset: 3, data: Data("def".utf8))
            try store.commit(id)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new.txt")), Data("abcdef".utf8))
            XCTAssertThrowsError(try upload(store, "/new.txt", Data("replacement".utf8)))
            try upload(store, "/empty.txt", Data())
            XCTAssertThrowsError(try store.rename("/empty.txt", to: "/new.txt"))
            let cancelled = try store.beginUpload("/cancelled.txt", size: 3)
            _ = try store.write(cancelled, offset: 0, data: Data("abc".utf8)); store.cancel(cancelled)
            XCTAssertEqual(Set(try store.list("/").map(\.name)), ["new.txt", "empty.txt"])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new.txt")), Data("abcdef".utf8))
        }
    }
    func testLinksTraversalAndChangedFilesAreRejected() throws {
        try fixture { store, root in
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/private/tmp")
            XCTAssertEqual(try store.statFile("/outside").kind, "symlink")
            XCTAssertThrowsError(try store.list("/outside"))
            XCTAssertThrowsError(try store.beginUpload("/outside/escape.txt", size: 0))
            XCTAssertThrowsError(try store.list("/../"))
            XCTAssertThrowsError(try store.list("/Users/pdp"))
            XCTAssertThrowsError(try store.remove("/"))
            try upload(store, "/file.txt", Data("before".utf8))
            let file = try store.statFile("/file.txt")
            try Data("after change".utf8).write(to: root.appendingPathComponent("file.txt"))
            XCTAssertThrowsError(try store.read("/file.txt", version: file.version, offset: 0))
            XCTAssertThrowsError(try store.copy("/file.txt", version: file.version, to: "/stale.txt"))
            try store.remove("/outside")
            XCTAssertFalse(try store.list("/").contains { $0.name == "outside" })
        }
    }
    func testFileRequestsPreserveTransferAndVersionFields() throws {
        var request = LocalMacRequest(.fileUploadOpen)
        request.path = "/workspace/file.txt"; request.size = 12; request.offset = 4
        request.destination = "/workspace/copy.txt"; request.version = "version"; request.transferID = UUID()
        try request.validate()
        let decoded = try JSONDecoder().decode(LocalMacRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.path, request.path); XCTAssertEqual(decoded.size, request.size)
        XCTAssertEqual(decoded.destination, request.destination); XCTAssertEqual(decoded.version, request.version)
        XCTAssertEqual(decoded.transferID, request.transferID); XCTAssertEqual(decoded.offset, request.offset)
        var reply = LocalMacReply(); reply.homeDirectory = "/"
        let decodedReply = try JSONDecoder().decode(LocalMacReply.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(decodedReply.homeDirectory, "/")
        request.size = -1; XCTAssertThrowsError(try request.validate())
        request.size = 0; request.destination = "/bad\0path"; XCTAssertThrowsError(try request.validate())
    }
}
