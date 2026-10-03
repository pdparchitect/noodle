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
        // The reply is sent only once the timeout has answered, however slow the machine.
        let late = LateReply()
        let result = await LocalMacServiceProbe.waitForReply(timeout: 0.01) { late.finish = $0 }
        XCTAssertFalse(result)
        late.finish?(true)
    }
}

private final class LateReply: @unchecked Sendable {
    var finish: (@Sendable (Bool) -> Void)?
}
