import XCTest
@testable import NoodleCore

final class UpdateRelaunchTests: XCTestCase {
    // Guard the production wiring: no runtime-state policy may intercept Sparkle
    // or cancel its normal application termination path.
    func testSparkleOwnsRelaunchWithoutApplicationVeto() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let updater = try String(contentsOf: root.appendingPathComponent("Sources/Noodle/AppUpdater.swift"))
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Noodle/NoodleApp.swift"))
        let store = try String(contentsOf: root.appendingPathComponent("Sources/Noodle/NoodleStore.swift"))
        XCTAssertTrue(updater.contains("updaterDelegate: nil"))
        XCTAssertFalse(updater.contains("shouldPostponeRelaunchForUpdate"))
        XCTAssertFalse(updater.contains("NoodleStore.active"))
        XCTAssertFalse(updater.contains("isWaitingToRelaunch"))
        XCTAssertFalse(app.contains("applicationShouldTerminate"))
        XCTAssertFalse(store.contains("canRelaunchForUpdate"))
        XCTAssertTrue(app.contains("NoodleStore.active?.stopMonitoring()"))
        XCTAssertTrue(store.contains("runtime.stopAll()"))
    }

    func testSleepPreventionRemainsIndependentOfUpdates() {
        XCTAssertFalse(AgentSleepPolicy.shouldPreventIdleSleep(enabled: false, phases: [.working]))
        XCTAssertFalse(AgentSleepPolicy.shouldPreventIdleSleep(enabled: true, phases: [.ready, .starting]))
        XCTAssertTrue(AgentSleepPolicy.shouldPreventIdleSleep(enabled: true, phases: [.ready, .working]))
    }
}
