import Foundation
import NoodleSettingsUI
import Testing

/// An app that just updated, such as to a migration milestone, looks again at once instead of a day later.
struct UpdateFollowUpTests {
    private func defaults() -> UserDefaults {
        let suite = "NoodleSettingsUITests.UpdateFollowUp.\(UUID())"
        return UserDefaults(suiteName: suite)!
    }

    @Test func aLaunchRightAfterAnUpdateLooksAgain() {
        let defaults = defaults()
        #expect(!UpdateFollowUp.justUpdated(to: "0.53.0", defaults: defaults), "The first launch is no update.")
        #expect(!UpdateFollowUp.justUpdated(to: "0.53.0", defaults: defaults), "Nor is relaunching the same version.")
        #expect(UpdateFollowUp.justUpdated(to: "0.61.0", defaults: defaults))
        #expect(!UpdateFollowUp.justUpdated(to: "0.61.0", defaults: defaults), "Only the first launch of a version.")
    }

    @Test func aBuildWithoutAVersionNeverLooks() {
        let defaults = defaults()
        #expect(!UpdateFollowUp.justUpdated(to: nil, defaults: defaults))
        #expect(!UpdateFollowUp.justUpdated(to: "0.61.0", defaults: defaults))
    }
}
