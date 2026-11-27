import Foundation

public struct AgentAccessConfiguration: Equatable, Sendable {
    public private(set) var autonomousAgentIDs: Set<UUID>
    public private(set) var requiredHarnessGrants: [String: [String]] = [:]
    public private(set) var accountAppGrants: [String: [String]] = [:]
    private static let storageKey = "Noodle.access.autonomousAgents"
    private static let harnessGrantsKey = "Noodle.access.requiredHarnessGrants"
    private static let accountAppsKey = "Noodle.access.accountApps"
    /// Unrestricted access stays off until someone turns it on outside the app, with
    /// `defaults write <the app's domain> AllowUnrestrictedAccess -bool true` or a configuration
    /// profile, whose value wins. No switch in the app turns it on, so nobody does by accident.
    public static let unrestrictedAccessKey = "AllowUnrestrictedAccess"
    /// Whether unrestricted access was turned on outside the app, as last read from `unrestrictedAccessKey`.
    public var unrestrictedAccessTurnedOn: Bool

    public init(autonomousAgentIDs: Set<UUID> = [], unrestrictedAccessTurnedOn: Bool = false) {
        self.autonomousAgentIDs = autonomousAgentIDs
        self.unrestrictedAccessTurnedOn = unrestrictedAccessTurnedOn
    }

    /// Whether bots may be given unrestricted access now: turned on, and not forbidden by the organisation.
    public var allowsUnrestrictedAccess: Bool { unrestrictedAccessTurnedOn && Organisation.allows(.unrestrictedAccess) }
    public func isExtended(_ id: UUID) -> Bool { autonomousAgentIDs.contains(id) }

    /// A provider's requirements never grant access. The app records the user's
    /// harness selection separately from mutable/imported agent configuration.
    /// While unrestricted access is not allowed every bot stays sandboxed, without forgetting the person's grants.
    public func isExtended(for agent: AgentRecord) -> Bool {
        isGranted(for: agent) && allowsUnrestrictedAccess
    }

    /// What the person granted, whatever the organisation allows.
    public func isGranted(for agent: AgentRecord) -> Bool {
        if let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? ""),
           !provider.supportsRestrictedAccess {
            return requiredHarnessGrants[agent.id.uuidString]?.contains(provider.rawValue) == true
        }
        return isExtended(agent.id)
    }
    public mutating func setExtended(_ enabled: Bool, for id: UUID) {
        if enabled { autonomousAgentIDs.insert(id) } else { autonomousAgentIDs.remove(id) }
    }
    public func appsEnabled(for agent: AgentRecord) -> Bool {
        guard let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? ""), provider.supportsAccountApps else { return false }
        return accountAppGrants[agent.id.uuidString]?.contains(provider.rawValue) == true
    }
    public mutating func setAppsEnabled(_ enabled: Bool, for agent: AgentRecord) {
        guard let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? ""), provider.supportsAccountApps else { return }
        var grants = Set(accountAppGrants[agent.id.uuidString] ?? [])
        if enabled { grants.insert(provider.rawValue) } else { grants.remove(provider.rawValue) }
        accountAppGrants[agent.id.uuidString] = grants.isEmpty ? nil : grants.sorted()
    }
    public mutating func authorizeSelectedHarness(for agent: AgentRecord) {
        guard let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? ""), !provider.supportsRestrictedAccess else { return }
        var grants = Set(requiredHarnessGrants[agent.id.uuidString] ?? [])
        grants.insert(provider.rawValue)
        requiredHarnessGrants[agent.id.uuidString] = grants.sorted()
    }
    public mutating func remove(_ id: UUID) {
        autonomousAgentIDs.remove(id)
        requiredHarnessGrants.removeValue(forKey: id.uuidString)
        accountAppGrants.removeValue(forKey: id.uuidString)
    }
    /// The switch is only ever read here: saving never writes it.
    public static func load(from defaults: UserDefaults) -> Self {
        var result = Self(autonomousAgentIDs: Set((defaults.stringArray(forKey: storageKey) ?? []).compactMap(UUID.init(uuidString:))),
                          unrestrictedAccessTurnedOn: defaults.bool(forKey: unrestrictedAccessKey))
        result.requiredHarnessGrants = defaults.dictionary(forKey: harnessGrantsKey) as? [String: [String]] ?? [:]
        result.accountAppGrants = defaults.dictionary(forKey: accountAppsKey) as? [String: [String]] ?? [:]
        return result
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(autonomousAgentIDs.map(\.uuidString).sorted(), forKey: Self.storageKey)
        defaults.set(requiredHarnessGrants, forKey: Self.harnessGrantsKey)
        defaults.set(accountAppGrants, forKey: Self.accountAppsKey)
    }
}

/// JSON-RPC IDs may be strings or numbers. Never coerce one into the other or
/// confuse server requests with responses to our own numbered requests.
public struct RuntimeRequestID: Hashable, Sendable {
    public let value: String
    public let isNumber: Bool
    public init?(_ raw: Any?) {
        if let string = raw as? String { value = string; isNumber = false }
        else if let number = raw as? NSNumber, !number.isJSONBoolean {
            value = number.stringValue; isNumber = true
        } else { return nil }
    }
    public var json: Any { isNumber ? (Int(value) as Any? ?? value) : value }
}

package extension NSNumber {
    /// Whether JSONSerialization made this from `true` or `false`, which also bridge to numbers.
    var isJSONBoolean: Bool {
        #if canImport(Darwin)
        CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        // Elsewhere JSON booleans are numbers of type `c`; ints are `i` and `q`.
        String(cString: objCType) == "c"
        #endif
    }
}

/// Noninteractive Codex server-request replies. Saved bot access governs runtime
/// permissions; requests are answered immediately without a pending UI queue.
public struct CodexRuntimeRequest {
    public let requestID: RuntimeRequestID
    public let method: String
    public let params: [String: Any]
    public var turnID: String? { params["turnId"] as? String }

    public init?(message: [String: Any]) {
        guard let requestID = RuntimeRequestID(message["id"]),
              let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return nil }
        self.requestID = requestID
        self.method = method
        self.params = params
    }

    private var canAcceptCommand: Bool {
        guard let choices = params["availableDecisions"] as? [Any] else { return true }
        return choices.contains { ($0 as? String) == "accept" }
    }

    private var isToolConfirmation: Bool {
        guard params["mode"] as? String == "form",
              let message = params["message"] as? String, !message.isEmpty,
              let schema = params["requestedSchema"] as? [String: Any],
              schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String: Any], properties.isEmpty else { return false }
        // A plain confirmation needs no user-entered data. Unknown constraints,
        // login URLs and fields cannot be satisfied with manufactured content.
        guard Set(schema.keys).isSubset(of: ["type", "properties", "required", "$schema"]) else { return false }
        if let required = schema["required"], !(required is NSNull) {
            guard let fields = required as? [String], fields.isEmpty else { return false }
        }
        return true
    }

    public func response(extendedAccess: Bool, isCurrent: Bool = true) -> [String: Any] {
        let allow = extendedAccess && isCurrent
        let result: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval":
            result = ["decision": allow && canAcceptCommand ? "accept" : "decline"]
        case "item/fileChange/requestApproval":
            result = ["decision": allow ? "accept" : "decline"]
        case "item/permissions/requestApproval":
            result = ["permissions": allow ? params["permissions"] as? [String: Any] ?? [:] : [:], "scope": "turn"]
        case "item/tool/requestUserInput":
            // Finish the request immediately without inventing a user's answer.
            result = ["answers": [String: Any]()]
        case "mcpServer/elicitation/request":
            result = isCurrent && isToolConfirmation
                ? ["action": "accept", "content": [String: Any]()]
                : ["action": "decline", "content": NSNull()]
        default:
            return ["id": requestID.json, "error": ["code": -32601, "message": "\(ProductIdentity.current.name) does not support this request; no permission was granted."]]
        }
        return ["id": requestID.json, "result": result]
    }
}

import ProductIdentity
