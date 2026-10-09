import Foundation
import Observation
import NoodleCore

/// The harnesses this Mac offers. One turned off is left out of Settings and every
/// harness picker, is not probed, and its bots do not start.
@MainActor @Observable
public final class HarnessSelection {
    static let defaultsKey = "Noodle.harness.turnedOn"

    @ObservationIgnored private let defaults: UserDefaults?
    /// The person's own choices; a harness without one keeps its default.
    private var choices: [String: Bool]

    /// Everything on and nothing saved, for runtimes no person chooses for.
    public init() {
        defaults = nil
        choices = Dictionary(uniqueKeysWithValues: HarnessProvider.allCases.map { ($0.rawValue, true) })
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        Self.keepEarlierHarnessesOn(in: defaults)
        choices = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
    }

    public func isOn(_ provider: HarnessProvider) -> Bool { choices[provider.rawValue] ?? provider.isOnByDefault }

    public func set(_ provider: HarnessProvider, on: Bool) {
        guard isOn(provider) != on else { return }
        choices[provider.rawValue] = on
        defaults?.set(choices, forKey: Self.defaultsKey)
    }

    // TODO(0.54.0): remove with its call in init(defaults:) and
    // HarnessSelectionTests.testAnEarlierInstallKeepsEveryHarnessOn. Milestone: 0.53.0.
    // TODO(Hub 0.26.0): same removal for the Hub. Milestone: Hub 0.25.0.
    /// Every harness was on before they could be turned off, so a Mac that already
    /// set one up or ran a bot keeps them all; only a new install gets the defaults.
    private static func keepEarlierHarnessesOn(in defaults: UserDefaults) {
        guard defaults.object(forKey: defaultsKey) == nil else { return }
        let earlier = [HarnessPresentationCache.defaultsKey, "Noodle.session.startDates"]
        // Saved even when empty, so the next launch does not take this install for an earlier one.
        defaults.set(earlier.contains(where: { defaults.object(forKey: $0) != nil })
            ? Dictionary(uniqueKeysWithValues: HarnessProvider.allCases.map { ($0.rawValue, true) }) : [String: Bool](),
            forKey: defaultsKey)
    }
}
