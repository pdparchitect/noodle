import Foundation

public struct AgentAccessConfiguration: Equatable, Sendable {
    public private(set) var restrictedAgentIDs: Set<UUID>
    public init(restrictedAgentIDs: Set<UUID> = []) { self.restrictedAgentIDs = restrictedAgentIDs }
    public func isExtended(_ id: UUID) -> Bool { !restrictedAgentIDs.contains(id) }
    public mutating func setExtended(_ enabled: Bool, for id: UUID) {
        if enabled { restrictedAgentIDs.remove(id) } else { restrictedAgentIDs.insert(id) }
    }
    public mutating func remove(_ id: UUID) { restrictedAgentIDs.remove(id) }
    public static func load(from defaults: UserDefaults) -> Self {
        .init(restrictedAgentIDs: Set((defaults.stringArray(forKey: "Noodle.access.restrictedAgents") ?? []).compactMap(UUID.init(uuidString:))))
    }
    public func save(to defaults: UserDefaults) {
        defaults.set(restrictedAgentIDs.map(\.uuidString).sorted(), forKey: "Noodle.access.restrictedAgents")
        defaults.removeObject(forKey: "Noodle.access.extendedAgents")
    }
}

/// JSON-RPC IDs may be strings or numbers. Never coerce one into the other or
/// confuse server requests with responses to our own numbered requests.
public struct RuntimeRequestID: Hashable, Sendable {
    public let value: String
    public let isNumber: Bool
    public init?(_ raw: Any?) {
        if let string = raw as? String { value = string; isNumber = false }
        else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.stringValue; isNumber = true
        } else { return nil }
    }
    public var json: Any { isNumber ? (Int(value) as Any? ?? value) : value }
}

public struct AgentApprovalRequest: Identifiable {
    public let id = UUID()
    public let agentID: UUID
    public let requestID: RuntimeRequestID
    public let method: String
    public let params: [String: Any]
    public let turnID: String?

    public init?(agentID: UUID, message: [String: Any]) {
        guard let requestID = RuntimeRequestID(message["id"]),
              let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return nil }
        self.agentID = agentID; self.requestID = requestID; self.method = method; self.params = params
        turnID = params["turnId"] as? String
    }

    public var title: String {
        switch method {
        case "item/commandExecution/requestApproval": return "Allow command?"
        case "item/fileChange/requestApproval": return "Allow file changes?"
        case "item/permissions/requestApproval": return "Allow additional access?"
        case "item/tool/requestUserInput": return "Your response is needed"
        case "mcpServer/elicitation/request": return "Tool confirmation required"
        default: return "Unsupported runtime request"
        }
    }

    public var questions: [[String: Any]] { params["questions"] as? [[String: Any]] ?? [] }
    public var isQuestion: Bool { method == "item/tool/requestUserInput" }
    public var isToolConfirmation: Bool {
        guard method == "mcpServer/elicitation/request",
              params["mode"] as? String == "form",
              let message = params["message"] as? String, !message.isEmpty,
              let schema = params["requestedSchema"] as? [String: Any],
              schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String: Any], properties.isEmpty else { return false }
        // Only a plain yes/no form can be represented without user-entered data.
        // Reject constraints/extensions we do not render or understand.
        guard Set(schema.keys).isSubset(of: ["type", "properties", "required", "$schema"]) else { return false }
        if let required = schema["required"], !(required is NSNull) {
            guard let fields = required as? [String], fields.isEmpty else { return false }
        }
        return true
    }
    public var detail: String {
        // Keep complete security-relevant details visible, including exact paths,
        // destinations and stdin. Do not trust a model's reason as the full scope.
        let keys = ["reason", "command", "kind", "stdin", "cwd", "grantRoot", "changes", "additionalPermissions", "permissions", "networkApprovalContext", "commandActions", "message", "serverName", "mode", "url", "requestedSchema"]
        return keys.compactMap { key in
            guard let value = params[key], !(value is NSNull) else { return nil }
            if let string = value as? String { return "\(key): \(string)" }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
            return "\(key): \(String(decoding: data, as: UTF8.self))"
        }.joined(separator: "\n\n")
    }

    public var canAllow: Bool {
        switch method {
        case "item/commandExecution/requestApproval":
            guard let choices = params["availableDecisions"] as? [Any] else { return true }
            return choices.contains { ($0 as? String) == "accept" }
        case "item/fileChange/requestApproval", "item/permissions/requestApproval": return true
        case "mcpServer/elicitation/request": return isToolConfirmation
        // URL/form elicitation may involve login, secrets, or a complex schema.
        // Do not manufacture consent/content for requests we cannot faithfully render.
        default: return false
        }
    }

    /// Routine runtime requests are resolved without interrupting an autonomous
    /// bot. Only a real question is returned to the app for user input.
    public func automaticResponse(extendedAccess: Bool) -> [String: Any]? {
        if isQuestion { return nil }
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval":
            return response(allow: extendedAccess)
        case "mcpServer/elicitation/request":
            return response(allow: isToolConfirmation)
        default:
            return response(allow: false)
        }
    }

    public func response(allow: Bool, answers: [String: String] = [:]) -> [String: Any] {
        var result: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": allow && canAllow ? "accept" : "decline"]
        case "item/permissions/requestApproval":
            result = ["permissions": allow ? params["permissions"] as? [String: Any] ?? [:] : [:], "scope": "turn"]
        case "item/tool/requestUserInput":
            let validIDs = Set(questions.compactMap { $0["id"] as? String })
            result = ["answers": allow ? answers.filter { validIDs.contains($0.key) }.mapValues { ["answers": [$0]] } : [:]]
        case "mcpServer/elicitation/request":
            result = allow && isToolConfirmation
                ? ["action": "accept", "content": [String: Any]()]
                : ["action": "decline", "content": NSNull()]
        default:
            return ["id": requestID.json, "error": ["code": -32601, "message": "Noodle does not support this request; no permission was granted."]]
        }
        return ["id": requestID.json, "result": result]
    }
}

import CoreFoundation
