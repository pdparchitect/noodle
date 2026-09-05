import Foundation
import XCTest
@testable import SuperBotCore

final class ProcessInputWriterTests: XCTestCase {
    @MainActor
    func testStalledReaderDoesNotBlockCallerAndWritesRemainOrdered() async {
        let pipe = Pipe()
        let writer = ProcessInputWriter(handle: pipe.fileHandleForWriting)
        // Larger than a pipe's capacity: a synchronous write cannot return
        // until the reader starts consuming it.
        let first = Data(repeating: 0x41, count: 1_048_576)
        let second = Data("\nsecond request\n".utf8)
        let expected = first + second
        let callerReturned = DispatchSemaphore(value: 0)
        let drained = expectation(description: "All requests arrived in order")

        DispatchQueue.global().async {
            let result = callerReturned.wait(timeout: .now() + 3)
            XCTAssertEqual(result, .success, "Writing to a stalled child blocked the caller")
            var received = Data()
            while received.count < expected.count {
                let chunk = pipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                received.append(chunk)
            }
            XCTAssertEqual(received, expected)
            drained.fulfill()
        }

        writer.write(first) { error in XCTFail("First write failed: \(error)") }
        writer.write(second) { error in XCTFail("Second write failed: \(error)") }
        callerReturned.signal()
        await fulfillment(of: [drained], timeout: 5)
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }

    func testWriteFailureIsReported() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        let writer = ProcessInputWriter(handle: pipe.fileHandleForWriting)
        let failed = expectation(description: "Closed pipe error reported")
        writer.write(Data("request".utf8)) { _ in failed.fulfill() }
        await fulfillment(of: [failed], timeout: 3)
        try pipe.fileHandleForReading.close()
    }
}
