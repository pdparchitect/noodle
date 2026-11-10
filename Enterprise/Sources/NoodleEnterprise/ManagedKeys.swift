// Noodle Enterprise. Source-available under Enterprise/LICENSE, not Apache-2.0.
import Foundation
import NoodleCore

/// A value a configuration profile gives a managed key.
public enum ManagedValue: Equatable, Sendable {
    case boolean(Bool)
    case strings([String])
}

/// One choice for the entries of a list key, as the Jamf form offers it.
public struct ManagedChoice: Equatable, Sendable {
    public let value: String
    public let title: String
}

/// One key administrators can set in Noodle's preference domain. Its name is a public contract:
/// it is never renamed or reused, and a retired key stays here, deprecated, still read.
public struct ManagedKey: Equatable, Sendable {
    public enum ValueType: String, Sendable {
        case boolean
        case strings
    }

    /// How a profile's value applies. v1 has only enforced keys: a forced value the person can't
    /// change. A key that supplies a changeable default would be the other kind.
    public enum Enforcement: String, Sendable {
        case enforced
    }

    public let name: String
    public let type: ValueType
    public let title: String
    public let description: String
    /// What Noodle does without the key, from the same constants the app uses; nil for a list
    /// whose absence means no list at all.
    public let defaultValue: ManagedValue?
    /// The values a list's entries may take; nil for free text, such as host names.
    public let choices: [ManagedChoice]?
    public let enforcement: Enforcement
    /// The Noodle release that first read it.
    public let since: String
    /// Still read, documented as deprecated; kept for at least one release before it may go.
    public let deprecated: Bool

    init(_ name: String, _ type: ValueType, title: String, description: String, defaultValue: ManagedValue?,
         choices: [ManagedChoice]? = nil, since: String = "0.84.0", deprecated: Bool = false) {
        self.name = name
        self.type = type
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
        self.choices = choices
        enforcement = .enforced
        self.since = since
        self.deprecated = deprecated
    }
}

/// Every key Noodle reads from a configuration profile. Nothing else in Noodle reads managed
/// preferences, and the Jamf schema, sample profile and guide's table are generated from this list.
public enum ManagedKeys {
    /// Production builds' domain; development and local builds add a suffix to their bundle ID.
    public static let domain = "com.pdparchitect.noodle"

    public static let allowedHarnesses = "AllowedHarnesses"
    public static let allowUnrestrictedAccess = "AllowUnrestrictedAccess"
    public static let allowMCP = "AllowMCP"
    public static let mcpAllowList = "MCPAllowList"
    public static let mcpDenyList = "MCPDenyList"
    public static let allowCustomMCP = "AllowCustomMCP"
    public static let customMCPAllowList = "CustomMCPAllowList"
    public static let customMCPDenyList = "CustomMCPDenyList"
    public static let allowBrowser = "AllowBrowser"
    public static let allowComputers = "AllowComputers"
    public static let allowHubHosting = "AllowHubHosting"
    public static let allowHubConnections = "AllowHubConnections"
    public static let hubAllowList = "HubAllowList"
    public static let hubDenyList = "HubDenyList"
    public static let allowUpdates = "AllowUpdates"
    public static let automaticUpdateChecks = "AutomaticUpdateChecks"
    public static let automaticUpdateInstalls = "AutomaticUpdateInstalls"

    /// What Noodle does with nothing managed: everything allowed. Each `Allow…` key's default.
    static let allowed = UnmanagedPolicy()

    /// Sparkle's own defaults, as the app's Info.plist sets them.
    public static let automaticUpdateChecksDefault = true
    public static let automaticUpdateInstallsDefault = false

    static let harnessChoices = HarnessProvider.allCases.map { ManagedChoice(value: $0.rawValue, title: $0.displayName) }
    static let catalogueChoices = ToolCatalog.entries.map { ManagedChoice(value: $0.id, title: $0.name) }

    private static let hostPattern = "Each entry is a host name, such as mcp.example.com, a domain with its subdomains, such as *.example.com, or a URL prefix starting with https://."

    public static let all: [ManagedKey] = [
        ManagedKey(allowedHarnesses, .strings, title: "Allowed harnesses",
                   description: "The only harnesses people can use. Others are hidden in Settings and the fallback list, and bots set to one don't start. Missing: every harness.",
                   defaultValue: .strings(harnessChoices.map(\.value)), choices: harnessChoices),
        ManagedKey(allowUnrestrictedAccess, .boolean, title: "Allow unrestricted access",
                   description: "Whether people can turn off the macOS sandbox for a bot (Unrestricted access in Settings › Bots). When false, every bot runs sandboxed; bots that had unrestricted access restart sandboxed.",
                   defaultValue: .boolean(allowed.allows(.unrestrictedAccess))),
        ManagedKey(allowMCP, .boolean, title: "Allow tool connections (MCP)",
                   description: "Whether people can sign in to and bots can use MCP tool connections at all. When false, every connection stops working; none is deleted.",
                   defaultValue: .boolean(allowed.allows(.toolConnections))),
        ManagedKey(mcpAllowList, .strings, title: "Allowed catalogue connections",
                   description: "The only connections from Noodle's catalogue people can use, by catalogue ID. Missing: all of them. Does not apply to custom connections.",
                   defaultValue: nil, choices: catalogueChoices),
        ManagedKey(mcpDenyList, .strings, title: "Blocked catalogue connections",
                   description: "Connections from Noodle's catalogue people can't use, by catalogue ID. Wins over the allowed list.",
                   defaultValue: nil, choices: catalogueChoices),
        ManagedKey(allowCustomMCP, .boolean, title: "Allow custom tool connections",
                   description: "Whether people can use MCP servers they add by URL, not from the catalogue.",
                   defaultValue: .boolean(allowed.allows(.toolConnection(catalogueID: nil, endpoint: URL(string: "https://example.com")!)))),
        ManagedKey(customMCPAllowList, .strings, title: "Allowed custom MCP servers",
                   description: "The only custom MCP servers people can use. \(hostPattern) Missing: any server.",
                   defaultValue: nil),
        ManagedKey(customMCPDenyList, .strings, title: "Blocked custom MCP servers",
                   description: "Custom MCP servers people can't use. \(hostPattern) Wins over the allowed list.",
                   defaultValue: nil),
        ManagedKey(allowBrowser, .boolean, title: "Allow Noodle Browser",
                   description: "Whether people and their bots can use Noodle Browser's browsers from Noodle.",
                   defaultValue: .boolean(allowed.allows(.browsers))),
        ManagedKey(allowComputers, .boolean, title: "Allow Noodle Computer",
                   description: "Whether people and their bots can use Noodle Computer's computers from Noodle.",
                   defaultValue: .boolean(allowed.allows(.computers))),
        ManagedKey(allowHubHosting, .boolean, title: "Allow Let My Devices Reach This Mac",
                   description: "Whether people can turn on Let My Devices Reach This Mac in Settings › Hub, which serves their own devices from this Mac as a Hub does. When false, a Hub already on stops; the setting comes back when allowed again.",
                   defaultValue: .boolean(allowed.allows(.hubHosting))),
        ManagedKey(allowHubConnections, .boolean, title: "Allow joining Noodle Hubs",
                   description: "Whether people can join and use Noodle Hubs from this Mac. When false, joined Hubs are disconnected; none is left.",
                   defaultValue: .boolean(allowed.allows(.hubConnections))),
        ManagedKey(hubAllowList, .strings, title: "Allowed Hub addresses",
                   description: "The only Hub addresses Noodle connects to. Each entry is a host name or IP address, or a domain with its subdomains, such as *.example.com. Missing: any address.",
                   defaultValue: nil),
        ManagedKey(hubDenyList, .strings, title: "Blocked Hub addresses",
                   description: "Hub addresses Noodle never connects to, in the same form. Wins over the allowed list.",
                   defaultValue: nil),
        ManagedKey(allowUpdates, .boolean, title: "Allow Noodle updates",
                   description: "Whether Noodle checks for and installs its own updates. Set false to leave updates to your MDM.",
                   defaultValue: .boolean(allowed.allows(.updates))),
        ManagedKey(automaticUpdateChecks, .boolean, title: "Check for updates automatically",
                   description: "Fixes Settings › Update › Automatically check for updates on or off.",
                   defaultValue: .boolean(automaticUpdateChecksDefault)),
        ManagedKey(automaticUpdateInstalls, .boolean, title: "Download and install updates automatically",
                   description: "Fixes Settings › Update › Automatically download and install updates on or off.",
                   defaultValue: .boolean(automaticUpdateInstallsDefault)),
    ]

    public static func key(named name: String) -> ManagedKey? { all.first { $0.name == name } }
}
