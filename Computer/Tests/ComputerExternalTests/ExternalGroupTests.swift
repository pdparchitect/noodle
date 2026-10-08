import Foundation
import Testing

/// The external socket is out of reach of Noodle's bots only because no Noodle or Hub process
/// holds its app group. Browser's tests check every Noodle and Hub entitlement file; this checks
/// that Computer's group is the one they look for.
@Suite struct ExternalGroupTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func computerHoldsItsExternalGroupAndNoodleDoesNot() throws {
        let computer = try String(contentsOf: Self.repository.appendingPathComponent("Computer/Support/Computer.entitlements"), encoding: .utf8)
        #expect(computer.contains("$(COMPUTER_EXTERNAL_GROUP_SUFFIX)"))
        for path in ["Support/Noodle.entitlements", "Support/Noodle-Release.entitlements", "Hub/Support/Hub.entitlements", "Hub/Support/Hub-Release.entitlements"] {
            let text = try String(contentsOf: Self.repository.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.contains("EXTERNAL_GROUP") && !text.contains("external-"), "\(path) holds an external tools group")
        }
    }
}
