import AppKit
import XCTest
import LocalMacCore
@testable import NoodleComputer

@MainActor final class LocalMacPointerTests: XCTestCase {
    func testOrdinaryMouseEventsDoNotReadScrollOnlyProperties() throws {
        let types: [(NSEvent.EventType, LocalMacInput.Kind)] = [
            (.leftMouseDown, .down), (.leftMouseUp, .up), (.rightMouseDown, .down),
            (.rightMouseUp, .up), (.mouseMoved, .move), (.leftMouseDragged, .move)
        ]
        for (type, kind) in types {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            let input = try XCTUnwrap(LocalMacPointerEvent.make(event, kind: kind,
                point: CGPoint(x: 100, y: 75), rect: CGRect(x: 0, y: 0, width: 200, height: 100)))
            XCTAssertEqual(input.x, 0.5); XCTAssertEqual(input.y, 0.75)
            XCTAssertEqual(input.scroll, 0)
        }
    }
    func testScrollUsesScrollProperties() throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        let input = try XCTUnwrap(LocalMacPointerEvent.make(event, kind: .scroll,
            point: CGPoint(x: 50, y: 50), rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(input.scroll, event.scrollingDeltaY)
        XCTAssertNotEqual(input.scroll, 0)
    }
    func testDragCanReleaseOutsideThePreview() throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        let rect = CGRect(x: 10, y: 10, width: 100, height: 100), point = CGPoint(x: 200, y: -10)
        XCTAssertNil(LocalMacPointerEvent.make(event, kind: .up, point: point, rect: rect))
        let release = try XCTUnwrap(LocalMacPointerEvent.make(event, kind: .up, point: point, rect: rect, clamp: true))
        XCTAssertEqual(release.x, 1); XCTAssertEqual(release.y, 0)
    }
    func testMotionBackpressurePreservesPressDragReleaseAndModifiers() {
        var queue = LocalMacInputQueue()
        XCTAssertTrue(queue.append(LocalMacInput(.flagsChanged)))
        XCTAssertTrue(queue.append(LocalMacInput(.down)))
        for index in 0..<2000 {
            var move = LocalMacInput(.move); move.x = Double(index) / 2000
            XCTAssertTrue(queue.append(move))
        }
        XCTAssertTrue(queue.append(LocalMacInput(.up)))
        XCTAssertTrue(queue.append(LocalMacInput(.keyDown)))
        XCTAssertTrue(queue.append(LocalMacInput(.keyUp)))
        XCTAssertEqual(queue.next()?.kind, .flagsChanged)
        XCTAssertEqual(queue.next()?.kind, .down)
        XCTAssertEqual(queue.next()?.x, 1999.0 / 2000)
        XCTAssertEqual(queue.next()?.kind, .up)
        XCTAssertEqual(queue.next()?.kind, .keyDown)
        XCTAssertEqual(queue.next()?.kind, .keyUp)
        XCTAssertNil(queue.next())
    }
    func testOverflowAndFocusLossReleaseHeldInput() {
        var queue = LocalMacInputQueue()
        for _ in 0..<512 { XCTAssertTrue(queue.append(LocalMacInput(.keyDown))) }
        XCTAssertFalse(queue.append(LocalMacInput(.keyUp)))
        XCTAssertEqual(queue.next()?.kind, .reset); XCTAssertNil(queue.next())
        XCTAssertTrue(queue.append(LocalMacInput(.down)))
        XCTAssertTrue(queue.append(LocalMacInput(.reset)))
        XCTAssertEqual(queue.next()?.kind, .reset); XCTAssertNil(queue.next())
    }
}
