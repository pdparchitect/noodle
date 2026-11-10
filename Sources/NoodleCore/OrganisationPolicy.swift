import Foundation
import Observation

/// Something a person or a bot does with Noodle that an organisation can forbid on its Macs.
/// Noodle asks where each one happens, so neither a person nor a bot can go around the answer.
public enum OrganisationAction: Hashable, Sendable {
    /// Running bots on a harness, offering it in Settings and pickers, and falling back to it.
    case harness(HarnessProvider)
    /// A bot running outside its macOS sandbox.
    case unrestrictedAccess
    /// Tool connections at all.
    case toolConnections
    /// Signing in to and using a tool connection; `catalogueID` is nil for one the person added by URL.
    case toolConnection(catalogueID: String?, endpoint: URL)
    /// Noodle Browser's browsers, for the person and their bots.
    case browsers
    /// Noodle Computer's computers, for the person and their bots.
    case computers
    /// This Mac serving its owner's devices as a Hub.
    case hubHosting
    /// Joining and using Noodle Hubs at all.
    case hubConnections
    /// Reaching a Hub at this address, a host name or IP address.
    case hubAddress(String)
    /// Noodle checking for and installing its own updates.
    case updates
}

/// A setting the organisation can fix to a value, which the person then cannot change.
public enum OrganisationSetting: Hashable, Sendable {
    case automaticUpdateChecks
    case automaticUpdateInstalls
}

/// One policy in force, as Settings lists it.
public struct OrganisationRule: Hashable, Sendable {
    public var title: String
    public var value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }
}

/// What an organisation allows on this Mac. Noodle itself has no opinion: without a policy
/// everything is allowed, and a policy only ever narrows that.
public protocol OrganisationPolicy: Sendable {
    func allows(_ action: OrganisationAction) -> Bool
    /// The value the organisation fixed for a setting; nil leaves it to the person.
    func value(of setting: OrganisationSetting) -> Bool?
    /// The policies in force, empty when the organisation set none.
    var rules: [OrganisationRule] { get }
}

/// No organisation: everything allowed, nothing fixed.
public struct UnmanagedPolicy: OrganisationPolicy {
    public init() {}
    public func allows(_ action: OrganisationAction) -> Bool { true }
    public func value(of setting: OrganisationSetting) -> Bool? { nil }
    public var rules: [OrganisationRule] { [] }
}

/// The policy in force for this app. Whoever reads the organisation's settings puts each new
/// policy in force here as it changes; everyone else only asks.
public enum Organisation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: any OrganisationPolicy = UnmanagedPolicy()

    /// Posted on the main thread after a new policy came into force.
    public static let didChangeNotification = Notification.Name("NoodleOrganisationPolicyDidChange")
    /// Beside a control the organisation set, or in place of a section it turned off.
    public static let managedText = "Managed by your organisation"
    /// Where people read what the enterprise feature is and how it is licensed.
    public static let enterpriseURL = URL(string: "https://github.com/pdparchitect/noodle/blob/main/ENTERPRISE.md")!

    /// Readable from any thread.
    public static var policy: any OrganisationPolicy { lock.withLock { current } }

    public static func allows(_ action: OrganisationAction) -> Bool { policy.allows(action) }

    /// Puts `policy` in force at once, then tells everyone who follows it.
    @MainActor public static func enforce(_ policy: any OrganisationPolicy) {
        lock.withLock { current = policy }
        OrganisationStatus.shared.policy = policy
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// What using this tool connection asks the organisation.
    public static func action(for connection: MCPConnectionRecord) -> OrganisationAction {
        .toolConnection(catalogueID: ToolCatalog.definition(forMCPEndpoint: connection.endpoint)?.id, endpoint: connection.endpoint)
    }
}

/// The policy in force, for views, which redraw when it changes.
@MainActor @Observable public final class OrganisationStatus {
    public static let shared = OrganisationStatus()
    public fileprivate(set) var policy: any OrganisationPolicy = UnmanagedPolicy()

    public func allows(_ action: OrganisationAction) -> Bool { policy.allows(action) }
    public func value(of setting: OrganisationSetting) -> Bool? { policy.value(of: setting) }
    public var isManaged: Bool { !policy.rules.isEmpty }
}
