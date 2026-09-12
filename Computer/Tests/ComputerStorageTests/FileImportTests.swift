import XCTest
@testable import NoodleComputer

final class FileImportTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testNestedHiddenAndEmptyItemsRoundTripWithMonotonicProgress() async throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("Folder ' $(literal)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent(".hidden"))
        let bytes = Data(repeating: 42, count: 200_000)
        try bytes.write(to: folder.appendingPathComponent("Nested/file\n.bin"))
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        let plan = try FileImportPlan.prepare([folder, empty], folder: "/workspace")
        XCTAssertEqual(plan.items.count, 6)
        XCTAssertEqual(plan.totalBytes, 200_003)
        let target = ImportFixtureDestination()
        let updates = ImportProgressRecorder()
        try await plan.send(to: target) { await updates.append($0) }
        let directories = await target.directories
        XCTAssertEqual(directories, ["/workspace/Folder ' $(literal)", "/workspace/Folder ' $(literal)/Nested", "/workspace/Folder ' $(literal)/Nested/Empty"])
        let files = await target.files
        XCTAssertEqual(files["/workspace/Folder ' $(literal)/Nested/file\n.bin"], bytes)
        XCTAssertEqual(files["/workspace/Folder ' $(literal)/.hidden"], Data([1, 2, 3]))
        XCTAssertEqual(files["/workspace/empty.txt"], Data())
        let progress = await updates.values
        XCTAssertEqual(progress.first?.fraction, 0)
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertEqual(progress.last?.completedItems, 6)
        XCTAssertEqual(progress.last?.transferredBytes, 200_003)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        XCTAssertTrue(progress.dropLast().allSatisfy { $0.fraction < 1 })
    }

    func testEmptyFoldersAndFilesHaveDeterminateProgress() async throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("zero"))
        let plan = try FileImportPlan.prepare([root], folder: "/workspace")
        let updates = ImportProgressRecorder()
        try await plan.send(to: ImportFixtureDestination()) { await updates.append($0) }
        let progress = await updates.values
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertEqual(progress.last?.totalBytes, 0)
        XCTAssertTrue(progress.contains { $0.fraction > 0 && $0.fraction < 1 })
    }

    func testPreflightRejectsLinksSpecialFilesOversizedFilesAndDuplicateDestinations() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try FileImportPlan.prepare([folder], folder: "/workspace"))
        try FileManager.default.removeItem(at: link)
        let special = folder.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(special.path, 0o600), 0)
        XCTAssertThrowsError(try FileImportPlan.prepare([folder], folder: "/workspace"))
        try FileManager.default.removeItem(at: special)
        let large = folder.appendingPathComponent("large")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FileImportPlan.fileLimit + 1))
        try handle.close()
        XCTAssertThrowsError(try FileImportPlan.prepare([folder], folder: "/workspace"))
        try FileManager.default.removeItem(at: large)
        XCTAssertThrowsError(try FileImportPlan.prepare([folder, folder], folder: "/workspace"))
    }

    func testCancelledPreflightAndActiveFileStopBeforeLaterItems() async throws {
        let root = try fixture()
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try Data(repeating: 7, count: 200_000).write(to: first)
        try Data([8]).write(to: second)
        let preflight = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileImportPlan.prepare([root], folder: "/workspace")
        }
        do { _ = try await preflight.value; XCTFail("Cancelled preparation succeeded") } catch is CancellationError {}
        let plan = try FileImportPlan.prepare([root], folder: "/workspace")
        let target = ImportFixtureDestination()
        let transfer = Task {
            try await plan.send(to: target) { state in
                if state.transferredBytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await transfer.value; XCTFail("Cancelled import succeeded") } catch is CancellationError {}
        let directories = await target.directories
        let files = await target.files
        XCTAssertEqual(directories.count, 1, "Completed directory is retained")
        XCTAssertTrue(files.isEmpty, "Incomplete and later files must not be published")
    }

    func testExistingDirectoryStopsImportWithoutMerging() async throws {
        let root = try fixture()
        try Data([1]).write(to: root.appendingPathComponent("file"))
        let plan = try FileImportPlan.prepare([root], folder: "/workspace")
        let target = ImportFixtureDestination(existing: [plan.items[0].destination])
        do { try await plan.send(to: target) { _ in }; XCTFail("Existing directory was accepted") } catch {}
        let files = await target.files
        XCTAssertTrue(files.isEmpty)
    }

    func testInputCancellationStopsFurtherReads() async throws {
        let root = try fixture(), file = root.appendingPathComponent("file")
        try Data(repeating: 3, count: 200_000).write(to: file)
        let input = try FileInput(url: file, limit: 200_000)
        var stream = input.stream().makeAsyncIterator()
        let first = await stream.next()
        XCTAssertEqual(first?.count, 65_536)
        input.cancel()
        let next = await stream.next()
        XCTAssertNil(next)
    }
}

private actor ImportProgressRecorder {
    var values: [FileImportProgress] = []
    func append(_ value: FileImportProgress) { values.append(value) }
}

private actor ImportFixtureDestination: FileImportDestination {
    var directories: [String] = []
    var files: [String: Data] = [:]
    var existing: Set<String>
    init(existing: Set<String> = []) { self.existing = existing }
    func createImportDirectory(_ path: String) async throws {
        guard existing.insert(path).inserted else { throw CocoaError(.fileWriteFileExists) }
        directories.append(path)
    }
    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let input = try FileInput(url: source, limit: Int64(size), progress: progress)
        var data = Data()
        for await chunk in input.stream() { try Task.checkCancellation(); data.append(chunk) }
        try Task.checkCancellation()
        guard existing.insert(path).inserted else { throw CocoaError(.fileWriteFileExists) }
        files[path] = data
    }
}
