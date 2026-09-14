import Foundation
import CoreGraphics
import XCTest
@testable import LocalMacCore

final class BoundaryTests: XCTestCase {
    func testPointerMappingExcludesCapturePadding() {
        let display = LocalMacDisplay()
        let wide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let center = display.desktopPoint(x: 0.5, y: 0.5, bounds: wide)!
        XCTAssertEqual(center.x, 1720, accuracy: 0.001)
        XCTAssertEqual(center.y, 720, accuracy: 0.001)
        XCTAssertNil(display.desktopPoint(x: 0.5, y: 0.1, bounds: wide))
        XCTAssertNil(display.desktopPoint(x: 0.5, y: 0.9, bounds: wide))
        XCTAssertEqual(display.desktopPoint(x: 0.5, y: 0.9, bounds: wide, clamp: true), CGPoint(x: wide.midX, y: wide.maxY))
        let button = CGPoint(x: 2040, y: 980)
        let scale = 1280.0 / 3440
        let imageY = (800 - 1440 * scale) / 2 + button.y * scale
        let mapped = display.desktopPoint(x: button.x * scale / 1280, y: imageY / 800, bounds: wide)!
        XCTAssertEqual(mapped.x, button.x, accuracy: 0.001)
        XCTAssertEqual(mapped.y, button.y, accuracy: 0.001)
        XCTAssertEqual(display.desktopPoint(x: 0.25, y: 0.75, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)), CGPoint(x: 320, y: 600))
    }
    func testSessionRejectsConsoleAndReusedIdentity() throws {
        let account = LocalMacAccount(computerID: UUID(), ownerUID: 501, uid: 502, directoryID: UUID(), display: .init())
        var record: [String: Any] = ["kCGSSessionIDKey": 270, "kCGSSessionAuditIDKey": 1234,
            "CGSSessionUniqueSessionUUID": UUID().uuidString, "kCGSSessionUserIDKey": 502,
            "kCGSSessionUserNameKey": account.name, "kCGSSessionOnConsoleKey": false, "kCGSessionLoginDoneKey": true]
        let session = try LocalMacSession(account: account, record: record)
        XCTAssertTrue(session.matches(record))
        record["kCGSSessionOnConsoleKey"] = true
        XCTAssertFalse(session.matches(record))
        XCTAssertThrowsError(try LocalMacSession(account: account, record: record))
        record["kCGSSessionOnConsoleKey"] = false
        record["CGSSessionUniqueSessionUUID"] = UUID().uuidString
        XCTAssertFalse(session.matches(record))
        record["kCGSSessionUserIDKey"] = 501
        XCTAssertThrowsError(try LocalMacSession(account: account, record: record))
    }
    func testOwnershipCannotAdoptMainOrForeignAccount() throws {
        var account = LocalMacAccount(computerID: UUID(), ownerUID: 501, uid: 502, directoryID: UUID(), display: .init())
        try account.validate(owner: 501)
        XCTAssertThrowsError(try account.validate(owner: 503))
        account.uid = 501
        XCTAssertThrowsError(try account.validate(owner: 501))
        account.uid = 0
        XCTAssertThrowsError(try account.validate(owner: 501))
    }
    func testBoundedDisplayAndInput() throws {
        XCTAssertEqual(LocalMacDisplay().width, 1280)
        XCTAssertEqual(LocalMacDisplay().height, 800)
        XCTAssertThrowsError(try LocalMacDisplay(width: 3440, height: 1440).validate())
        XCTAssertThrowsError(try LocalMacDisplay(width: 1281, height: 800).validate())
        var input = LocalMacInput(.move); input.x = .nan
        XCTAssertThrowsError(try input.validate())
        var request = LocalMacRequest(.terminalResize); request.width = 100; request.height = 0
        XCTAssertThrowsError(try request.validate())
    }
    func testFramingRejectsOversizeWithoutReadingBody() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data([0x7f, 0xff, 0xff, 0xff]))
        XCTAssertThrowsError(try LocalMacWire.read(pipe.fileHandleForReading))
        try pipe.fileHandleForWriting.close(); try pipe.fileHandleForReading.close()
    }
    func testFramingRoundTripAndTruncation() throws {
        let pipe = Pipe(), payload = Data("account frame".utf8)
        try LocalMacWire.write(payload, to: pipe.fileHandleForWriting)
        XCTAssertEqual(try LocalMacWire.read(pipe.fileHandleForReading), payload)
        try pipe.fileHandleForWriting.write(contentsOf: Data([0, 0, 0, 4, 1]))
        try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(try LocalMacWire.read(pipe.fileHandleForReading))
        try pipe.fileHandleForReading.close()
    }
}
