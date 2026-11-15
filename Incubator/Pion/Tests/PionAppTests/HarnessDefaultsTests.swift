import NoodleCore
import PionCore
import XCTest

/// Pion is for security work: Codex, Claude and Apple Intelligence on this Mac are on for a new install and
/// offered by the welcome; the rest wait to be turned on in Settings, and a choice the person made is kept.
@MainActor final class HarnessDefaultsTests: XCTestCase {
    func testCodexClaudeAndAppleAreOnByDefaultAndTheWelcomeOffersThem() throws {
        let suite = "PionHarnessDefaults-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionHarnesses-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = PionModel(root: root, messenger: nil, isScripted: true, harnessDefaults: defaults)
        for provider in HarnessProvider.allCases {
            XCTAssertEqual(model.runtime.harnesses.isOn(provider), PionHarnesses.onByDefault.contains(provider), provider.rawValue)
        }
        XCTAssertEqual(PionHarnesses.onByDefault, [.codex, .claudeCode, .apple])
        XCTAssertEqual(PionHarnesses.featured, [.codex, .claudeCode, .apple])

        model.runtime.harnesses.set(.grokBuild, on: true)
        let reopened = PionModel(root: root, messenger: nil, isScripted: true, harnessDefaults: defaults)
        XCTAssertTrue(reopened.runtime.harnesses.isOn(.grokBuild), "The person's own choice is kept")
        XCTAssertFalse(reopened.runtime.harnesses.isOn(.muse))
    }
}

/// Apple Intelligence is one of Pion's own, so its on-device model is added for a new install, once: someone who
/// removes it in Settings keeps it removed.
@MainActor final class AppleModelDefaultTests: XCTestCase {
    func testTheOnDeviceModelIsAddedOnceAndStaysRemovedWhenRemoved() throws {
        let suite = "PionAppleModel-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionAppleModel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true, harnessDefaults: defaults)
        let store = AppleLocalModelStore(repository: root)
        XCTAssertFalse(store.systemModelAdded)
        model.offerAppleModel(defaults: defaults)
        XCTAssertTrue(store.systemModelAdded)
        try store.setSystemModelAdded(false)
        model.offerAppleModel(defaults: defaults)
        XCTAssertFalse(store.systemModelAdded, "Removed in Settings, it stays removed")
    }
}
