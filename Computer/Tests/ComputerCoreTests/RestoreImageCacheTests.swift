import XCTest

@testable import ComputerCore

final class RestoreImageCacheTests: XCTestCase {
    func testPinnedISOChecksumAndReuse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try RestoreImageCache(directory: root)
        let source = URL(string: "https://example.com/linux.iso")!
        let download = root.appendingPathComponent("download")
        let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("abc".utf8).write(to: download)
        XCTAssertThrowsError(try cache.store(download: download, source: source, expectedSHA256: "incorrect"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        XCTAssertNil(try cache.verifiedImage(for: source))
        let saved = try cache.store(download: download, source: source, expectedSHA256: checksum)
        XCTAssertEqual(saved.pathExtension, "iso")
        XCTAssertEqual(try cache.verifiedImage(for: source, expectedSHA256: checksum), saved)
        XCTAssertNil(try cache.verifiedImage(for: source, expectedSHA256: "different-pin"))
        try Data("abd".utf8).write(to: saved)
        XCTAssertNil(try cache.verifiedImage(for: source, expectedSHA256: checksum))
    }

    func testCompletedImageIsReusedAndDifferentURLIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try RestoreImageCache(directory: root)
        let source = URL(string: "https://example.com/macOS-version-1.ipsw")!
        let download = root.appendingPathComponent("download")
        try Data("verified-image".utf8).write(to: download)
        let saved = try cache.store(download: download, source: source)
        XCTAssertEqual(try cache.verifiedImage(for: source), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        XCTAssertNil(try cache.verifiedImage(for: URL(string: "https://example.com/macOS-version-2.ipsw")!))
    }

    func testSizeAndSameSizeHashCorruptionAreRejectedAndReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try RestoreImageCache(directory: root)
        let source = URL(string: "https://example.com/macOS.ipsw")!
        let download = root.appendingPathComponent("download")
        try Data("original".utf8).write(to: download)
        let saved = try cache.store(download: download, source: source)
        try Data("modified".utf8).write(to: saved)  // Same byte length: hash must catch it.
        XCTAssertNil(try cache.verifiedImage(for: source))
        try Data("short".utf8).write(to: saved)
        XCTAssertNil(try cache.verifiedImage(for: source))
        try Data("replacement".utf8).write(to: download)
        XCTAssertEqual(try cache.store(download: download, source: source), saved)
        XCTAssertEqual(try cache.verifiedImage(for: source), saved)
    }

    func testIncompleteImageWithoutManifestIsNeverReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try RestoreImageCache(directory: root)
        let source = URL(string: "https://example.com/macOS.ipsw")!
        let download = root.appendingPathComponent("download")
        try Data("completed".utf8).write(to: download)
        let saved = try cache.store(download: download, source: source)
        try FileManager.default.removeItem(at: saved.appendingPathExtension("json"))
        XCTAssertNil(try cache.verifiedImage(for: source))
    }

    func testProgressSupportsUnknownLengthAndClampsFraction() {
        XCTAssertNil(TransferProgress(received: 100, expected: -1, elapsed: 2).fraction)
        XCTAssertEqual(TransferProgress(received: 50, expected: 100, elapsed: 1).fraction, 0.5)
        XCTAssertEqual(TransferProgress(received: 101, expected: 100, elapsed: 1).fraction, 1)
        XCTAssertEqual(TransferProgress(received: -1, expected: 100, elapsed: 0).fraction, 0)
        XCTAssertTrue(TransferProgress(received: 1_000_000, expected: 10_000_000, elapsed: 2).detail.contains("/s"))
    }
}
