@testable import NoodleSettingsUI
import XCTest

final class RiskAcknowledgementTests: XCTestCase {
    private let terms = RiskAcknowledgement(id: "rook", version: 1, appName: "Rook", title: "Before you use Rook",
                                            message: "Rook attacks systems.", phrase: "I understand the risks")

    /// Accepted once, kept; new terms (a higher version) are asked again.
    func testAcceptanceIsKeptPerVersion() throws {
        let suite = "RiskAcknowledgementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(terms.isAccepted(in: defaults))
        terms.accept(in: defaults)
        XCTAssertTrue(terms.isAccepted(in: defaults))
        let newer = RiskAcknowledgement(id: "rook", version: 2, appName: "Rook", title: terms.title, message: terms.message, phrase: terms.phrase)
        XCTAssertFalse(newer.isAccepted(in: defaults))
        terms.reset(in: defaults)
        XCTAssertFalse(terms.isAccepted(in: defaults))
    }

    /// The phrase must be typed whole; case and surrounding spaces do not matter.
    func testOnlyThePhraseItselfContinues() {
        XCTAssertTrue(terms.matches("I understand the risks"))
        XCTAssertTrue(terms.matches("  i understand the RISKS "))
        XCTAssertFalse(terms.matches("I understand"))
        XCTAssertFalse(terms.matches("I understand the risks!"))
        XCTAssertFalse(terms.matches(""))
    }
}
