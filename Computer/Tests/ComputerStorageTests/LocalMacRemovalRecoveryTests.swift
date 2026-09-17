import Darwin
import Foundation
import LocalMacCore
import XCTest
@testable import NoodleComputer

@MainActor final class LocalMacRemovalRecoveryTests: XCTestCase {
    func testOnlyPrivacyFailureOffersSettingsAndDismissalClearsAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let denied = LocalMacRemovalFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: [
            "LocalMacRemovalPath": "Desktop", "LocalMacRemovalOperation": "open", "LocalMacRemovalPreflight": true
        ]))
        store.recordRemovalFailure(denied)
        XCTAssertEqual(store.errorRecovery, .fullDiskAccess)
        XCTAssertTrue(store.error?.contains("Desktop") == true)
        store.error = nil
        XCTAssertNil(store.errorRecovery)
        store.recordRemovalFailure(denied)
        store.recordRemovalFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        XCTAssertNil(store.errorRecovery)
    }
    func testUnreachableHelperOffersRepairAndNamesDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        store.recordRemovalFailure(LocalMacSetupRequired(registration: .enabled))
        XCTAssertEqual(store.errorRecovery, .repair)
        XCTAssertTrue(store.error?.contains("retry Delete") == true)
        XCTAssertFalse(store.error?.contains("retry Start") == true)
        XCTAssertEqual(store.errorRecovery?.actionTitle, "Repair Local Mac…")
        store.error = nil
        XCTAssertNil(store.errorRecovery)
    }
}
