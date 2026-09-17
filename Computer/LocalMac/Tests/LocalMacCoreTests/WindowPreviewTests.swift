import Foundation
import LocalMacPrivate
import XCTest
@testable import LocalMacCore

final class WindowPreviewTests: XCTestCase {
    func testFocusMatchesOnlyTheSameProcessAndUnambiguousWindow() {
        let bounds = CGRect(x: 500, y: 200, width: 900, height: 600)
        var candidates: [LocalMacWindowMatch.Candidate] = [
            .init(id: 1, pid: 50, title: "Document", bounds: bounds),
            .init(id: 2, pid: 60, title: "Document", bounds: bounds)
        ]
        XCTAssertEqual(LocalMacWindowMatch.find(pid: 50, title: "Document", bounds: bounds, in: candidates), 1)
        XCTAssertNil(LocalMacWindowMatch.find(pid: 70, title: "Document", bounds: bounds, in: candidates))
        candidates.append(.init(id: 3, pid: 50, title: "Document", bounds: bounds))
        XCTAssertNil(LocalMacWindowMatch.find(pid: 50, title: "Document", bounds: bounds, in: candidates))
        candidates[2].title = "Other"
        XCTAssertEqual(LocalMacWindowMatch.find(pid: 50, title: "Other", bounds: bounds, in: candidates), 3)
        XCTAssertNil(LocalMacWindowMatch.find(pid: 50, title: "Other", bounds: bounds.offsetBy(dx: 10, dy: 0), in: candidates))
    }
    func testCropIncludesChildPixelsBeyondParentAndIgnoresRowPadding() {
        let width = 10, height = 8, stride = 48
        var pixels = [UInt8](repeating: 0, count: stride * height)
        for y in 2..<6 { for x in 3..<7 { pixels[y * stride + x * 4 + 3] = 255 } }
        pixels[1 * stride + 8 * 4 + 3] = 255 // child extending above and right
        for y in 0..<height { pixels[y * stride + 47] = 255 } // not image pixels
        let crop = pixels.withUnsafeBufferPointer { NLMVisiblePixelBounds($0.baseAddress!, width, height, stride) }
        XCTAssertEqual(crop, CGRect(x: 3, y: 1, width: 6, height: 5))
        pixels = [UInt8](repeating: 0, count: stride * height)
        XCTAssertTrue(pixels.withUnsafeBufferPointer { NLMVisiblePixelBounds($0.baseAddress!, width, height, stride) }.isNull)
        XCTAssertTrue(pixels.withUnsafeBufferPointer { NLMVisiblePixelBounds($0.baseAddress!, width, height, 4) }.isNull)
    }
    func testFrameGeometryMapsRetinaPixelsIntoOffsetDesktopPoints() throws {
        let frame = LocalMacWindowFrame(previewID: UUID(), bounds: CGRect(x: 900, y: 350, width: 700, height: 500), width: 1400, height: 1000)
        XCTAssertEqual(frame.display.desktopPoint(x: 0.5, y: 0.5, bounds: frame.bounds), CGPoint(x: 1250, y: 600))
        XCTAssertEqual(frame.display.desktopPoint(x: 1, y: 1, bounds: frame.bounds), CGPoint(x: 1600, y: 850))
        let window = LocalMacWindow(id: 42, pid: 100, title: "Document", application: "Editor")
        var request = LocalMacRequest(.windowPreview)
        XCTAssertThrowsError(try request.validate())
        request.previewID = frame.previewID; request.enabled = true; request.window = window
        let decoded = try LocalMacWire.decode(LocalMacRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
        XCTAssertEqual(decoded.window, window); XCTAssertEqual(decoded.previewID, frame.previewID)
        var reply = LocalMacReply(); reply.frame = true; reply.windowFrame = frame
        reply.previewID = frame.previewID
        var status = LocalMacStatus(screenCapture: true, accessibility: true, postEvents: true, display: .init())
        status.focusedWindow = window; reply.status = status
        let received = try LocalMacWire.decode(LocalMacReply.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(received.windowFrame, frame); XCTAssertEqual(received.previewID, frame.previewID)
        XCTAssertEqual(received.status?.focusedWindow, window)
        var input = LocalMacInput(.down); input.previewID = frame.previewID
        XCTAssertThrowsError(try input.validate())
        input.geometryID = frame.geometryID; request = LocalMacRequest(.input); request.input = input
        let sent = try LocalMacWire.decode(LocalMacRequest.self, from: JSONEncoder().encode(request))
        try sent.validate(); XCTAssertEqual(sent.input?.geometryID, frame.geometryID)
        XCTAssertEqual(sent.input?.previewID, frame.previewID)
    }
    func testPreviousHelperFailsCompatibilityHandshake() {
        XCTAssertThrowsError(try LocalMacWire.checkVersion(1))
    }
}
