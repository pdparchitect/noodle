import SwiftUI
import AppKit
import RookCore
import XCTest

final class MissionGraphTests: XCTestCase {
    @MainActor func testMouseWheelZoomsWithoutScrollingAndTrackpadPassesThrough() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let pan = MissionGraphPanView(frame: document.bounds)
        document.addSubview(pan)
        scroll.documentView = document
        window.contentView = scroll
        defer { window.close(); window.contentView = nil }
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let start = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
        var viewport = MissionGraphViewport()
        pan.zoom = { viewport.zoom(by: $0) }
        let origin = clip.bounds.origin
        XCTAssertTrue(pan.handleWheel(delta: 2, precise: false, inverted: false, location: start, in: window))
        XCTAssertGreaterThan(viewport.scale, 1)
        XCTAssertEqual(clip.bounds.origin, origin)
        XCTAssertTrue(pan.handleWheel(delta: -2, precise: false, inverted: false, location: start, in: window))
        XCTAssertEqual(viewport.scale, 1, accuracy: 0.001)
        XCTAssertFalse(pan.handleWheel(delta: 20, precise: true, inverted: false, location: start, in: window))
        XCTAssertFalse(pan.handleWheel(delta: 2, precise: false, inverted: false, location: start, in: nil))
        XCTAssertFalse(pan.handleWheel(delta: 2, precise: false, inverted: false, location: CGPoint(x: -1000, y: -1000), in: window))
        XCTAssertEqual(viewport.scale, 1, accuracy: 0.001)
        XCTAssertTrue(pan.handleWheel(delta: -2, precise: false, inverted: true, location: start, in: window))
        XCTAssertGreaterThan(viewport.scale, 1)
        XCTAssertFalse(pan.isPanning)
    }

    @MainActor func testSheetSizeKeepsAnInsetWithoutGrowingBeyondItsParent() {
        XCTAssertEqual(MissionGraphView.sheetSize(in: CGSize(width: 1400, height: 900)), CGSize(width: 1304, height: 804))
        let small = MissionGraphView.sheetSize(in: CGSize(width: 400, height: 300))
        XCTAssertLessThanOrEqual(small.width, 400)
        XCTAssertLessThanOrEqual(small.height, 300)
        XCTAssertGreaterThan(small.width, 0)
        XCTAssertGreaterThan(small.height, 0)
    }

    @MainActor func testMiddleMousePansNativeScrollViewAndReleasesOutsideTheGraph() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let pan = MissionGraphPanView(frame: document.bounds)
        document.addSubview(pan)
        scroll.documentView = document
        window.contentView = scroll
        defer { pan.cancelPan(); window.close(); window.contentView = nil }
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 300, y: 200))
        let start = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
        XCTAssertFalse(pan.handle(.otherMouseDown, button: 3, location: start, in: window))
        XCTAssertFalse(pan.handle(.scrollWheel, button: 0, location: start, in: window))
        XCTAssertFalse(pan.isPanning)
        XCTAssertTrue(pan.handle(.otherMouseDown, button: 2, location: start, in: window))
        XCTAssertTrue(pan.isPanning)
        XCTAssertEqual(NSCursor.current, MissionGraphPanView.panCursor)
        let end = CGPoint(x: start.x + 60, y: start.y + 40)
        XCTAssertTrue(pan.handle(.otherMouseDragged, button: 2, location: end, in: window))
        XCTAssertEqual(clip.bounds.origin.x, 240, accuracy: 0.01)
        XCTAssertEqual(clip.bounds.origin.y, clip.isFlipped ? 240 : 160, accuracy: 0.01)
        // Leaving the viewport must not stop the operation or strand its cursor on release.
        XCTAssertTrue(pan.handle(.otherMouseDragged, button: 2, location: CGPoint(x: -500, y: -500), in: window))
        XCTAssertTrue(pan.isPanning)
        XCTAssertTrue(pan.handle(.otherMouseUp, button: 2, location: .zero, in: nil))
        XCTAssertFalse(pan.isPanning)
        XCTAssertNotEqual(NSCursor.current, MissionGraphPanView.panCursor)
    }

    @MainActor func testMiddlePanIgnoresOtherWindowsAndCancelsWhenRemoved() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let pan = MissionGraphPanView(frame: document.bounds)
        document.addSubview(pan)
        scroll.documentView = document
        window.contentView = scroll
        defer { window.close(); window.contentView = nil }
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let start = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
        XCTAssertFalse(pan.handle(.otherMouseDown, button: 2, location: start, in: nil))
        XCTAssertFalse(pan.handle(.otherMouseDown, button: 2, location: CGPoint(x: -1000, y: -1000), in: window))
        XCTAssertFalse(pan.handle(.leftMouseDown, button: 0, location: start, in: window))
        XCTAssertTrue(pan.handle(.otherMouseDown, button: 2, location: start, in: window))
        pan.removeFromSuperview()
        XCTAssertFalse(pan.isPanning)
        XCTAssertNotEqual(NSCursor.current, MissionGraphPanView.panCursor)
    }

    func testZoomProjectsDrawingCoordinatesAndPreservesDragDistance() {
        var viewport = MissionGraphViewport()
        viewport.setScale(2.5)
        let original = CGPoint(x: 200, y: 150)
        XCTAssertEqual(viewport.renderPosition(original), CGPoint(x: 500, y: 375))
        XCTAssertEqual(viewport.modelPosition(viewport.renderPosition(original)), original)
        XCTAssertEqual(viewport.renderSize(CGSize(width: 156, height: 64)), CGSize(width: 390, height: 160))
        var drag = MissionGraphInteraction()
        drag.positions = ["a": original]
        drag.move("a", start: CGPoint(x: 510, y: 380), location: CGPoint(x: 610, y: 430),
                  in: CGSize(width: 800, height: 600), scale: viewport.scale)
        XCTAssertEqual(drag.positions["a"], CGPoint(x: 240, y: 170))
    }

    func testZoomFitsLargeMapsAndClampsMagnification() {
        var viewport = MissionGraphViewport()
        viewport.fit(canvas: CGSize(width: 2400, height: 1200), inside: CGSize(width: 800, height: 600))
        XCTAssertEqual(viewport.scale, 1.0 / 3, accuracy: 0.001)
        viewport.zoom(by: 1.25)
        XCTAssertEqual(viewport.scale, 1.25 / 3, accuracy: 0.001)
        viewport.setScale(100)
        XCTAssertEqual(viewport.scale, 3)
        viewport.setScale(0)
        XCTAssertEqual(viewport.scale, 0.05)
        viewport.fit(canvas: CGSize(width: 400, height: 300), inside: CGSize(width: 800, height: 600))
        XCTAssertEqual(viewport.scale, 1)
    }

    @MainActor func testLargeLayoutDoesNotCompressCardsIntoOverlaps() {
        var record = CaseRecord()
        for index in 0..<30 {
            record.record(entity: .host, name: "Host \(index)", detail: nil,
                          by: .champion("Investigator"), at: Date(timeIntervalSince1970: 0))
        }
        let positions = MissionGraphView.layout(record, in: CGSize(width: 800, height: 600))
        XCTAssertEqual(positions.count, 30)
        for (index, entity) in record.entities.enumerated() {
            for other in record.entities.dropFirst(index + 1) {
                guard let a = positions[entity.id], let b = positions[other.id] else { continue }
                XCTAssertTrue(abs(a.x - b.x) >= 180 || abs(a.y - b.y) >= 96,
                              "Cards \(entity.id) and \(other.id) need room for their labels")
            }
        }
        XCTAssertEqual(positions, MissionGraphView.layout(record, in: CGSize(width: 800, height: 600)))
    }

    @MainActor func testLayoutFollowsDirectedPathsAndHandlesCycles() throws {
        var record = CaseRecord()
        let actor = CaseActor.champion("Investigator")
        let now = Date(timeIntervalSince1970: 0)
        let nodes = (0..<5).map { record.record(entity: .host, name: "Host \($0)", detail: nil, by: actor, at: now) }
        for index in 0..<4 {
            try record.record(linkFrom: nodes[index].id, relation: "reaches", to: nodes[index + 1].id, by: actor, at: now)
        }
        let positions = MissionGraphView.layout(record, in: CGSize(width: 800, height: 600))
        for index in 0..<4 {
            XCTAssertLessThan(try XCTUnwrap(positions[nodes[index].id]).x,
                              try XCTUnwrap(positions[nodes[index + 1].id]).x)
        }
        try record.record(linkFrom: nodes[4].id, relation: "returns", to: nodes[0].id, by: actor, at: now)
        let cyclic = MissionGraphView.layout(record, in: CGSize(width: 800, height: 600))
        XCTAssertEqual(cyclic.count, 5)
        XCTAssertTrue(cyclic.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testDraggingTracksThePointerWithoutJumpingOrAccumulatingMovement() {
        var drag = MissionGraphInteraction()
        drag.positions = ["a": CGPoint(x: 200, y: 150), "b": CGPoint(x: 400, y: 300)]
        let size = CGSize(width: 800, height: 600)
        let start = CGPoint(x: 210, y: 155)
        drag.move("a", start: start, location: CGPoint(x: 240, y: 175), in: size)
        XCTAssertEqual(drag.positions["a"], CGPoint(x: 230, y: 170))
        drag.move("a", start: start, location: CGPoint(x: 270, y: 195), in: size)
        XCTAssertEqual(drag.positions["a"], CGPoint(x: 260, y: 190))
        XCTAssertEqual(drag.positions["b"], CGPoint(x: 400, y: 300))
        drag.end()
        XCTAssertEqual(drag.positions["a"], CGPoint(x: 260, y: 190))
        drag.move("a", start: CGPoint(x: 260, y: 190), location: CGPoint(x: 280, y: 200), in: size)
        XCTAssertEqual(drag.positions["a"], CGPoint(x: 280, y: 200))
    }

    func testDraggingKeepsCardsInsideTheGraph() {
        var drag = MissionGraphInteraction()
        drag.positions = ["a": CGPoint(x: 200, y: 150)]
        drag.move("a", start: CGPoint(x: 200, y: 150), location: CGPoint(x: -500, y: 900),
                  in: CGSize(width: 800, height: 600))
        XCTAssertEqual(drag.positions["a"], CGPoint(x: 82, y: 562))
    }
}
