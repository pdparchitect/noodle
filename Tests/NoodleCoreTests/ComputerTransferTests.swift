import ComputerBridge
import Darwin
import XCTest
@testable import NoodleCore

final class ComputerTransferTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testBinaryAndEmptyFilesRoundTripWithoutInlinePayloads() throws {
        let root = try directory(), shared = try directory()
        for size in [0, 2_500_017] {
            let name = "binary ' $()\n \(size).dat"
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            try bytes.write(to: root.appendingPathComponent(name))
            let staging = try ComputerTransferFiles.staging(root: shared, id: UUID(), create: true)
            XCTAssertEqual(try ComputerWorkspaceFiles.upload(workspace: root, path: name, to: staging), Int64(size))
            let destination = try ComputerWorkspaceDownload(workspace: root, path: "copy-" + name)
            XCTAssertEqual(try destination.copy(from: staging, expected: Int64(size)), Int64(size))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy-" + name).path))
            try destination.publish()
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copy-" + name)), bytes)
        }
    }

    func testNoOverwriteEvenWhenDestinationAppearsDuringDownload() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        try Data([0, 255]).write(to: source)
        let target = root.appendingPathComponent("target")
        var download: ComputerWorkspaceDownload? = try ComputerWorkspaceDownload(workspace: root, path: "target")
        _ = try download!.copy(from: source, expected: 2)
        try Data("keep".utf8).write(to: target)
        XCTAssertThrowsError(try download!.publish())
        download = nil
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertThrowsError(try ComputerWorkspaceDownload(workspace: root, path: "target"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source", "target"])
    }

    func testRefusesEscapeSymlinksMissingParentsAndSpecialFiles() throws {
        let root = try directory(), outside = try directory()
        try Data([7]).write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file"), withDestinationURL: outside.appendingPathComponent("secret"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
        for path in ["../secret", outside.appendingPathComponent("secret").path, "link/secret", "file", "fifo", "missing/file", "", "a\0b"] {
            XCTAssertThrowsError(try ComputerWorkspaceFiles.upload(workspace: root, path: path, to: root.appendingPathComponent(UUID().uuidString)))
        }
        for path in ["../new", "link/new", "file", "fifo", "missing/file", "/tmp/new"] {
            XCTAssertThrowsError(try ComputerWorkspaceDownload(workspace: root, path: path))
        }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret")), Data([7]))
    }

    func testDownloadKeepsOpenedParentWhenNameIsReplacedWithSymlink() throws {
        let root = try directory(), outside = try directory()
        let folder = root.appendingPathComponent("folder"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source")
        try Data([1, 2]).write(to: source)
        let download = try ComputerWorkspaceDownload(workspace: root, path: "folder/result")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        _ = try download.copy(from: source, expected: 2)
        try download.publish()
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("result")), Data([1, 2]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("result").path))
    }

    func testIncompleteDownloadAndAbandonmentNeverPublish() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        try Data([1]).write(to: source)
        var download: ComputerWorkspaceDownload? = try ComputerWorkspaceDownload(workspace: root, path: "result")
        XCTAssertThrowsError(try download!.copy(from: source, expected: 2))
        _ = try download!.copy(from: source, expected: 1)
        download = nil // Includes revocation after staging but before publication.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
    }

    func testOversizedSparseFileIsRejectedBeforeCopying() throws {
        let root = try directory(), source = root.appendingPathComponent("large")
        let fd = Darwin.open(source.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        XCTAssertEqual(ftruncate(fd, ComputerTransferFiles.limit + 1), 0)
        XCTAssertThrowsError(try ComputerWorkspaceFiles.upload(workspace: root, path: "large", to: root.appendingPathComponent("staging")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("staging").path))
    }

    func testCLILocalPathResolutionAndTransferDeadline() throws {
        let root = try directory().resolvingSymlinksInPath()
        XCTAssertEqual(try ComputerWorkspaceFiles.relativePath("a.bin", currentDirectory: root, workspace: root), "a.bin")
        XCTAssertEqual(try ComputerWorkspaceFiles.relativePath("b.bin", currentDirectory: root.appendingPathComponent("sub"), workspace: root), "sub/b.bin")
        XCTAssertEqual(try ComputerWorkspaceFiles.relativePath(root.appendingPathComponent("a.bin").path, currentDirectory: root, workspace: root), "a.bin")
        for path in ["/etc/passwd", "../escape", "link/../file", ""] {
            XCTAssertThrowsError(try ComputerWorkspaceFiles.relativePath(path, currentDirectory: root, workspace: root))
        }
        var request = ComputerAgentRequest(token: "fixture", request: .init(.fileUpload))
        request.localPath = "sub/binary.dat"
        let encoded = try JSONEncoder().encode(request)
        let fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(fields["localPath"] as? String, request.localPath)
        XCTAssertEqual(try JSONDecoder().decode(ComputerAgentRequest.self, from: encoded).localPath, request.localPath)
        XCTAssertGreaterThan(request.expiresAt.timeIntervalSinceNow, 590)
    }
}
