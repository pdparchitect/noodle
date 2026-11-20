import NoodleCore
@testable import RookCore
import XCTest

final class RookShortcutsTests: XCTestCase {
    /// Rook's shortcuts keep the keys its menus always had, none twice, none macOS's own, and include the
    /// ones the capture and annotation code shared with Noodle looks up by name.
    func testRooksShortcutsAreValidUniqueAndCoverTheSharedOnes() throws {
        let preferences = KeyboardShortcutPreferences(catalog: RookShortcuts.catalog)
        var seen = Set<KeyBinding>()
        for action in RookShortcuts.catalog {
            let binding = try XCTUnwrap(preferences.binding(for: action), action.title)
            XCTAssertTrue(binding.isValid, action.title)
            XCTAssertNil(binding.reservedAction, action.title)
            XCTAssertTrue(seen.insert(binding).inserted, action.title)
        }
        XCTAssertEqual(Set(RookShortcuts.catalog.map(\.id)).count, RookShortcuts.catalog.count)
        for shared in [ShortcutDefinition.capture, .annotateSelection, .annotateRegion, .saveAnnotation, .call] {
            XCTAssertNotNil(preferences.binding(for: shared), shared.id)
        }
        XCTAssertEqual(preferences.binding(for: RookShortcuts.newMission)?.displayName, "⌘N")
        XCTAssertEqual(preferences.binding(for: RookShortcuts.newAgent)?.displayName, "⇧⌘N")
        XCTAssertEqual(preferences.binding(for: .newGroup)?.displayName, "⌥⌘N")
        XCTAssertEqual(preferences.binding(for: .recordVoice)?.displayName, "⇧⌘D")
        XCTAssertNil(preferences.binding(for: .newBot), "Rook's agents come from New Agent")
        XCTAssertNil(preferences.binding(for: .chooseConversation), "Rook has no conversation picker and no keys outside itself")
        XCTAssertEqual(preferences.binding(for: .showUsage)?.displayName, "⇧⌘U")
    }
}
