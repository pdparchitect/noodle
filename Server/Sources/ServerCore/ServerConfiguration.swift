import Foundation
import HubWire
import NoodleCore
import Yams

/// What `noodled.yaml` says: where the server keeps its data, which harnesses it runs, and the plans and
/// users it serves. Reading it checks every setting it knows and refuses any it does not, naming where.
public struct ServerConfiguration: Equatable, Sendable {
    public struct Plan: Equatable, Sendable {
        public var name: String
        public var harnesses: [HarnessProvider]
        /// The models a bot may use on a harness; a harness missing here may use any.
        public var models: [HarnessProvider: [String]]
        public var tokens: TokenLimit?
    }

    public struct User: Equatable, Sendable {
        public var name: String
        public var plan: String
        public var isAdmin: Bool
        public var canPairDevices: Bool
    }

    public static let defaultData = URL(fileURLWithPath: "/var/lib/noodled")
    public static let defaultPlan = "Default"
    /// The harnesses the server knows how to run in its sandbox.
    public static let supported: [HarnessProvider] = [.claudeCode, .codex]

    public var name: String
    public var data: URL
    public var port: UInt16
    /// Where devices away from the server's networks reach it, such as a domain, with a port when it is not `port`.
    public var address: String?
    /// Each harness the admin installed, by where its program is.
    public var harnesses: [HarnessProvider: String]
    public var plans: [Plan]
    public var users: [User]

    public init(contentsOf url: URL) throws {
        try self.init(yaml: String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    public init(yaml: String) throws {
        let root: Node
        do {
            root = try Yams.compose(yaml: yaml) ?? Node("")
        } catch {
            throw ServerConfigurationError("noodled.yaml is not valid YAML: \(error)")
        }
        let settings = try Self.settings(root, at: "", known: ["name", "data", "port", "address", "harnesses", "plans", "users"])
        name = try settings["name"].map { try Self.text($0, at: "name") } ?? Self.hostName
        data = try settings["data"].map { URL(fileURLWithPath: try Self.text($0, at: "data")) } ?? Self.defaultData
        port = try settings["port"].map { try Self.port($0) } ?? 38_415
        address = try settings["address"].map { try Self.text($0, at: "address", expected: "expected a host name or address, with a port if it is not the server's.") }

        var harnesses: [HarnessProvider: String] = [:]
        for (key, value) in try Self.named(settings["harnesses"], at: "harnesses", expected: "expected each harness by name, with the path to it.") {
            let path = "harnesses.\(key)"
            harnesses[try Self.harness(key, at: path)] = try Self.text(value, at: path, expected: "expected the path to the harness.")
        }
        self.harnesses = harnesses

        plans = try Self.named(settings["plans"], at: "plans", expected: "expected each plan by name, with its settings.").map { name, node in
            let path = "plans.\(name)"
            let plan = try Self.settings(node, at: path, known: ["harnesses", "models", "tokens"])
            var models: [HarnessProvider: [String]] = [:]
            for (key, value) in try Self.named(plan["models"], at: "\(path).models", expected: "expected the models of each harness by its name.") {
                models[try Self.harness(key, at: "\(path).models.\(key)")] = try Self.list(value, at: "\(path).models.\(key)")
            }
            return Plan(name: name,
                        harnesses: try (plan["harnesses"].map { try Self.list($0, at: "\(path).harnesses") } ?? [])
                            .map { try Self.harness($0, at: "\(path).harnesses") },
                        models: models,
                        tokens: try plan["tokens"].map { try Self.tokens($0, at: "\(path).tokens") })
        }

        users = try Self.named(settings["users"], at: "users", expected: "expected each user by name, with their settings.").map { name, node in
            let path = "users.\(name)"
            let user = try Self.settings(node, at: path, known: ["plan", "admin", "pair-devices"])
            return User(name: name,
                        plan: try user["plan"].map { try Self.text($0, at: "\(path).plan") } ?? Self.defaultPlan,
                        isAdmin: try user["admin"].map { try Self.flag($0, at: "\(path).admin") } ?? false,
                        canPairDevices: try user["pair-devices"].map { try Self.flag($0, at: "\(path).pair-devices") } ?? false)
        }
    }

    /// What reads fine but cannot work on this machine, each with where it is in the file.
    public func problems(isProgram: (String) -> Bool = Self.isProgram) -> [String] {
        var problems: [String] = []
        if let address, LinkEndpoint(text: address, defaultPort: port) == nil {
            problems.append("address: \(address) is not a host name or address, with a port if it is not the server's.")
        }
        for (provider, path) in harnesses.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if !Self.supported.contains(provider) {
                problems.append("harnesses.\(provider.rawValue): noodled runs only \(Self.supported.map(\.rawValue).joined(separator: " and ")) for now.")
            } else if !isProgram(path) {
                problems.append("harnesses.\(provider.rawValue): \(path) is not a program noodled can run.")
            }
        }
        for plan in plans {
            for provider in plan.harnesses where harnesses[provider] == nil {
                problems.append("plans.\(plan.name).harnesses: \(provider.rawValue) is not one of the harnesses this server has.")
            }
        }
        let planNames = Set(plans.map(\.name) + [Self.defaultPlan])
        for user in users where !planNames.contains(user.plan) {
            problems.append("users.\(user.name).plan: there is no plan named \(user.plan).")
        }
        return problems
    }

    public static func isProgram(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static var hostName: String {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "Noodle Server" : name
    }

    // MARK: Reading values

    private static func settings(_ node: Node, at path: String, known: Set<String>) throws -> [String: Node] {
        guard case .mapping(let mapping) = node else {
            if case .scalar(let scalar) = node, scalar.string.isEmpty { return [:] }
            throw ServerConfigurationError("\(path.isEmpty ? "noodled.yaml" : path): expected settings, one per line.")
        }
        var settings: [String: Node] = [:]
        for (key, value) in mapping {
            let name = key.string ?? ""
            guard known.contains(name) else {
                throw ServerConfigurationError("\(path.isEmpty ? name : "\(path).\(name)"): noodled has no such setting.")
            }
            settings[name] = value
        }
        return settings
    }

    /// A mapping whose keys are names, in the order written.
    private static func named(_ node: Node?, at path: String, expected: String) throws -> [(String, Node)] {
        guard let node else { return [] }
        if case .scalar(let scalar) = node, scalar.string.isEmpty { return [] }
        guard case .mapping(let mapping) = node else { throw ServerConfigurationError("\(path): \(expected)") }
        return try mapping.map { key, value in
            guard let name = key.string, !name.isEmpty else { throw ServerConfigurationError("\(path): \(expected)") }
            return (name, value)
        }
    }

    private static func text(_ node: Node, at path: String, expected: String = "expected text.") throws -> String {
        guard case .scalar(let scalar) = node, !scalar.string.isEmpty else { throw ServerConfigurationError("\(path): \(expected)") }
        return scalar.string
    }

    private static func list(_ node: Node, at path: String) throws -> [String] {
        guard case .sequence(let sequence) = node else { throw ServerConfigurationError("\(path): expected a list, such as [a, b].") }
        return try sequence.map { try text($0, at: path) }
    }

    private static func flag(_ node: Node, at path: String) throws -> Bool {
        guard let value = node.bool else { throw ServerConfigurationError("\(path): expected true or false.") }
        return value
    }

    private static func port(_ node: Node) throws -> UInt16 {
        guard let value = node.int, (1...65_535).contains(value) else {
            throw ServerConfigurationError("port: expected a number from 1 to 65535.")
        }
        return UInt16(value)
    }

    private static func harness(_ name: String, at path: String) throws -> HarnessProvider {
        guard let provider = HarnessProvider(rawValue: name) else {
            throw ServerConfigurationError("\(path): there is no harness called \(name).")
        }
        return provider
    }

    private static func tokens(_ node: Node, at path: String) throws -> TokenLimit {
        let settings = try settings(node, at: path, known: ["limit", "per"])
        guard let limit = settings["limit"]?.int, limit > 0 else {
            throw ServerConfigurationError("\(path).limit: expected a number above 0.")
        }
        let period = try settings["per"].map { try text($0, at: "\(path).per") } ?? "week"
        let words = period.lowercased().split(separator: " ")
        let length = words.count == 2 ? Int(words[0]) : 1
        let unitName = words.last.map { $0.hasSuffix("s") ? String($0.dropLast()) : String($0) }
        guard (1...2).contains(words.count), let length, length > 0,
              let unit = TokenLimit.Unit.allCases.first(where: { $0.name(count: 1) == unitName }) else {
            throw ServerConfigurationError("\(path).per: expected a period such as week, 2 days or month.")
        }
        return TokenLimit(tokens: limit, length: length, unit: unit)
    }
}

public struct ServerConfigurationError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
