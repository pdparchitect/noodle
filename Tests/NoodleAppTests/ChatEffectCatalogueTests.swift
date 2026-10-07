import NoodleBrand
import NoodleCore
import XCTest

final class ChatEffectCatalogueTests: XCTestCase {
    /// Every effect a bot can send is one the apps draw, and nothing is drawn that bots cannot send.
    func testBotsSendOnlyEffectsTheAppsDraw() {
        XCTAssertEqual(ConversationEffectKind.allCases.map(\.rawValue), ChatEffect.allCases.map(\.rawValue))
    }
}
