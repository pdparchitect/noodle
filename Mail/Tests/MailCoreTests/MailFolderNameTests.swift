import XCTest
@testable import MailCore

final class MailFolderNameTests: XCTestCase {
    /// Seznam's Czech folder names decode from modified UTF-7.
    func testSeznamFolderNamesDecode() {
        XCTAssertEqual(MailFolderName.display("Odeslan&AOk-"), "Odeslané")
        XCTAssertEqual(MailFolderName.display("Rozepsan&AOk-"), "Rozepsané")
        XCTAssertEqual(MailFolderName.display("Ko&AWE-"), "Koš")
        XCTAssertEqual(MailFolderName.display("[Gmail]/Odeslan&AOk-"), "[Gmail]/Odeslané")
    }

    /// "&-" is a literal ampersand, and plain ASCII names stay as they are.
    func testAmpersandsAndPlainNames() {
        XCTAssertEqual(MailFolderName.display("Tom &- Jerry"), "Tom & Jerry")
        XCTAssertEqual(MailFolderName.display("INBOX"), "INBOX")
        XCTAssertEqual(MailFolderName.display(""), "")
    }

    /// Anything that isn't valid modified UTF-7 comes back raw instead of failing.
    func testMalformedNamesComeBackRaw() {
        for raw in ["Bad&AOk", "&!!!-", "&A-", "x&AOk=-"] { XCTAssertEqual(MailFolderName.display(raw), raw, raw) }
    }
}
