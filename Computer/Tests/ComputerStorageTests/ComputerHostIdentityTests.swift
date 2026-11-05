import ComputerBridge
import XCTest
@testable import ComputerEngine

/// The engine serves Noodle's apps only from Noodle Computer's own builds, and keeps Noodle Computer's
/// names wherever Noodle runs it.
@MainActor final class ComputerHostIdentityTests: XCTestCase {
    func testOnlyNoodleComputerServesItsSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        // The test runner is no Noodle Computer build, as another product's app would not be.
        XCTAssertNil(ComputerBuildIdentity.provider(Bundle.main.bundleIdentifier))
        XCTAssertThrowsError(try ComputerProvider(store: store, listens: false))
        XCTAssertNoThrow(try ComputerProvider(store: store, socket: root.appendingPathComponent("c.sock"), listens: false))
        for identity in ComputerBuildIdentity.allCases {
            XCTAssertEqual(ComputerBuildIdentity.provider(identity.providerID), identity)
            for client in identity.clientIDs { XCTAssertNil(ComputerBuildIdentity.provider(client), client) }
        }
    }

    func testNoodleKeepsNoodleComputersNames() {
        XCTAssertEqual(ComputerAppIdentity.name, "Noodle Computer")
        XCTAssertEqual(ComputerAppIdentity.libraryFolder, "Noodle Computer")
        XCTAssertEqual(ComputerAppIdentity.subsystem, "com.pdparchitect.noodle.computer")
    }
}
