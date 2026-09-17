import XCTest
@testable import LocalMacCore

final class ApplicationFocusTests: XCTestCase {
    private func candidates(_ pids: [Int32]) -> [LocalMacApplicationFocus.Candidate] {
        pids.map { .init(pid: $0, layer: 0) }
    }
    func testMissingWorkspaceFocusRecoversFromExplicitAccountFocus() {
        var queried: [Int32] = []
        let pid = LocalMacApplicationFocus.resolve(workspacePID: nil, candidates: candidates([90, 50, 50, 60]),
            belongsToAccount: { [50, 60].contains($0) }, isFrontmost: {
                queried.append($0)
                return $0 == 50
            })
        XCTAssertEqual(pid, 50)
        XCTAssertEqual(queried, [50, 60]) // Never query another account; deduplicate windows.
    }

    func testDesktopWidgetsCannotMakeApplicationFocusAmbiguous() {
        let windows: [LocalMacApplicationFocus.Candidate] = [
            .init(pid: 70, layer: 20), // Dock overlay
            .init(pid: 50, layer: 0),  // Chrome window
            .init(pid: 80, layer: -2_147_483_601) // Desktop widgets also report AXFrontmost=true
        ]
        var queried: [Int32] = []
        XCTAssertEqual(LocalMacApplicationFocus.resolve(workspacePID: nil, candidates: windows,
            belongsToAccount: { _ in true }, isFrontmost: { queried.append($0); return true }), 50)
        XCTAssertEqual(queried, [50])
    }

    func testMissingFocusDoesNotGuessFromWindowOrderOrUnreadableApps() {
        for result: Bool? in [false, nil] {
            XCTAssertNil(LocalMacApplicationFocus.resolve(workspacePID: nil, candidates: candidates([50, 60]),
                belongsToAccount: { _ in true }, isFrontmost: { _ in result }))
        }
        XCTAssertNil(LocalMacApplicationFocus.resolve(workspacePID: nil, candidates: candidates([50, 60]),
            belongsToAccount: { _ in true }, isFrontmost: { _ in true }))
        XCTAssertNil(LocalMacApplicationFocus.resolve(workspacePID: nil, candidates: candidates([-1, 0, 90]),
            belongsToAccount: { _ in false }, isFrontmost: { _ in
                XCTFail("An invalid or foreign PID must not be queried")
                return true
            }))
    }

    func testKnownWorkspaceFocusWinsAndForeignFocusFailsClosed() {
        for workspace: Int32 in [50, 90, 0] {
            let pid = LocalMacApplicationFocus.resolve(workspacePID: workspace, candidates: candidates([60]),
                belongsToAccount: { [50, 60].contains($0) }, isFrontmost: { _ in
                    XCTFail("A known frontmost app must not be replaced with another window")
                    return true
                })
            XCTAssertEqual(pid, workspace == 50 ? 50 : nil)
        }
    }

    func testPreviewInputStopsFollowingItsAppWhenFocusChanges() {
        // The same fallback is used for preview input. Recovering detection
        // alone would open a panel whose clicks/keys are still rejected.
        var frontmost: Int32 = 50
        func inputTarget() -> Int32? {
            LocalMacApplicationFocus.resolve(workspacePID: nil, candidates: candidates([50]),
                belongsToAccount: { $0 == 50 }, isFrontmost: { $0 == frontmost })
        }
        XCTAssertEqual(inputTarget(), 50)
        frontmost = 60
        XCTAssertNil(inputTarget())
        frontmost = 50
        XCTAssertEqual(inputTarget(), 50)
    }
}
