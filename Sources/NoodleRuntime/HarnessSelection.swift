import Foundation
import Observation
import NoodleCore

/// One login in the ordered fallback list. A bare harness names its Default login;
/// named profiles extend that same identifier with their UUID, so both remain valid choices.
public struct HarnessFallbackTarget: Hashable, Sendable {
    public let provider: HarnessProvider
    public let profile: UUID?

    public init(provider: HarnessProvider, profile: UUID? = nil) {
        self.provider = provider
        self.profile = provider.supportsProfiles && profile != HarnessProfileStore.defaultID(provider) ? profile : nil
    }

    var identifier: String { profile.map { "\(provider.rawValue)/\($0.uuidString)" } ?? provider.rawValue }

    init?(identifier: String) {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard let name = parts.first, let provider = HarnessProvider(rawValue: String(name)), parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard provider.supportsProfiles, let id = UUID(uuidString: String(parts[1])) else { return nil }
            self.init(provider: provider, profile: id)
        } else { self.init(provider: provider) }
    }
}

/// The harnesses this Mac offers. One turned off is left out of Settings and every
/// harness picker, is not probed, and its bots do not start.
@MainActor @Observable
public final class HarnessSelection {
    static let defaultsKey = "Noodle.harness.turnedOn"
    static let fallbackDefaultsKey = "Noodle.harness.fallback"
    static let fallbacksDefaultsKey = "Noodle.harness.fallbacks"
    static let usageRetryProfilesDefaultsKey = "Noodle.harness.usageRetryProfiles"

    @ObservationIgnored private let defaults: UserDefaults?
    /// The person's own choices; a harness without one keeps its default.
    private var choices: [String: Bool]
    /// Whether a bot whose harness runs out of usage continues on another one. Off until the person turns it on.
    public private(set) var fallbackIsOn: Bool
    /// Where such a bot continues, in order. Kept while fallback is off, so turning it on again restores it.
    public private(set) var fallbackTargets: [HarnessFallbackTarget]
    /// Logins explicitly allowed for automatic retries on their own harness, independently of the fallback list.
    public private(set) var usageRetryTargets: Set<HarnessFallbackTarget>
    public var fallbacks: [HarnessProvider] {
        var seen: Set<HarnessProvider> = []
        return fallbackTargets.map(\.provider).filter { seen.insert($0).inserted }
    }

    /// Everything on and nothing saved, for runtimes no person chooses for.
    public init() {
        defaults = nil
        choices = Dictionary(uniqueKeysWithValues: HarnessProvider.allCases.map { ($0.rawValue, true) })
        fallbackIsOn = false
        fallbackTargets = []
        usageRetryTargets = []
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        choices = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
        fallbackIsOn = defaults.bool(forKey: Self.fallbackDefaultsKey)
        fallbackTargets = Self.unique((defaults.stringArray(forKey: Self.fallbacksDefaultsKey) ?? []).compactMap(HarnessFallbackTarget.init(identifier:)))
        usageRetryTargets = Set((defaults.stringArray(forKey: Self.usageRetryProfilesDefaultsKey) ?? [])
            .compactMap(HarnessFallbackTarget.init(identifier:)).filter { $0.provider.supportsProfiles })
    }

    public func isOn(_ provider: HarnessProvider) -> Bool { choices[provider.rawValue] ?? provider.isOnByDefault }

    public func set(_ provider: HarnessProvider, on: Bool) {
        guard isOn(provider) != on else { return }
        choices[provider.rawValue] = on
        defaults?.set(choices, forKey: Self.defaultsKey)
    }

    public func setFallback(on: Bool) {
        guard fallbackIsOn != on else { return }
        fallbackIsOn = on
        defaults?.set(on, forKey: Self.fallbackDefaultsKey)
    }

    public func setFallbacks(_ providers: [HarnessProvider]) {
        setFallbackTargets(providers.map { HarnessFallbackTarget(provider: $0) })
    }

    public func setFallbackTargets(_ targets: [HarnessFallbackTarget]) {
        let targets = Self.unique(targets)
        guard fallbackTargets != targets else { return }
        fallbackTargets = targets
        defaults?.set(targets.map(\.identifier), forKey: Self.fallbacksDefaultsKey)
    }

    public func allowsUsageRetries(_ target: HarnessFallbackTarget) -> Bool { usageRetryTargets.contains(target) }

    public func setUsageRetries(_ target: HarnessFallbackTarget, on: Bool) {
        guard target.provider.supportsProfiles, allowsUsageRetries(target) != on else { return }
        if on { usageRetryTargets.insert(target) } else { usageRetryTargets.remove(target) }
        defaults?.set(usageRetryTargets.map(\.identifier).sorted(), forKey: Self.usageRetryProfilesDefaultsKey)
    }

    private static func unique(_ targets: [HarnessFallbackTarget]) -> [HarnessFallbackTarget] {
        var seen: Set<HarnessFallbackTarget> = []
        return targets.filter { seen.insert($0).inserted }
    }
}
