import Foundation
import XCTest
@testable import Noodle

@MainActor final class AppPermissionCheckerTests: XCTestCase {
    func testRefreshReportsEveryPermissionAndCountsOnlyRefusals() async {
        let system: [AppPermission: AppPermissionStatus] = [
            .microphone: .denied, .screenRecording: .notRequested, .notifications: .allowed
        ]
        let checker = AppPermissionChecker(status: { system[$0] ?? .denied }, ask: { _ in })
        XCTAssertTrue(checker.statuses.isEmpty)
        XCTAssertEqual(checker.needingAttention, 0)

        await checker.refresh().value

        XCTAssertEqual(checker.statuses, system)
        XCTAssertEqual(checker.needingAttention, 1)
    }

    func testRequestAsksTheSystemOnceThenRereadsTheStatus() async {
        var system: [AppPermission: AppPermissionStatus] = [:]
        var asked: [AppPermission] = []
        let checker = AppPermissionChecker(
            status: { system[$0] ?? .notRequested },
            ask: { asked.append($0); system[$0] = $0 == .microphone ? .allowed : .denied })
        await checker.refresh().value
        XCTAssertEqual(checker.statuses[.microphone], .notRequested)

        await checker.request(.microphone)
        XCTAssertEqual(asked, [.microphone])
        XCTAssertEqual(checker.statuses[.microphone], .allowed)
        XCTAssertEqual(checker.needingAttention, 0)

        await checker.request(.screenRecording)
        XCTAssertEqual(asked, [.microphone, .screenRecording])
        XCTAssertEqual(checker.statuses[.screenRecording], .denied)
        XCTAssertEqual(checker.needingAttention, 1)
    }

    func testEveryPermissionOpensASystemSettingsPane() {
        for permission in AppPermission.allCases {
            XCTAssertEqual(permission.settingsURL?.scheme, "x-apple.systempreferences", permission.name)
        }
    }
}
