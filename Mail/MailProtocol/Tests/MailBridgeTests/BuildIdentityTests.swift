import XCTest
@testable import MailBridge

final class BuildIdentityTests: XCTestCase {
    private func ids(_ identity: MailBuildIdentity) -> [String] { [identity.providerID, identity.noodleID, identity.toolExtensionID] }

    /// Dev and production name different apps, groups and schemes, so their data and sockets never meet.
    func testDevelopmentAndProductionNeverShareAnIdentifier() {
        XCTAssertEqual(ids(.production), ["com.pdparchitect.noodle.mail", "com.pdparchitect.noodle", "com.pdparchitect.noodle.tools.mail"])
        XCTAssertEqual(ids(.development), ["com.pdparchitect.noodle.mail.local", "com.pdparchitect.noodle.local", "com.pdparchitect.noodle.local.tools.mail"])
        XCTAssertTrue(Set(ids(.production)).isDisjoint(with: ids(.development)))
        XCTAssertEqual(MailBuildIdentity.production.groupSuffix, "com.pdparchitect.noodle.mails")
        XCTAssertEqual(MailBuildIdentity.development.groupSuffix, "com.pdparchitect.noodle.mails.local")
        XCTAssertEqual(MailBuildIdentity.development.appName, "Noodle Mail Dev")
        XCTAssertEqual(MailBuildIdentity.development.urlScheme, "noodlemail-dev")
        XCTAssertEqual(MailBuildIdentity.production.clientIDs, ["com.pdparchitect.noodle", "com.pdparchitect.noodle.tools.mail"])
    }

    /// Only the three known identifiers of each environment are recognised; other Noodle apps are not.
    func testIdentifyKnowsOnlyMailIdentifiers() {
        XCTAssertEqual(MailBuildIdentity.identify("com.pdparchitect.noodle.mail.local"), .development)
        XCTAssertEqual(MailBuildIdentity.identify("com.pdparchitect.noodle.tools.mail"), .production)
        XCTAssertNil(MailBuildIdentity.identify("com.pdparchitect.noodle.browser"))
        XCTAssertNil(MailBuildIdentity.identify(nil))
    }

    /// A group from the other environment or another team is refused.
    func testValidateGroupRefusesTheOtherEnvironmentAndTeam() {
        XCTAssertNoThrow(try MailBuildIdentity.production.validateGroup("ABCDE12345.com.pdparchitect.noodle.mails", team: "ABCDE12345"))
        XCTAssertThrowsError(try MailBuildIdentity.development.validateGroup("ABCDE12345.com.pdparchitect.noodle.mails", team: "ABCDE12345"))
        XCTAssertThrowsError(try MailBuildIdentity.production.validateGroup("ZZZZZ99999.com.pdparchitect.noodle.mails", team: "ABCDE12345"))
    }

    /// Unsigned test runs act as production, as Browser's do.
    func testUnsignedTestsRunAsProduction() {
        XCTAssertEqual(MailBuildIdentity.current, .production)
    }
}
