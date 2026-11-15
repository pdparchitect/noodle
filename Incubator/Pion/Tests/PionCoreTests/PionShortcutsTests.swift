import NoodleCore
@testable import PionCore
import XCTest

final class PionShortcutsTests: XCTestCase {
    /// Pion's shortcuts keep the keys its menus always had, none twice, none macOS's own, and include the
    /// ones the capture and annotation code shared with Noodle looks up by name.
    func testPionsShortcutsAreValidUniqueAndCoverTheSharedOnes() throws {
        let preferences = KeyboardShortcutPreferences(catalog: PionShortcuts.catalog)
        var seen = Set<KeyBinding>()
        for action in PionShortcuts.catalog {
            let binding = try XCTUnwrap(preferences.binding(for: action), action.title)
            XCTAssertTrue(binding.isValid, action.title)
            XCTAssertNil(binding.reservedAction, action.title)
            XCTAssertTrue(seen.insert(binding).inserted, action.title)
        }
        XCTAssertEqual(Set(PionShortcuts.catalog.map(\.id)).count, PionShortcuts.catalog.count)
        for shared in [ShortcutDefinition.capture, .annotateSelection, .annotateRegion, .saveAnnotation, .call] {
            XCTAssertNotNil(preferences.binding(for: shared), shared.id)
        }
        XCTAssertEqual(preferences.binding(for: PionShortcuts.newInvestigation)?.displayName, "⌘N")
        XCTAssertEqual(preferences.binding(for: PionShortcuts.newAgent)?.displayName, "⇧⌘N")
        XCTAssertEqual(preferences.binding(for: .newGroup)?.displayName, "⌥⌘N")
        XCTAssertEqual(preferences.binding(for: .recordVoice)?.displayName, "⇧⌘D")
        XCTAssertNil(preferences.binding(for: .newBot), "Pion's agents come from New Agent")
        XCTAssertEqual(preferences.binding(for: .showUsage)?.displayName, "⇧⌘U")
    }
}
