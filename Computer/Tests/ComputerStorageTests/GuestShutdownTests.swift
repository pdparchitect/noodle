import ComputerCore
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

final class GuestShutdownTests: XCTestCase {
    @MainActor func testLinuxGuestThatIgnoresShutdownIsForceStopped() async throws {
        var requested = false, waited = false, forced = false
        try await ComputerStore.shutDownGuest(
            kind: .linux, request: { requested = true }, wait: { waited = true },
            stillRunning: { true }, forceStop: { forced = true })
        XCTAssertTrue(requested)
        XCTAssertTrue(waited)
        XCTAssertTrue(forced)
    }

    @MainActor func testLinuxGuestThatShutsDownIsNotForceStopped() async throws {
        var forced = false
        try await ComputerStore.shutDownGuest(
            kind: .linux, request: {}, wait: {}, stillRunning: { false }, forceStop: { forced = true })
        XCTAssertFalse(forced)
    }

    @MainActor func testMacGuestIsOnlyAskedToShutDown() async throws {
        var waited = false, forced = false
        try await ComputerStore.shutDownGuest(
            kind: .macOS, request: {}, wait: { waited = true }, stillRunning: { true }, forceStop: { forced = true })
        XCTAssertFalse(waited)
        XCTAssertFalse(forced)
    }
}
