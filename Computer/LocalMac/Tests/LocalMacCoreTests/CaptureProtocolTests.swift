import Foundation
import XCTest
@testable import LocalMacCore

final class CaptureProtocolTests: XCTestCase {
    func testCaptureRequiresASeparateDisplayRegardlessOfResolution() throws {
        try LocalMacCapturePolicy.validate(displayID: 99, isBuiltin: false, protectedIDs: [2, 3])
        for id in [0, 2, 3] as [UInt32] {
            XCTAssertThrowsError(try LocalMacCapturePolicy.validate(displayID: id, isBuiltin: false, protectedIDs: [2, 3]))
        }
        XCTAssertThrowsError(try LocalMacCapturePolicy.validate(displayID: 99, isBuiltin: true, protectedIDs: [2]))
        for ids in [[], [0], [2, 2], Array(1...33)] as [[UInt32]] {
            XCTAssertThrowsError(try LocalMacCapturePolicy.validateProtectedDisplays(ids))
        }
    }
    func testCaptureAuthorizationSurvivesWireRoundTrip() throws {
        var request = LocalMacRequest(.stream); request.enabled = true
        XCTAssertThrowsError(try request.validate())
        request.protectedDisplayIDs = [2, 3]
        let decoded = try LocalMacWire.decode(LocalMacRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
        XCTAssertEqual(decoded.protectedDisplayIDs, [2, 3])
        request.enabled = false; request.protectedDisplayIDs = nil
        XCTAssertNoThrow(try request.validate())
    }
    func testLegacyAndFuturePeersFailBeforeDecodingOrExecutingOperations() throws {
        for version in [nil, 0, LocalMacWire.version + 1] as [Int?] {
            var payload: [String: Any] = ["operation": "futureUnsupportedOperation"]
            payload["protocolVersion"] = version
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(try LocalMacWire.decode(LocalMacRequest.self, from: data)) {
                XCTAssertTrue($0.localizedDescription.contains("incompatible"))
            }
            XCTAssertThrowsError(try LocalMacWire.decode(LocalMacReply.self, from: data)) {
                XCTAssertTrue($0.localizedDescription.contains("incompatible"))
            }
        }
        let reply = LocalMacReply(id: UUID())
        XCTAssertEqual(try LocalMacWire.decode(LocalMacReply.self, from: JSONEncoder().encode(reply)).id, reply.id)
    }
}
