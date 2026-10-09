#if DEBUG
import XCTest
@testable import NoodleComputer

final class NeptuneArenaMappingTests: XCTestCase {
    func testStoppingRequiresAFreshMapping() throws {
        var mapping = NeptuneArenaMapping()
        let first = try XCTUnwrap(mapping.begin())
        XCTAssertNil(mapping.begin())
        XCTAssertTrue(mapping.complete(first, succeeded: true))
        XCTAssertTrue(mapping.isReady)
        XCTAssertNil(mapping.begin())
        mapping.stopped()
        XCTAssertFalse(mapping.isReady)
        XCTAssertNotNil(mapping.begin())
    }

    func testAnOldCompletionCannotOverwriteTheNewRun() throws {
        var mapping = NeptuneArenaMapping()
        let first = try XCTUnwrap(mapping.begin())
        mapping.stopped()
        let second = try XCTUnwrap(mapping.begin())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(mapping.complete(first, succeeded: true))
        XCTAssertFalse(mapping.isReady)
        XCTAssertTrue(mapping.complete(second, succeeded: true))
        XCTAssertFalse(mapping.complete(first, succeeded: false))
        XCTAssertTrue(mapping.isReady)
    }

    func testFailedMapsCanBeRetried() throws {
        var mapping = NeptuneArenaMapping()
        let first = try XCTUnwrap(mapping.begin())
        XCTAssertTrue(mapping.complete(first, succeeded: false))
        XCTAssertFalse(mapping.isReady)
        XCTAssertNotNil(mapping.begin())
    }
}
#endif
