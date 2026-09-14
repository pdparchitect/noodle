import Foundation
import XCTest
@testable import LocalMacCore

final class FileWorkerTests: XCTestCase {
    @MainActor func testFolderConsentDoesNotBlockOtherReadsOrAccumulateDuplicateListings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "First folder is waiting for consent")
        let ready = expectation(description: "Workspace stays readable")
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var first = true
        let worker = LocalMacFileWorker(home: root.path) {
            lock.lock(); let shouldWait = first; first = false; lock.unlock()
            if shouldWait {
                entered.fulfill()
                guard gate.wait(timeout: .now() + 5) == .success else { throw LocalMacError("Consent test timed out") }
            }
        }
        var blockedRequest = LocalMacRequest(.fileList); blockedRequest.path = "/Desktop"
        let blocked = Task { try await worker.handle(blockedRequest) }
        await fulfillment(of: [entered], timeout: 2)
        var otherRequest = LocalMacRequest(.fileList); otherRequest.path = "/workspace"
        let other = Task {
            let result = try await worker.handle(otherRequest)
            ready.fulfill()
            return result
        }
        await fulfillment(of: [ready], timeout: 2)
        var duplicate = LocalMacRequest(.fileList); duplicate.path = root.path + "/./Desktop/"
        do { _ = try await worker.handle(duplicate); XCTFail("A duplicate listing must not wait behind consent") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still being read")) }
        gate.signal()
        let blockedResult = try await blocked.value, otherResult = try await other.value
        XCTAssertEqual(blockedResult.files?.count, 0)
        XCTAssertEqual(otherResult.files?.count, 0)
        // The duplicate reservation is released when the original completes.
        let retried = try await worker.handle(duplicate)
        XCTAssertEqual(retried.files?.count, 0)
        await withCheckedContinuation { continuation in worker.close { continuation.resume() } }
    }
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
