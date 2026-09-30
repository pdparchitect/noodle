@testable import NoodletFormat
import XCTest

final class ArchiveTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A noodlet travels to a device as one compressed file and comes out as the same files.
    func testFilesComeBackAsTheyWent() throws {
        let source = try folder()
        let files = ["noodlet.json": Data("{}".utf8), "index.html": Data(repeating: 65, count: 300_000),
                     "art/sprite.png": Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }), "empty.txt": Data()]
        for (name, data) in files {
            let url = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let archive = try folder().appendingPathComponent("a.noodletarchive")
        try NoodletArchive.write(files.keys.sorted(), from: source, to: archive)
        let size = try XCTUnwrap(archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, 2_400_000, "The archive is compressed")

        let destination = try folder().appendingPathComponent("Out.noodlet")
        try NoodletArchive.extract(archive, to: destination)
        for (name, data) in files {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), data, name)
        }
    }

    /// An archive naming a path outside its folder is refused, and nothing lands there.
    func testPathsCannotLeaveTheFolder() throws {
        let archive = try folder().appendingPathComponent("bad.noodletarchive")
        try NoodletArchive.write(entries: [("../escaped.txt", Data("x".utf8))], to: archive)
        let destination = try folder().appendingPathComponent("Out.noodlet")
        XCTAssertThrowsError(try NoodletArchive.extract(archive, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent()
            .appendingPathComponent("escaped.txt").path))
    }

    func testSomethingElseIsNotReadAsAnArchive() throws {
        let file = try folder().appendingPathComponent("junk")
        try Data("not an archive".utf8).write(to: file)
        XCTAssertThrowsError(try NoodletArchive.extract(file, to: try folder().appendingPathComponent("Out.noodlet"))) {
            XCTAssertEqual($0.localizedDescription, "This is not a noodlet sent from a Hub.")
        }
    }
}
