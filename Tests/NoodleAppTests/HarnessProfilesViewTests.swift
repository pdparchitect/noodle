import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class HarnessProfilesViewTests: HiddenViewTests {
    func testProfileRowsOfferSignInWhileTheirStatusIsUnknown() async throws {
        let f = try fixture()
        _ = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        // No executable: the status check cannot run, and sign-in must stay reachable.
        let sheet = host(HarnessProfilesView(installation: HarnessInstallation(provider: .codex, executablePath: nil))
            .environment(f.store))
        _ = try await control("Codex Profiles", in: sheet)
        _ = try await control("Work", in: sheet)
        for name in ["Sign In…", "Add Profile…", "Done"] {
            let button = try await control(name, in: sheet)
            XCTAssertTrue(enabled(button), name)
        }
    }
}
