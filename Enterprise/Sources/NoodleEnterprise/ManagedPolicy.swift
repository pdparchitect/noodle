// Noodle Enterprise. Source-available under Enterprise/LICENSE, not Apache-2.0.
import Foundation
import NoodleCore
import OSLog

/// Where managed values come from: the app's own preference domain, as macOS fills it from
/// installed configuration profiles.
public protocol ManagedPreferenceSource: Sendable {
    /// The value an administrator forced for `key`; nil when it is missing or only the person's own.
    func forcedValue(forKey key: String) -> Any?
}

/// The app's preference domain. Only forced values count: a value the person wrote themselves,
/// with `defaults write` for example, is theirs, not their organisation's.
public struct DefaultsPreferenceSource: ManagedPreferenceSource, @unchecked Sendable {
    let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func forcedValue(forKey key: String) -> Any? {
        defaults.objectIsForced(forKey: key) ? defaults.object(forKey: key) : nil
    }
}

/// The policies a configuration profile sets, read once. A missing key allows; a value of the
/// wrong type is ignored and logged, so a mistake never crashes and never widens what is allowed;
/// a list keeps its valid entries. Deny lists win over allow lists, and an allow list, even an
/// empty one, means only what it lists.
public struct ManagedPolicy: OrganisationPolicy, Equatable {
    public let values: [String: ManagedValue]
    /// What was ignored and why, for the log.
    public let problems: [String]

    public init(values: [String: ManagedValue] = [:]) {
        self.values = values
        problems = []
    }

    public init(reading source: any ManagedPreferenceSource) {
        var values: [String: ManagedValue] = [:], problems: [String] = []
        for key in ManagedKeys.all {
            guard let raw = source.forcedValue(forKey: key.name) else { continue }
            switch key.type {
            case .boolean:
                if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    values[key.name] = .boolean(number.boolValue)
                } else {
                    problems.append("\(key.name) is not a boolean and is ignored.")
                }
            case .strings:
                guard let array = raw as? [Any] else {
                    problems.append("\(key.name) is not an array of strings and is ignored.")
                    continue
                }
                var entries: [String] = []
                for item in array {
                    guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                        problems.append("\(key.name) has an entry that is not a string; it is left out.")
                        continue
                    }
                    if let choices = key.choices, !choices.contains(where: { $0.value == text }) {
                        problems.append("\(key.name) has an unknown entry \(text); it is left out.")
                        continue
                    }
                    entries.append(key.choices == nil ? text.lowercased() : text)
                }
                values[key.name] = .strings(entries)
            }
        }
        self.values = values
        self.problems = problems
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.values == rhs.values }

    func bool(_ key: String) -> Bool? {
        if case .boolean(let value)? = values[key] { return value }
        return nil
    }

    func strings(_ key: String) -> [String]? {
        if case .strings(let value)? = values[key] { return value }
        return nil
    }

    public func allows(_ action: OrganisationAction) -> Bool {
        switch action {
        case .harness(let provider):
            return strings(ManagedKeys.allowedHarnesses)?.contains(provider.rawValue) ?? true
        case .unrestrictedAccess: return bool(ManagedKeys.allowUnrestrictedAccess) ?? true
        case .toolConnections: return bool(ManagedKeys.allowMCP) ?? true
        case .toolConnection(let catalogueID, let endpoint):
            guard bool(ManagedKeys.allowMCP) != false else { return false }
            if let catalogueID {
                return admits(catalogueID, deny: ManagedKeys.mcpDenyList, allow: ManagedKeys.mcpAllowList) { $0 == catalogueID }
            }
            guard bool(ManagedKeys.allowCustomMCP) != false, let host = endpoint.host else { return false }
            return admits(host, deny: ManagedKeys.customMCPDenyList, allow: ManagedKeys.customMCPAllowList) {
                ManagedPattern.matches($0, host: host, url: endpoint)
            }
        case .browsers: return bool(ManagedKeys.allowBrowser) ?? true
        case .computers: return bool(ManagedKeys.allowComputers) ?? true
        case .hubHosting: return bool(ManagedKeys.allowHubHosting) ?? true
        case .hubConnections: return bool(ManagedKeys.allowHubConnections) ?? true
        case .hubAddress(let host):
            guard bool(ManagedKeys.allowHubConnections) != false else { return false }
            return admits(host, deny: ManagedKeys.hubDenyList, allow: ManagedKeys.hubAllowList) {
                ManagedPattern.matches($0, host: host, url: nil)
            }
        case .updates: return bool(ManagedKeys.allowUpdates) ?? true
        }
    }

    /// Deny first, then the allow list if there is one.
    private func admits(_ subject: String, deny: String, allow: String, matches: (String) -> Bool) -> Bool {
        if strings(deny)?.contains(where: matches) == true { return false }
        guard let allowed = strings(allow) else { return true }
        return allowed.contains(where: matches)
    }

    public func value(of setting: OrganisationSetting) -> Bool? {
        switch setting {
        case .automaticUpdateChecks: return bool(ManagedKeys.automaticUpdateChecks)
        case .automaticUpdateInstalls: return bool(ManagedKeys.automaticUpdateInstalls)
        }
    }

    public var rules: [OrganisationRule] {
        ManagedKeys.all.compactMap { key in
            switch values[key.name] {
            case .boolean(let value)?:
                let fixed = key.name == ManagedKeys.automaticUpdateChecks || key.name == ManagedKeys.automaticUpdateInstalls
                return OrganisationRule(title: key.title, value: fixed ? (value ? "On" : "Off") : (value ? "Allowed" : "Not allowed"))
            case .strings(let entries)?:
                let names = entries.map { entry in key.choices?.first { $0.value == entry }?.title ?? entry }
                return OrganisationRule(title: key.title, value: names.isEmpty ? "None" : names.joined(separator: ", "))
            case nil:
                return nil
            }
        }
    }
}

/// An entry of a host list: a host name or IP address, `*.domain` for a domain and its
/// subdomains, or an `https://` URL prefix that matches whole path segments only.
enum ManagedPattern {
    static func matches(_ pattern: String, host: String, url: URL?) -> Bool {
        let pattern = pattern.lowercased()
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if pattern.contains("://") {
            guard let url, let prefix = URL(string: pattern), let prefixHost = prefix.host?.lowercased(),
                  url.scheme?.lowercased() == prefix.scheme, url.host?.lowercased() == prefixHost,
                  url.port == prefix.port else { return false }
            let base = prefix.path.hasSuffix("/") ? String(prefix.path.dropLast()) : prefix.path
            return base.isEmpty || url.path == base || url.path.hasPrefix(base + "/")
        }
        if pattern.hasPrefix("*.") {
            let domain = pattern.dropFirst(2)
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
        return host == pattern
    }
}

/// Follows the preference domain while the app runs: installing, changing or removing a profile
/// puts the new policy in force without a restart.
@MainActor public final class ManagedPreferences: NSObject {
    public static let shared = ManagedPreferences()

    public private(set) var policy = ManagedPolicy()
    private let defaults: UserDefaults
    private let source: any ManagedPreferenceSource
    private var observing = false
    private var timer: Timer?
    private static let logger = Logger(subsystem: "com.pdparchitect.noodle", category: "ManagedPreferences")

    /// `source` reads what counts as forced; the domain's own by default.
    public init(defaults: UserDefaults = .standard, source: (any ManagedPreferenceSource)? = nil) {
        self.defaults = defaults
        self.source = source ?? DefaultsPreferenceSource(defaults)
    }

    /// Puts the profile's policy in force now, then follows changes. macOS doesn't promise to
    /// tell a running app that a profile changed its managed values, so they are also read again
    /// every `interval` seconds; nil reads only on notice.
    public func start(rereadingEvery interval: TimeInterval? = 60) {
        refresh()
        guard !observing else { return }
        observing = true
        for key in ManagedKeys.all { defaults.addObserver(self, forKeyPath: key.name, options: [], context: nil) }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: defaults)
        if let interval {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    public func stop() {
        guard observing else { return }
        observing = false
        for key in ManagedKeys.all { defaults.removeObserver(self, forKeyPath: key.name) }
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: defaults)
        timer?.invalidate()
        timer = nil
    }

    /// Reads the domain again and puts a changed policy in force.
    public func refresh() {
        let next = ManagedPolicy(reading: source)
        guard next != policy || next.problems != policy.problems else { return }
        for problem in next.problems where !policy.problems.contains(problem) {
            Self.logger.error("Managed preference ignored: \(problem, privacy: .public)")
        }
        let changed = next != policy
        policy = next
        if changed {
            Self.logger.notice("Managed preferences changed: \(next.values.keys.sorted().joined(separator: ", "), privacy: .public)")
            Organisation.enforce(next)
        }
    }

    @objc private nonisolated func defaultsChanged() {
        if Thread.isMainThread { MainActor.assumeIsolated { refresh() } }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } } }
    }

    public override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                                  change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
    }
}
