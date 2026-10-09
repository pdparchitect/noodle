@testable import AppletBridge
import XCTest

final class ConnectionPatienceTests: XCTestCase {
    /// A call waits as long as its operation may take: packing a large noodlet for a phone takes
    /// longer than a quick question.
    func testACallWaitsAsLongAsItsOperationMayTake() {
        for operation in AppletOperation.allCases {
            XCTAssertEqual(AppletConnection.patience(for: operation), operation.timeout, operation.rawValue)
        }
        XCTAssertEqual(AppletConnection.patience(for: .archive), 180)
    }
}
