import Foundation
import XCTest
@testable import SuperBotCore

final class JSONLineReaderTests: XCTestCase {
    func testFragmentedUnicodeAndMultipleLinesRemainOrdered() async {
        let first = expectation(description: "First message")
        let second = expectation(description: "Second message")
        let reader = JSONLineReader { message in
            XCTAssertFalse(Thread.isMainThread)
            switch message["id"] as? Int {
            case 1:
                XCTAssertEqual(message["text"] as? String, "Hello 🐴")
                first.fulfill()
            case 2:
                second.fulfill()
            default:
                XCTFail("Unexpected message")
            }
        }
        let input = Data("\nnot JSON\n{\"id\":1,\"text\":\"Hello 🐴\"}\n{\"id\":2}\n".utf8)
        for byte in input { reader.receive(Data([byte])) }
        await fulfillment(of: [first, second], timeout: 3, enforceOrder: true)
    }

    @MainActor
    func testLargeFragmentedHistoryIsDecodedOffMainThread() async throws {
        let decoded = expectation(description: "Large history decoded")
        let body = String(repeating: "x", count: 8_388_608)
        let reader = JSONLineReader { message in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(message["history"] as? String, body)
            decoded.fulfill()
        }
        let input = try JSONSerialization.data(withJSONObject: ["history": body]) + Data([0x0A])
        for start in stride(from: 0, to: input.count, by: 4096) {
            reader.receive(input[start..<min(start + 4096, input.count)])
        }
        await fulfillment(of: [decoded], timeout: 5)
    }
}
