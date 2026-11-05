import ProductIdentity
import XCTest

final class ProductIdentityTests: XCTestCase {
    func testEveryNoodleAppAndHelperIsNoodle() {
        for id in ["com.pdparchitect.noodle", "com.pdparchitect.noodle.local", "com.pdparchitect.noodle.integration",
                   "com.pdparchitect.noodle.agent-host", "com.pdparchitect.noodle.hub", "com.pdparchitect.noodle.hub.agent-host",
                   "com.pdparchitect.noodle.computer", "com.pdparchitect.noodle.computer.tests",
                   "com.pdparchitect.noodle.tools.computer"] {
            XCTAssertEqual(ProductIdentity.identify(id), .noodle, id)
        }
    }

    func testPionsAppsArePion() {
        for id in ["com.pdparchitect.pion", "com.pdparchitect.pion.local", "com.pdparchitect.pion.agent-host"] {
            XCTAssertEqual(ProductIdentity.identify(id), .pion, id)
        }
        XCTAssertEqual(ProductIdentity.pion.identifier("runtime"), "com.pdparchitect.pion.runtime")
    }

    /// Only the whole identifier, or one followed by a dot, belongs to a product.
    func testALookalikeIsNotPion() {
        XCTAssertEqual(ProductIdentity.identify("com.pdparchitect.pionx"), .noodle)
        XCTAssertEqual(ProductIdentity.identify("com.example.pion"), .noodle)
    }

    func testWithoutABundleItIsNoodleAsBefore() {
        XCTAssertEqual(ProductIdentity.identify(nil), .noodle)
        XCTAssertEqual(ProductIdentity.identify("com.apple.dt.xctest.tool"), .noodle)
        XCTAssertEqual(ProductIdentity.noodle.identifier("runtime"), "com.pdparchitect.noodle.runtime")
    }
}
