import XCTest
@testable import LocalMacCore

final class ServiceProbeTests: XCTestCase {
    func testUnlaunchableRegisteredServiceTimesOutWithoutCallbacks() async {
        let result = await LocalMacServiceProbe.waitForReply(timeout: 0.01) { _ in }
        XCTAssertFalse(result)
    }
    func testReplyAndXPCErrorRaceCompletesOnlyOnce() async {
        let result = await LocalMacServiceProbe.waitForReply(timeout: 0.05) { finish in
            finish(true)
            finish(false)
        }
        XCTAssertTrue(result)
        try? await Task.sleep(for: .milliseconds(75))
    }
    func testLateReplyAfterTimeoutIsIgnored() async {
        let result = await LocalMacServiceProbe.waitForReply(timeout: 0.01) { finish in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { finish(true) }
        }
        XCTAssertFalse(result)
        try? await Task.sleep(for: .milliseconds(50))
    }
}
