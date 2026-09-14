import Foundation
import XCTest
@testable import LocalMacCore

final class FileWorkerTests: XCTestCase {
    @MainActor func testFileWaitLeavesTheMainQueueAvailableAndRechecksSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var verifications = 0
        let worker = LocalMacFileWorker(home: root.path) {
            // Model a filesystem call waiting for a consent action delivered on
            // the main queue. It must never block capture/input from delivering it.
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            guard answered.wait(timeout: .now() + 2) == .success else { throw LocalMacError("Main queue blocked") }
            verifications += 1
        }
        let request = LocalMacRequest(.fileHome)
        let result = try await worker.handle(request)
        XCTAssertEqual(result.id, request.id); XCTAssertEqual(result.homeDirectory, "/")
        var list = LocalMacRequest(.fileList); list.path = "/"
        let listing = try await worker.handle(list)
        XCTAssertEqual(listing.files?.count, 0)
        XCTAssertEqual(verifications, 2)
        await withCheckedContinuation { continuation in worker.close { continuation.resume() } }
        do { _ = try await worker.handle(request); XCTFail("Closed worker accepted a request") } catch {}
    }
    func testRejectedSessionCannotModifyFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LocalMacFileWorker(home: root.path) { throw LocalMacError("Wrong session") }
        var request = LocalMacRequest(.fileMkdir); request.path = "/created"
        do { _ = try await worker.handle(request); XCTFail("Unverified session accepted") }
        catch { XCTAssertEqual(error.localizedDescription, "Wrong session") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("created").path))
        await withCheckedContinuation { continuation in worker.close { continuation.resume() } }
    }
}
