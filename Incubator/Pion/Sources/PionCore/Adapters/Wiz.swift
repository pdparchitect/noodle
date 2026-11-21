import Foundation
import NoodleCore
import NoodleToolConnections

/// Wiz: the cloud security issues it found, and read-only GraphQL queries over its graph, reached as a service
/// account. Each account is one tenant, in its region.
public enum Wiz {
    public static let preset = ToolDefinition(
        id: "6351153d-b484-4629-8a9b-37ed096300a8", name: "Wiz", summary: "Cloud security issues and queries over the Wiz security graph.",
        defaultInstructions: """
        Use Wiz to see the cloud as its security graph does: list issues by severity and status, with the resource each \
        concerns, its cloud and subscription; and run read-only GraphQL queries for anything else, such as cloud \
        resources or vulnerability findings. Record each finding as evidence, citing the issue or resource. These tools \
        only read; mutations are refused.
        """,
        iconName: "wiz",
        configuration: .connection(.init(endpointTemplate: "https://api.{region}.app.wiz.io/graphql",
            fields: [ToolField(key: "region", title: "Data center", placeholder: "us17", kind: .identifier)],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://auth.app.wiz.io/oauth/token",
                                                       parameters: ["audience": "wiz-api"]),
            adapter: "wiz")),
        setup: setup)

    static let setup = [
        "In Wiz, open **Settings › Access Management › Service Accounts** and choose **Add Service Account**.",
        "Choose the type **Custom Integration (GraphQL API)**, leave **Projects** empty for the whole tenant, and give it only `read:issues` and `read:resources`.",
        "Copy the **Client ID** and **Client Secret** here; the secret is shown only once.",
        "For the data center, open **User Settings › Tenant** and take the part of the API endpoint after `api.`: `https://api.us17.app.wiz.io/graphql` is `us17`.",
    ]

    public static let adapter = OperationAdapter(operations: [Issues(), Query()], trigger: SevereIssues())

    /// New open critical and high issues.
    struct SevereIssues: ServiceTrigger {
        var tool: String { Issues.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            struct Issue: Decodable { let id: String; let createdAt: String? }
            struct Nodes: Decodable { let nodes: [Issue]? }
            struct Data: Decodable { let issues: Nodes? }
            let filter = Issues.Filter(status: ["OPEN", "IN_PROGRESS"], severity: ["CRITICAL", "HIGH"],
                                       createdAt: .init(after: ISO8601DateFormatter().string(from: since)))
            let query = """
            query Issues($filterBy: IssueFilters, $first: Int) {
              issues: issuesV2(filterBy: $filterBy, first: $first) { nodes { id createdAt } }
            }
            """
            return (try await service.graphQL(query: query, variables: Issues.Variables(filterBy: filter, first: ServiceAlert.most), as: Data.self)
                .issues?.nodes ?? [])
                .compactMap { issue in ServiceAlert.time(issue.createdAt).map { ServiceAlert(id: issue.id, time: $0) } }
                .sorted { $0.time > $1.time }
        }
    }
}

extension Wiz {
    struct Issues: ServiceOperation {
        struct Input: Decodable, Sendable { let severities: [String]?, statuses: [String]?, since: String?, limit: Int? }
        struct Filter: Encodable {
            struct After: Encodable { let after: String }
            let status: [String]
            var severity: [String]?
            var createdAt: After?
        }
        struct Variables: Encodable { let filterBy: Filter; let first: Int }
        static let name = "issues"
        static let summary = "Cloud security issues, by severity, status and time, with the rule that raised each and the resource it concerns."
        static let input = JSONSchema.object([
            "severities": .array(.string("A severity.", oneOf: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"]), "Severities to include."),
            "statuses": .array(.string("A status.", oneOf: ["OPEN", "IN_PROGRESS", "RESOLVED", "REJECTED"]), "Statuses to include. Open and in progress when left out."),
            "since": .string("The earliest time each was raised, in ISO 8601."),
            "limit": .integer("How many issues, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter = Filter(status: try (input.statuses ?? ["OPEN", "IN_PROGRESS"]).map {
                try ServiceInput.oneOf($0, ["OPEN", "IN_PROGRESS", "RESOLVED", "REJECTED"], "status")
            })
            if let severities = input.severities {
                filter.severity = try severities.map { try ServiceInput.oneOf($0, ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"], "severity") }
            }
            if let since = input.since { filter.createdAt = .init(after: try ServiceInput.time(since)) }
            let limit = input.limit ?? 25
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 issues.") }
            struct Rule: Codable { let name: String? }
            struct Entity: Codable { let name: String?, type: String?, cloudPlatform: String?, region: String?, subscriptionName: String? }
            struct Issue: Codable { let id: String, severity: String?, status: String?, createdAt: String?, sourceRule: Rule?, entitySnapshot: Entity? }
            struct Nodes: Decodable { let nodes: [Issue]? }
            struct Data: Decodable { let issues: Nodes? }
            struct Issues: Encodable { let issues: [Issue] }
            let query = """
            query Issues($filterBy: IssueFilters, $first: Int) {
              issues: issuesV2(filterBy: $filterBy, first: $first) {
                nodes { id severity status createdAt sourceRule { name } entitySnapshot { name type cloudPlatform region subscriptionName } }
              }
            }
            """
            let issues = try await service.graphQL(query: query, variables: Variables(filterBy: filter, first: limit), as: Data.self).issues?.nodes ?? []
            let text = issues.isEmpty ? "No issues match." : issues.map { issue in
                var line = "\(issue.severity ?? "?") \(issue.status ?? "?"): \(issue.sourceRule?.name ?? issue.id)"
                if let entity = issue.entitySnapshot {
                    line += " — \(entity.name ?? "?") (\([entity.type, entity.cloudPlatform, entity.subscriptionName].compactMap { $0 }.joined(separator: ", ")))"
                }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Issues(issues: issues))
        }
    }

    struct Query: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "query"
        static let summary = "Run a read-only GraphQL query over the Wiz security graph. Mutations are refused."
        static let input = JSONSchema.object(["query": .string("The GraphQL query, such as query { cloudResources(first: 10) { nodes { name type } } }.")],
                                             required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let query = try ServiceInput.query(input.query, limit: 20_000)
            // Any operation that is not a query, anywhere in the document, is refused.
            let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            if words.contains("mutation") || words.contains("subscription") {
                throw ServiceError.input("Only queries run here; mutations and subscriptions are refused.")
            }
            struct NoVariables: Encodable {}
            let data = try await service.graphQL(query: query, variables: NoVariables(), as: CellValueTree.self)
            let text = String(data: try JSONEncoder().encode(data), encoding: .utf8) ?? ""
            return try ServiceResult(text: String(text.prefix(4_000)) + (text.count > 4_000 ? "…" : ""), structured: ["data": data])
        }
    }
}

/// Any JSON, kept as it came, for results whose shape the query chose.
indirect enum CellValueTree: Codable, Sendable {
    case object([String: CellValueTree]), array([CellValueTree]), text(String), number(Double), flag(Bool), none

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .none }
        else if let flag = try? container.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let text = try? container.decode(String.self) { self = .text(text) }
        else if let array = try? container.decode([CellValueTree].self) { self = .array(array) }
        else { self = .object(try container.decode([String: CellValueTree].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object): try container.encode(object)
        case .array(let array): try container.encode(array)
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        case .none: try container.encodeNil()
        }
    }
}
