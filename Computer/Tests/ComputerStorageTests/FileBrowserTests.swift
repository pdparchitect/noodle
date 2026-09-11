import XCTest
@testable import NoodleComputer

final class FileBrowserTests: XCTestCase {
    func testGuestNamesCannotEscapeDestination() throws {
        for name in ["", ".", "..", "../host", "a/b", "a\0b"] { XCTAssertThrowsError(try GuestFile.path("/workspace", name)) }
        XCTAssertEqual(try GuestFile.path("/workspace", "a 'quoted' $(name)\n.txt"), "/workspace/a 'quoted' $(name)\n.txt")
        XCTAssertEqual(try GuestFile.normalize("/var"), "/var")
        XCTAssertEqual(try GuestFile.normalize("/workspace/../etc//./hosts"), "/etc/hosts")
        XCTAssertEqual(try GuestFile.normalize("/../../"), "/")
        XCTAssertThrowsError(try GuestFile.normalize("~/Documents"))
    }

    func testOutputEnforcesActualBytesAndExactLength() throws {
        let output = try FileOutput(limit: 4)
        try output.write(Data([0, 1, 2, 3]))
        XCTAssertThrowsError(try output.write(Data([4])))
        XCTAssertThrowsError(try output.finish())
        let truncated = try FileOutput(limit: 4)
        try truncated.write(Data([0, 1]))
        XCTAssertThrowsError(try truncated.finish(expected: 4))
    }

    func testHostTransferFilesRejectSymlinksAndExistingDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), link = root.appendingPathComponent("link")
        try Data([1, 2, 3]).write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try FileInput(url: link, limit: 3))
        XCTAssertThrowsError(try FileInput(url: original, limit: 2))
        XCTAssertThrowsError(try FileOutput(limit: 3, url: original))
        XCTAssertThrowsError(try FileOutput(limit: 3, url: link))
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
    }

    func testPreviewRejectsActiveAndMismatchedFormats() throws {
        XCTAssertNil(PreviewPolicy.suffix(for: "page.html"))
        XCTAssertNil(PreviewPolicy.suffix(for: "script.app"))
        XCTAssertNil(PreviewPolicy.suffix(for: "archive.zip"))
        XCTAssertEqual(PreviewPolicy.suffix(for: "code.js"), "txt")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<html>wrong type</html>".utf8).write(to: url)
        XCTAssertThrowsError(try PreviewPolicy.validate(url))
    }

    func testCacheReservationsPinActiveFilesAndEvictUnused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FilePreviewCache(root: root)
        var leases: [FilePreviewCache.Lease] = []
        for index in 0..<5 { leases.append(try await cache.acquire(key: "\(index)", size: PreviewPolicy.fileLimit, suffix: "txt")) }
        do { _ = try await cache.acquire(key: "overflow", size: 1, suffix: "txt"); XCTFail("Active reservations must not exceed the cap") } catch {}
        try Data("cached".utf8).write(to: leases[0].url)
        await cache.complete(leases[0]); await cache.release(leases[0])
        let next = try await cache.acquire(key: "next", size: PreviewPolicy.fileLimit, suffix: "txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leases[0].url.path))
        let reserved = await cache.reservedBytes
        XCTAssertEqual(reserved, PreviewPolicy.cacheLimit)
        for lease in leases.dropFirst() { await cache.release(lease) }
        await cache.release(next)
        let remaining = await cache.reservedBytes
        XCTAssertEqual(remaining, 0)
    }

    func testCacheRecoversFromSystemPurgeAndExpires() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FilePreviewCache(root: root)
        let first = try await cache.acquire(key: "same", size: 1, suffix: "txt")
        try Data([65]).write(to: first.url)
        await cache.complete(first); await cache.release(first)
        let reuse = try await cache.acquire(key: "same", size: 1, suffix: "txt")
        XCTAssertTrue(reuse.reused)
        await cache.release(reuse)
        try FileManager.default.removeItem(at: first.url)
        let second = try await cache.acquire(key: "same", size: 1, suffix: "txt")
        XCTAssertFalse(second.reused)
        try Data([66]).write(to: second.url)
        await cache.complete(second); await cache.release(second)
        await cache.expire(now: Date().addingTimeInterval(601))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        let remaining = await cache.reservedBytes
        XCTAssertEqual(remaining, 0)
    }

    func testEmptyPreviewsCannotAccumulateUnlimitedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FilePreviewCache(root: root)
        for index in 0..<140 {
            let lease = try await cache.acquire(key: "\(index)", size: 0, suffix: "txt")
            try Data().write(to: lease.url)
            await cache.complete(lease); await cache.release(lease)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 128)
        await cache.clearUnused()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
