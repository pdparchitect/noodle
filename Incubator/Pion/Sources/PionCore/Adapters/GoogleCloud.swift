import Foundation
import NoodleCore
import NoodleMCP

/// Google Cloud, as a defender reads it: who did what in the audit logs, what Security Command Center found, who has
/// access to what, and where resources are. Each account is one organisation, folder or project, reached as a
/// service account with read-only access.
public enum GoogleCloud {
    public static let preset = ToolDefinition(
        id: "google-cloud", name: "Google Cloud", summary: "Audit logs, Security Command Center findings, IAM access and resources, read-only.",
        defaultInstructions: """
        Use Google Cloud to investigate an organisation, folder or project: search the Cloud Audit Logs by principal, \
        method, resource and time; list Security Command Center findings by severity and category; find who has access \
        to what from IAM policies; and find resources by name or type. Record each finding as evidence, citing the scope \
        and time window. These tools only read: recommend removing access or changing a resource to the champion.
        """,
        iconName: "google-cloud",
        configuration: .mcp(.init(endpointTemplate: "https://googleapis.com",
            fields: [ToolField(key: "level", title: "Scope", placeholder: "organizations", kind: .choice([
                         .init(value: "organizations", title: "Organization"), .init(value: "folders", title: "Folder"),
                         .init(value: "projects", title: "Project")])),
                     ToolField(key: "id", title: "Organization, folder or project ID", placeholder: "123456789012", kind: .identifier)],
            googleScopes: ["https://www.googleapis.com/auth/cloud-platform.read-only"], adapter: "google-cloud")))

    public static let adapter = OperationAdapter(operations: [AuditLogs(), Findings(), IAMPolicies(), FindResources()])

    /// The account's scope, such as organizations/123456789012.
    static func scope(_ service: ServiceClient) throws -> (level: String, id: String) {
        let level = try ServiceInput.oneOf(try service.setting("level"), ["organizations", "folders", "projects"], "scope")
        return (level, try service.setting("id"))
    }

    /// A value inside a Google filter's double quotes.
    static func quoted(_ value: String, _ name: String) throws -> String { "\"" + (try ServiceInput.quoted(value, name)) + "\"" }
}

extension GoogleCloud {
    struct AuditLogs: ServiceOperation {
        struct Input: Decodable, Sendable { let principal: String?, method: String?, resource: String?, since: String?, until: String?, limit: Int? }
        static let name = "audit-logs"
        static let summary = "Cloud Audit Log entries, newest first, by principal, method and resource, with caller IP and status."
        static let input = JSONSchema.object([
            "principal": .string("The email of who acted, such as mallory@example.com or a service account."),
            "method": .string("The API method, such as SetIamPolicy or google.iam.admin.v1.CreateServiceAccountKey."),
            "resource": .string("The resource name, such as projects/my-project."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."), "limit": .integer("How many entries, at most.", minimum: 1, maximum: 200),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            var filter = [#"logName:"cloudaudit.googleapis.com""#]
            if let principal = input.principal { filter.append("protoPayload.authenticationInfo.principalEmail=" + (try GoogleCloud.quoted(principal, "the principal"))) }
            if let method = input.method { filter.append("protoPayload.methodName:" + (try GoogleCloud.quoted(method, "the method"))) }
            if let resource = input.resource { filter.append("protoPayload.resourceName:" + (try GoogleCloud.quoted(resource, "the resource"))) }
            filter.append("timestamp>=\"\(try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7))\"")
            if let until = input.until { filter.append("timestamp<=\"\(try ServiceInput.time(until))\"") }
            let limit = input.limit ?? 50
            guard (1...200).contains(limit) else { throw ServiceError.input("Ask for between 1 and 200 entries.") }
            struct Body: Encodable { let resourceNames: [String], filter: String, orderBy: String, pageSize: Int }
            struct Authentication: Codable { let principalEmail: String? }
            struct Metadata: Codable { let callerIp: String?; let callerSuppliedUserAgent: String? }
            struct Status: Codable { let code: Int?; let message: String? }
            struct Payload: Codable {
                let methodName: String?, serviceName: String?, resourceName: String?, authenticationInfo: Authentication?
                let requestMetadata: Metadata?, status: Status?
            }
            struct Entry: Codable { let timestamp: String?, logName: String?, severity: String?, protoPayload: Payload? }
            struct Entries: Codable { let entries: [Entry]? }
            let entries = try await service.at(host: "logging.googleapis.com").post(["v2", "entries:list"], body: Body(
                resourceNames: ["\(scope.level)/\(scope.id)"], filter: filter.joined(separator: " AND "), orderBy: "timestamp desc", pageSize: limit),
                as: Entries.self).entries ?? []
            let text = entries.isEmpty ? "No audit log entries match." : entries.prefix(30).map { entry in
                let payload = entry.protoPayload
                var line = "\(entry.timestamp ?? "?") \(payload?.methodName ?? "?")"
                if let who = payload?.authenticationInfo?.principalEmail { line += " by \(who)" }
                if let ip = payload?.requestMetadata?.callerIp { line += " from \(ip)" }
                if let resource = payload?.resourceName { line += " on \(resource)" }
                if let code = payload?.status?.code, code != 0 { line += " — failed (\(payload?.status?.message ?? String(code)))" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Entries(entries: entries))
        }
    }

    struct Findings: ServiceOperation {
        struct Input: Decodable, Sendable { let severities: [String]?, category: String?, limit: Int? }
        static let name = "scc-findings"
        static let summary = "Active Security Command Center findings, newest first, by severity and category, with the resource each concerns."
        static let input = JSONSchema.object([
            "severities": .array(.string("A severity.", oneOf: ["CRITICAL", "HIGH", "MEDIUM", "LOW"]), "Severities. Critical and high when left out."),
            "category": .string("A finding category, such as PUBLIC_BUCKET_ACL or Persistence: IAM Anomalous Grant."),
            "limit": .integer("How many findings, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let severities = try (input.severities ?? ["CRITICAL", "HIGH"]).map { try ServiceInput.oneOf($0, ["CRITICAL", "HIGH", "MEDIUM", "LOW"], "severity") }
            var filter = [#"state="ACTIVE""#, "(" + severities.map { "severity=\"\($0)\"" }.joined(separator: " OR ") + ")"]
            if let category = input.category { filter.append("category=" + (try GoogleCloud.quoted(category, "the category"))) }
            let limit = input.limit ?? 25
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 findings.") }
            struct Finding: Codable { let name: String?, category: String?, severity: String?, state: String?, eventTime: String?, resourceName: String?, externalUri: String? }
            struct Resource: Codable { let displayName: String?; let type: String? }
            struct Result: Codable { let finding: Finding?; let resource: Resource? }
            struct Answer: Codable { let listFindingsResults: [Result]? }
            let results = try await service.at(host: "securitycenter.googleapis.com").get(["v1", scope.level, scope.id, "sources", "-", "findings"],
                query: ["filter": filter.joined(separator: " AND "), "orderBy": "event_time desc", "pageSize": String(limit)],
                as: Answer.self).listFindingsResults ?? []
            let text = results.isEmpty ? "No active findings match." : results.map { result in
                "\(result.finding?.eventTime ?? "?") \(result.finding?.severity ?? "?") \(result.finding?.category ?? "?") — \(result.resource?.displayName ?? result.finding?.resourceName ?? "?")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Answer(listFindingsResults: results))
        }
    }

    struct IAMPolicies: ServiceOperation {
        struct Input: Decodable, Sendable { let member: String?, query: String? }
        static let name = "iam-policies"
        static let summary = "Who has which role on what: IAM policy bindings across the scope, for a member or a Cloud Asset query."
        static let input = JSONSchema.object([
            "member": .string("An email of a user, group or service account, to find every role it holds."),
            "query": .string("A Cloud Asset IAM policy query instead, such as policy:roles/owner."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let query: String
            if let member = input.member { query = "policy:" + (try GoogleCloud.quoted(member, "the member")) }
            else if let given = input.query { query = try ServiceInput.query(given, limit: 500) }
            else { throw ServiceError.input("Give a member or a query.") }
            struct Binding: Codable { let role: String?; let members: [String]? }
            struct Policy: Codable { let bindings: [Binding]? }
            struct Result: Codable { let resource: String?; let project: String?; let policy: Policy? }
            struct Answer: Codable { let results: [Result]? }
            let results = try await service.at(host: "cloudasset.googleapis.com").get(["v1", scope.level, "\(scope.id):searchAllIamPolicies"],
                                                                                       query: ["query": query, "pageSize": "100"], as: Answer.self).results ?? []
            let text = results.isEmpty ? "No IAM policy matches." : results.prefix(30).map { result in
                (result.resource ?? "?") + ": " + (result.policy?.bindings ?? []).map { "\($0.role ?? "?") to \(($0.members ?? []).prefix(5).joined(separator: ", "))" }.joined(separator: "; ")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Answer(results: results))
        }
    }

    struct FindResources: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, assetTypes: [String]? }
        static let name = "find-resources"
        static let summary = "Find resources across the scope with a Cloud Asset query, such as name:web-01 or labels.env:prod."
        static let input = JSONSchema.object([
            "query": .string("A Cloud Asset resource query, such as name:web-01, location:europe-west1 or state:RUNNING."),
            "assetTypes": .array(.string("An asset type, such as compute.googleapis.com/Instance."), "Only these types."),
        ], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            var query: [String: String?] = ["query": try ServiceInput.query(input.query, limit: 500), "pageSize": "100"]
            if let types = input.assetTypes {
                query["assetTypes"] = try ServiceInput.list(types, limit: 20) { try ServiceInput.quoted($0, "the asset type") }.joined(separator: ",")
            }
            struct Resource: Codable { let name: String?, assetType: String?, displayName: String?, location: String?, project: String?, state: String? }
            struct Answer: Codable { let results: [Resource]? }
            let resources = try await service.at(host: "cloudasset.googleapis.com").get(["v1", scope.level, "\(scope.id):searchAllResources"],
                                                                                         query: query, as: Answer.self).results ?? []
            let text = resources.isEmpty ? "No resource matches." : resources.prefix(30).map { resource in
                "\(resource.displayName ?? resource.name ?? "?") (\(resource.assetType ?? "?"))\(resource.location.map { " in \($0)" } ?? "")\(resource.state.map { ", \($0)" } ?? "")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Answer(results: resources))
        }
    }
}
