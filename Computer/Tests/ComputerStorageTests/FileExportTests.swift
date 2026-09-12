import XCTest
@testable import NoodleComputer

final class FileExportTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ name: String, kind: String = "file", size: Int64 = 0) -> GuestFile {
        GuestFile(name: name, kind: kind, size: size, modified: 0, version: "fixture")
    }

    func testDropTargetsMatchFolderAndBackgroundAndRejectInvalidMoves() {
        let folder = file("Folder", kind: "directory"), item = file("file.txt")
        XCTAssertEqual(FileDropDestination.folder("/workspace", hovered: folder), "/workspace/Folder")
        XCTAssertEqual(FileDropDestination.folder("/workspace", hovered: nil), "/workspace")
        XCTAssertNil(FileDropDestination.folder("/workspace", hovered: item))
        XCTAssertEqual(FileDropDestination.folder("/workspace", hovered: folder, moving: item), "/workspace/Folder")
        XCTAssertNil(FileDropDestination.folder("/workspace", hovered: folder, moving: folder))
        XCTAssertNil(FileDropDestination.folder("/workspace", hovered: nil, moving: item))
        XCTAssertNil(FileDropDestination.folder("/workspace", hovered: file("../escape", kind: "directory")))
    }

    func testFolderExportPreservesContentsAndQuarantinesFiles() async throws {
        let root = try fixture(), destination = root.appendingPathComponent("Exported")
        let folder = file("Folder", kind: "directory"), nested = file("Nested", kind: "directory")
        let bytes = Data(repeating: 42, count: 200_000)
        let source = ExportFixtureSource(listings: [
            "/Folder": [file(".hidden"), nested],
            "/Folder/Nested": [file("Empty", kind: "directory"), file("quotes ' $(literal)\n.bin", size: Int64(bytes.count))],
            "/Folder/Nested/Empty": []
        ], contents: ["/Folder/.hidden": Data(), "/Folder/Nested/quotes ' $(literal)\n.bin": bytes])
        let plan = try await FileExportPlan.prepare(folder, path: "/Folder", source: source)
        let updates = ExportProgressRecorder()
        try await plan.export(to: destination, source: source, stagingRoot: root, replace: false) { updates.append($0) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Nested/quotes ' $(literal)\n.bin")), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Nested/Empty").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".hidden").path))
        XCTAssertNotNil(try destination.appendingPathComponent(".hidden").resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Exported"], "Staging must be removed")
        let progress = updates.values
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertEqual(progress.last?.completedItems, 5)
        XCTAssertEqual(progress.last?.transferredBytes, Int64(bytes.count))
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
    }

    func testCancelledExportRemovesEntireStagingAndNeverPublishes() async throws {
        let root = try fixture(), destination = root.appendingPathComponent("Cancelled")
        let source = ExportFixtureSource(listings: ["/Folder": [file("data", size: 200_000)]], contents: ["/Folder/data": Data(repeating: 1, count: 200_000)])
        let plan = try await FileExportPlan.prepare(file("Folder", kind: "directory"), path: "/Folder", source: source)
        let transfer = Task {
            try await plan.export(to: destination, source: source, stagingRoot: root, replace: false) { state in
                if state.transferredBytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await transfer.value; XCTFail("Cancellation was ignored") } catch is CancellationError {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testExistingDestinationAndFailedReadPreserveHostFilesAndCleanStaging() async throws {
        let root = try fixture(), destination = root.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data([9]).write(to: destination.appendingPathComponent("keep"))
        let source = ExportFixtureSource(listings: ["/Folder": [file("data", size: 1)]], contents: ["/Folder/data": Data([1])])
        let plan = try await FileExportPlan.prepare(file("Folder", kind: "directory"), path: "/Folder", source: source)
        do { try await plan.export(to: destination, source: source, stagingRoot: root, replace: true) { _ in }; XCTFail("Merged/replaced a folder") } catch {}
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("keep")), Data([9]))
        let truncated = ExportFixtureSource(listings: [:], contents: ["/data": Data()])
        let bad = try await FileExportPlan.prepare(file("data", size: 1), path: "/data", source: truncated)
        do { try await bad.export(to: root.appendingPathComponent("Failed"), source: truncated, stagingRoot: root, replace: false) { _ in }; XCTFail("Incomplete export succeeded") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Existing"])
    }

    func testPreflightRejectsUnsafeGuestEntries() async throws {
        let folder = file("Folder", kind: "directory")
        for child in [file("../escape"), file("a/b"), file("link", kind: "symlink"), file("pipe", kind: "other"), file("huge", size: FileImportPlan.fileLimit + 1)] {
            let source = ExportFixtureSource(listings: ["/Folder": [child]], contents: [:])
            do { _ = try await FileExportPlan.prepare(folder, path: "/Folder", source: source); XCTFail("Unsafe export accepted: \(child.name)") } catch {}
        }
    }
}

private final class ExportProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [FileTransferProgress] = []
    var values: [FileTransferProgress] { lock.withLock { progress } }
    func append(_ value: FileTransferProgress) { lock.withLock { progress.append(value) } }
}

private actor ExportFixtureSource: FileExportSource {
    let listings: [String: [GuestFile]]
    let contents: [String: Data]
    init(listings: [String: [GuestFile]], contents: [String: Data]) { self.listings = listings; self.contents = contents }
    func list(_ path: String) async throws -> [GuestFile] {
        guard let items = listings[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return items
    }
    func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let bytes = contents[path] else { throw CocoaError(.fileReadNoSuchFile) }
        let output = try FileOutput(limit: file.size, url: destination, progress: progress)
        for offset in stride(from: 0, to: bytes.count, by: 65_536) {
            try Task.checkCancellation()
            try output.write(bytes.subdata(in: offset..<min(offset + 65_536, bytes.count)))
        }
        try Task.checkCancellation()
        _ = try output.finish(expected: file.size)
    }
}
