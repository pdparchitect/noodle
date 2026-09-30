@testable import NoodletFormat
import NoodletRuntime
import XCTest

final class RemoteTests: XCTestCase {
    /// Pieces as the Hub would get them.
    private actor Wire {
        var pieces: [(UUID, Int, Int, Data)] = []
        func take(_ id: UUID, _ offset: Int, _ total: Int, _ piece: Data) -> Data? {
            pieces.append((id, offset, total, piece))
            let whole = pieces.filter { $0.0 == id }.reduce(Data()) { $0 + $1.3 }
            guard whole.count == total, let call = try? JSONDecoder().decode(NoodletStoreCall.self, from: whole) else { return nil }
            return try? JSONEncoder().encode(NoodletValue.text(call.text ?? call.operation))
        }
    }

    /// A call too large for one request goes in pieces of one call, in order, and the last answers.
    func testALargeCallGoesInPieces() async throws {
        let wire = Wire()
        let store = RemoteNoodletStore { await wire.take($0, $1, $2, $3) }
        let text = String(repeating: "é", count: 700_000)
        let answer = try await store.perform(NoodletStoreCall(operation: "write", path: "a.txt", text: text))
        XCTAssertEqual(answer, .text(text))
        let pieces = await wire.pieces
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(Set(pieces.map(\.0)).count, 1)
        XCTAssertEqual(pieces.map(\.1), [0, RemoteNoodletStore.pieceSize, 2 * RemoteNoodletStore.pieceSize])
        XCTAssertTrue(pieces.allSatisfy { $0.3.count <= RemoteNoodletStore.pieceSize })
        let small = try await store.perform(NoodletStoreCall(operation: "read", path: "a.txt"))
        XCTAssertEqual(small, .text("read"))
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private actor Offsets {
        var all: [Int] = []
        func add(_ offset: Int) { all.append(offset) }
    }

    /// A revision this device has is not fetched again; a new one is, and the old one goes.
    func testTheCacheFetchesEachRevisionOnce() async throws {
        let archive = try folder().appendingPathComponent("a")
        try NoodletArchive.write(entries: [("noodlet.json", Data("{}".utf8)), ("index.html", Data(repeating: 7, count: 300_000))], to: archive)
        let bytes = try Data(contentsOf: archive)
        let cache = NoodletCache(root: try folder())
        let id = UUID()
        let offsets = Offsets()
        let fetch: @Sendable (Int) async throws -> Data = { offset in
            await offsets.add(offset)
            return bytes.subdata(in: offset..<min(bytes.count, offset + 1000))
        }
        let first = try await cache.package(id, revision: "abc1", byteCount: bytes.count, fetch: fetch)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("index.html")).count, 300_000)
        let count = await offsets.all.count
        XCTAssertGreaterThan(count, 0)
        _ = try await cache.package(id, revision: "abc1", byteCount: bytes.count, fetch: fetch)
        let again = await offsets.all.count
        XCTAssertEqual(again, count, "fetched a revision it had")
        let second = try await cache.package(id, revision: "abc2", byteCount: bytes.count, fetch: fetch)
        let later = await offsets.all.count
        XCTAssertGreaterThan(later, count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("noodlet.json").path))
        do {
            _ = try await cache.package(id, revision: "../x", byteCount: bytes.count, fetch: fetch)
            XCTFail("a revision named a path")
        } catch {}
    }

    /// Where the person ran a noodlet last is where it runs next time, for that noodlet alone.
    func testTheChoiceIsRememberedForEachNoodlet() throws {
        let suite = "NoodletPlaces." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = NoodletPlaces(defaults: defaults)
        let game = UUID(), viewer = UUID()
        XCTAssertNil(places.chosen(game))
        places.choose(.hub, for: game)
        XCTAssertEqual(places.chosen(game), .hub)
        XCTAssertNil(places.chosen(viewer))
        places.choose(.device, for: game)
        XCTAssertEqual(NoodletPlaces(defaults: defaults).chosen(game), .device)
    }
}
