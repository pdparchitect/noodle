import AppKit
import XCTest

@testable import NoodleApplet

final class UISettleTests: XCTestCase {
    /// Pausing a fixed length of time after pressing a toolbar button is a race with the sidebar
    /// animation: on a loaded machine the toolbar is still rearranging when it is measured, and
    /// the check reads the old layout. Waiting for the frames to stop moving does not.
    @MainActor func testSettlingWaitsForTheFramesToStopMoving() async throws {
        var readings: [[CGRect]] = [
            [],
            [CGRect(x: 144, y: 630, width: 36, height: 36)],
            [CGRect(x: 96, y: 630, width: 39, height: 28)],
            [CGRect(x: 96, y: 630, width: 36, height: 36), CGRect(x: 144, y: 630, width: 36, height: 36)],
            [CGRect(x: 96, y: 630, width: 36, height: 36), CGRect(x: 144, y: 630, width: 36, height: 36)],
        ]
        var taken = 0
        let settled = await AppletUITest.settle(expecting: 2, sleep: { _ in }) {
            defer { taken += 1 }
            return readings.isEmpty ? [] : readings.removeFirst()
        }
        XCTAssertEqual(settled.count, 2, "Measured the toolbar while it was still rearranging")
        XCTAssertEqual(settled.first?.height, 36)
        XCTAssertGreaterThanOrEqual(taken, 5, "Stopped reading before the layout had settled")
    }

    /// The toolbar drops Open Noodlet when the window is too narrow for it, so a run that never
    /// sees the second item has to carry on with the one it has rather than hang.
    @MainActor func testSettlingGivesUpOnWhatNeverArrives() async throws {
        let only = [CGRect(x: 96, y: 630, width: 36, height: 36)]
        var taken = 0
        let settled = await AppletUITest.settle(attempts: 6, expecting: 2, sleep: { _ in }) {
            taken += 1
            return only
        }
        XCTAssertEqual(settled, only)
        XCTAssertLessThanOrEqual(taken, 7, "Kept waiting for an item that is never coming")
    }
}
