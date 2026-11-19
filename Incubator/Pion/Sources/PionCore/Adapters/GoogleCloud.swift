import Foundation
import NoodleCore
import NoodleMCP

/// Google Cloud, as a defender reads it: who did what in the audit logs, what Security Command Center found, who has
/// access to what, and where resources are. Each account is one organisation, folder or project, read as the person
/// who signs in with Google, through an iOS OAuth client their organisation made for Pion's bundle ID, as Google
/// Workspace is.
public enum GoogleCloud {
    public static let preset = ToolDefinition(
        id: "371912f8-7145-4096-a763-2c3ce3af0e55", name: "Google Cloud", summary: "Audit logs, Security Command Center findings, IAM access and resources, read-only.",
        defaultInstructions: """
        Use Google Cloud to investigate an organisation, folder or project: search the Cloud Audit Logs by principal, \
        method, resource and time; list Security Command Center findings by severity and category; find who has access \
        to what, for a member, including through groups, or for a resource; and list resources by type, by name too. Record each finding as evidence, citing the scope \
        and time window. These tools only read: recommend removing access or changing a resource to the champion.
        """,
        iconName: "google-cloud",
        configuration: .connection(.init(endpointTemplate: "https://googleapis.com",
            fields: [ToolField(key: "level", title: "Scope", placeholder: "organizations", kind: .choice([
                         .init(value: "organizations", title: "Organization"), .init(value: "folders", title: "Folder"),
                         .init(value: "projects", title: "Project")])),
                     ToolField(key: "id", title: "Organization, folder or project ID", placeholder: "123456789012", kind: .identifier),
                     ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            // The narrowest each API takes: Logging's read-only scope, Cloud Asset's own, whose methods only read, and
            // Security Command Center's own, as it has no read-only one. Never all of Google Cloud, which Cloud Asset's
            // searches would need; its read-only list and analysis stand in for them.
            oauth: .google(scopes: ["https://www.googleapis.com/auth/logging.read", "https://www.googleapis.com/auth/cloudasset",
                                    "https://www.googleapis.com/auth/securitycenter"], clients: []),
            oauthClientField: "clientID", adapter: "google-cloud")),
        setup: setup)

    static let setup = [
        "In the [Google Cloud console](https://console.cloud.google.com), pick or create a project in your organisation and, under **APIs & Services › Library**, enable the **Cloud Logging**, **Security Command Center** and **Cloud Asset** APIs in it. Pion's requests count against this project.",
        "Open **Google Auth Platform**, set it up with the audience **Internal**, and under **Data Access** add the scopes `https://www.googleapis.com/auth/logging.read`, `https://www.googleapis.com/auth/cloudasset` and `https://www.googleapis.com/auth/securitycenter`. The same client can serve Google Workspace too.",
        "Under **Clients**, choose **Create client** of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev), and copy its **Client ID** here.",
        "Whoever signs in acts with their own access, so sign in with an account that holds only viewer roles where you can. It needs **Logs Viewer**, **Security Center Findings Viewer** and **Cloud Asset Viewer** on the organisation, folder or project to investigate, and **Private Logs Viewer** for Data Access logs too. Findings also need Security Command Center activated for the organisation.",
        "Set Scope and its ID to where they have that access: the organisation's or folder's number, or the project's ID. Then choose **Add & Connect** and sign in.",
    ]

    public static let adapter = OperationAdapter(operations: [AuditLogs(), Findings(), IAMPolicies(), FindResources()])

    /// The account's scope, such as organizations/123456789012.
    static func scope(_ service: ServiceClient) throws -> (level: String, id: String) {
        let level = try ServiceInput.oneOf(try service.setting("level"), ["organizations", "folders", "projects"], "scope")
        return (level, try service.setting("id"))
    }

    /// The projects under an organisation or folder, from Cloud Asset's read-only listing: each one's ID, number
    /// and lifecycle state. A deleted project stays listed, with its resources, for 30 days.
    static func projects(_ service: ServiceClient, _ scope: (level: String, id: String)) async throws -> [(id: String, number: String, state: String)] {
        struct Data: Codable { let projectId: String?; let lifecycleState: String? }
        struct Details: Codable { let data: Data? }
        struct Asset: Codable { let name: String?; let resource: Details? }
        struct Answer: Codable { let assets: [Asset]? }
        let assets = try await service.at(host: "cloudasset.googleapis.com").get(["v1", scope.level, scope.id, "assets"], query: [
            "contentType": "RESOURCE", "pageSize": "500",
        ], repeated: ["assetTypes": ["cloudresourcemanager.googleapis.com/Project"]], as: Answer.self).assets ?? []
        return assets.compactMap { asset in
            guard let data = asset.resource?.data, let id = data.projectId, let number = asset.name?.split(separator: "/").last else { return nil }
            return (id, String(number), data.lifecycleState ?? "ACTIVE")
        }
    }

    /// The IDs of the live projects under an organisation or folder.
    static func liveProjects(_ service: ServiceClient, _ scope: (level: String, id: String)) async throws -> [String] {
        try await projects(service, scope).filter { $0.state == "ACTIVE" }.map(\.id)
    }

    /// For an organisation or folder, how each of its projects not in use is described, by its ID and by its number,
    /// so what sits in a project pending deletion is not taken for live; empty for a project's own account.
    static func retiredProjects(_ service: ServiceClient, _ scope: (level: String, id: String)) async throws -> [String: String] {
        guard scope.level != "projects" else { return [:] }
        var retired: [String: String] = [:]
        for project in try await projects(service, scope) where project.state != "ACTIVE" {
            let said = project.state == "DELETE_REQUESTED" ? "pending deletion" : project.state.lowercased().replacingOccurrences(of: "_", with: " ")
            retired[project.id] = said
            retired[project.number] = said
        }
        return retired
    }

    /// The project a resource's full name or ancestor names, such as kestrel-prod in
    /// //iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@…, or 1001 in projects/1001.
    static func project(in name: String) -> String? {
        let parts = name.split(separator: "/")
        guard let index = parts.firstIndex(of: "projects"), index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }

    /// A value inside a Google filter's double quotes.
    static func quoted(_ value: String, _ name: String) throws -> String { "\"" + (try ServiceInput.quoted(value, name)) + "\"" }
}

extension GoogleCloud {
    struct AuditLogs: ServiceOperation {
        struct Input: Decodable, Sendable { let principal: String?, method: String?, resource: String?, since: String?, until: String?, limit: Int? }
        static let name = "audit-logs"
        static let summary = "Cloud Audit Log entries across the scope and each of its live projects, newest first, by principal, method and resource, with caller IP and status."
        static let input = JSONSchema.object([
            "principal": .string("The email of who acted, such as mallory@example.com or a service account."),
            "method": .string("The API method, such as SetIamPolicy or google.iam.admin.v1.CreateServiceAccountKey."),
            "resource": .string("The resource name, such as projects/my-project."),
            "since": .string("The earliest time, in ISO 8601. The last 30 days when left out."),
            "until": .string("The latest time, in ISO 8601."), "limit": .integer("How many entries, at most.", minimum: 1, maximum: 200),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            // The audit logs by name, which Logging finds by index; matching part of every log's name is slow enough
            // across an organisation's projects for Logging to fail the search.
            var filter = ["(" + ["activity", "data_access", "system_event", "policy", "access_transparency"]
                .map { #"log_id("cloudaudit.googleapis.com/\#($0)")"# }.joined(separator: " OR ") + ")"]
            if let principal = input.principal { filter.append("protoPayload.authenticationInfo.principalEmail=" + (try GoogleCloud.quoted(principal, "the principal"))) }
            if let method = input.method { filter.append("protoPayload.methodName:" + (try GoogleCloud.quoted(method, "the method"))) }
            if let resource = input.resource { filter.append("protoPayload.resourceName:" + (try GoogleCloud.quoted(resource, "the resource"))) }
            filter.append("timestamp>=\"\(try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(30))\"")
            if let until = input.until { filter.append("timestamp<=\"\(try ServiceInput.time(until))\"") }
            let limit = input.limit ?? 50
            guard (1...200).contains(limit) else { throw ServiceError.input("Ask for between 1 and 200 entries.") }
            struct Body: Encodable { let resourceNames: [String], filter: String, orderBy: String, pageSize: Int, pageToken: String? }
            struct Authentication: Codable { let principalEmail: String? }
            struct Metadata: Codable { let callerIp: String?; let callerSuppliedUserAgent: String? }
            struct Status: Codable { let code: Int?; let message: String? }
            struct Payload: Codable {
                let methodName: String?, serviceName: String?, resourceName: String?, authenticationInfo: Authentication?
                let requestMetadata: Metadata?, status: Status?
            }
            struct Entry: Codable { let timestamp: String?, logName: String?, severity: String?, protoPayload: Payload? }
            struct Entries: Codable { let entries: [Entry]?; var nextPageToken: String? = nil }
            // Each project keeps its own audit logs, so an organisation's or folder's search names its live projects too,
            // as many as Logging takes at once.
            var names = ["\(scope.level)/\(scope.id)"]
            var note = ""
            if scope.level != "projects" {
                let projects = try await GoogleCloud.liveProjects(service, scope)
                names += projects.prefix(99).map { "projects/" + $0 }
                if projects.count > 99 { note = "\nOnly the first 99 of \(projects.count) projects' logs were searched; narrow the account to a folder for the rest." }
            }
            // Logging may hand back empty pages that still lead on, so it reads ten at most. It fails a search now and
            // then, as Google says to expect, so a failed page is asked for once more before giving up.
            var entries: [Entry] = [], page: String?, pages = 0, retried = false
            while true {
                let body = Body(resourceNames: names, filter: filter.joined(separator: " AND "), orderBy: "timestamp desc",
                                pageSize: limit - entries.count, pageToken: page)
                let answer: Entries
                do { answer = try await service.at(host: "logging.googleapis.com").post(["v2", "entries:list"], body: body, as: Entries.self) }
                catch ServiceError.status(let status, _) where status >= 500 && !retried {
                    retried = true
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                pages += 1
                entries += answer.entries ?? []
                page = answer.nextPageToken
                if page == nil || entries.count >= limit || pages >= 10 { break }
            }
            // Pages left unread mean entries may still be there, older ones at least.
            let unfinished = page != nil && entries.count < limit
            if unfinished {
                note += "\nLogging did not finish searching the whole time window, so older entries may be missing; narrow it with since and until, or by principal, method or resource."
            }
            let text = entries.isEmpty ? (unfinished ? "No audit log entries were found." : "No audit log entries match.") + note : entries.prefix(30).map { entry in
                let payload = entry.protoPayload
                var line = "\(entry.timestamp ?? "?") \(payload?.methodName ?? "?")"
                if let who = payload?.authenticationInfo?.principalEmail { line += " by \(who)" }
                if let ip = payload?.requestMetadata?.callerIp { line += " from \(ip)" }
                if let resource = payload?.resourceName { line += " on \(resource)" }
                // Where it was logged, when that is a project rather than the scope itself.
                if let log = entry.logName, log.hasPrefix("projects/"), let project = log.split(separator: "/").dropFirst().first {
                    line += " in projects/\(project)"
                }
                if let code = payload?.status?.code, code != 0 { line += " — failed (\(payload?.status?.message ?? String(code)))" }
                return line
            }.joined(separator: "\n") + note
            return try ServiceResult(text: text, structured: Entries(entries: Array(entries.prefix(limit))))
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
            let results = try await service.at(host: "securitycenter.googleapis.com").get(["v2", scope.level, scope.id, "sources", "-", "findings"],
                query: ["filter": filter.joined(separator: " AND "), "orderBy": "event_time desc", "pageSize": String(limit)],
                as: Answer.self).listFindingsResults ?? []
            let text = results.isEmpty ? "No active findings match." : results.map { result in
                "\(result.finding?.eventTime ?? "?") \(result.finding?.severity ?? "?") \(result.finding?.category ?? "?") — \(result.resource?.displayName ?? result.finding?.resourceName ?? "?")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Answer(listFindingsResults: results))
        }
    }

    struct IAMPolicies: ServiceOperation {
        struct Input: Decodable, Sendable { let member: String?, resource: String?, role: String? }
        static let name = "iam-policies"
        static let summary = "Who can do what on which resource across the scope: for a member, including access through groups, or for a resource."
        static let input = JSONSchema.object([
            "member": .string("A user's or service account's email, or a principal such as group:admins@example.com, to find every role it holds."),
            "resource": .string("A full resource name instead, such as //cloudresourcemanager.googleapis.com/projects/my-project, to find who has access to it."),
            "role": .string("Only this role, such as roles/owner."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            guard input.member != nil || input.resource != nil else { throw ServiceError.input("Give a member or a resource.") }
            var query: [String: String?] = [:]
            if let member = input.member {
                let value = try ServiceInput.quoted(member.trimmingCharacters(in: .whitespaces), "the member")
                // A bare email is a person's, or a service account's when it ends as theirs do.
                query["analysisQuery.identitySelector.identity"] = value.contains(":") ? value
                    : (value.hasSuffix(".gserviceaccount.com") ? "serviceAccount:" : "user:") + value
                query["analysisQuery.options.expandGroups"] = "true"
            }
            if let resource = input.resource {
                let value = try ServiceInput.quoted(resource.trimmingCharacters(in: .whitespaces), "the resource")
                guard value.hasPrefix("//") else { throw ServiceError.input("Give the resource's full name, such as //cloudresourcemanager.googleapis.com/projects/my-project.") }
                query["analysisQuery.resourceSelector.fullResourceName"] = value
            }
            if let role = input.role {
                let value = try ServiceInput.quoted(role.trimmingCharacters(in: .whitespaces), "the role")
                guard value.hasPrefix("roles/") || value.contains("/roles/") else { throw ServiceError.input("Give the role as roles/owner or a custom role's name.") }
                query["analysisQuery.accessSelector.roles"] = value
            }
            struct Binding: Codable { let role: String?; let members: [String]? }
            struct Named: Codable { let name: String? }
            struct Identities: Codable { let identities: [Named]? }
            struct Result: Codable { let attachedResourceFullName: String?; let iamBinding: Binding?; let identityList: Identities? }
            struct Analysis: Codable { let analysisResults: [Result]?; let fullyExplored: Bool? }
            struct Answer: Codable { let mainAnalysis: Analysis? }
            let analysis = try await service.at(host: "cloudasset.googleapis.com").get(["v1", scope.level, "\(scope.id):analyzeIamPolicy"],
                                                                                        query: query, as: Answer.self).mainAnalysis
            let results = analysis?.analysisResults ?? []
            let retired = results.isEmpty ? [:] : try await GoogleCloud.retiredProjects(service, scope)
            var text = results.isEmpty ? "No access matches." : results.prefix(30).map { result in
                let who = (result.identityList?.identities ?? []).compactMap(\.name)
                let state = result.attachedResourceFullName.flatMap(GoogleCloud.project(in:)).flatMap { retired[$0] }
                return "\(result.attachedResourceFullName ?? "?")\(state.map { " (project \($0))" } ?? ""): \(result.iamBinding?.role ?? "?") to "
                    + ((result.iamBinding?.members ?? []).prefix(5).joined(separator: ", "))
                    + (who.isEmpty ? "" : " (reaching \(who.prefix(5).joined(separator: ", ")))")
            }.joined(separator: "\n")
            if analysis?.fullyExplored == false { text += "\nThe analysis was not complete; narrow it to a resource or a role." }
            struct Kept: Encodable { let results: [Result] }
            return try ServiceResult(text: text, structured: Kept(results: results))
        }
    }

    struct FindResources: ServiceOperation {
        struct Input: Decodable, Sendable { let assetTypes: [String], name: String? }
        static let name = "find-resources"
        static let summary = "Resources of the given types across the scope, with where each is and its state, optionally only those whose name contains a word."
        static let input = JSONSchema.object([
            "assetTypes": .array(.string("An asset type, such as compute.googleapis.com/Instance or storage.googleapis.com/Bucket."), "The types to list, up to 20."),
            "name": .string("Only resources whose name contains this, such as web-01."),
        ], required: ["assetTypes"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            guard !input.assetTypes.isEmpty else { throw ServiceError.input("Give at least one asset type, such as compute.googleapis.com/Instance.") }
            let types = try ServiceInput.list(input.assetTypes, limit: 20) { try ServiceInput.quoted($0, "the asset type") }
            let word = input.name?.trimmingCharacters(in: .whitespaces).lowercased()
            /// A resource's own name and state, under whichever names its type uses, read leniently since types differ:
            /// a project gives its ID, name and lifecycle state; an instance its name and status.
            struct State: Codable {
                let projectId: String?, name: String?, displayName: String?, status: String?, state: String?, lifecycleState: String?
                init(from decoder: Decoder) throws {
                    let fields = try? decoder.container(keyedBy: CodingKeys.self)
                    func text(_ key: CodingKeys) -> String? { try? fields?.decode(String.self, forKey: key) }
                    projectId = text(.projectId); name = text(.name); displayName = text(.displayName)
                    status = text(.status); state = text(.state); lifecycleState = text(.lifecycleState)
                }
                /// What it is called, without repeating the end of its address.
                func called(_ short: String) -> String {
                    let names = [projectId, name, displayName].compactMap { $0 }.filter { $0 != short }
                    var seen = Set<String>()
                    return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
                }
            }
            struct Details: Codable { let location: String?; let data: State? }
            struct Asset: Codable { let name: String?; let assetType: String?; let resource: Details?; var ancestors: [String]? = nil }
            struct Answer: Codable { let assets: [Asset]? }
            let assets = try await service.at(host: "cloudasset.googleapis.com").get(["v1", scope.level, scope.id, "assets"], query: [
                "contentType": "RESOURCE", "pageSize": "500",
            ], repeated: ["assetTypes": types], as: Answer.self).assets ?? []
            func short(_ asset: Asset) -> String { (asset.name ?? "?").split(separator: "/").last.map(String.init) ?? "?" }
            func label(_ asset: Asset) -> String {
                let called = asset.resource?.data?.called(short(asset)) ?? ""
                // A project's address ends in its number, which says less than its ID and name.
                return called.isEmpty ? short(asset) : asset.assetType == "cloudresourcemanager.googleapis.com/Project" ? called : "\(short(asset)), \(called)"
            }
            let matching = assets.filter { asset in
                word.map { !$0.isEmpty && ((asset.name ?? "") + " " + label(asset)).lowercased().contains($0) } ?? true
            }
            let retired = matching.isEmpty ? [:] : try await GoogleCloud.retiredProjects(service, scope)
            let text = matching.isEmpty ? "No resource matches." : matching.prefix(30).map { asset in
                let data = asset.resource?.data
                let state = data?.status ?? data?.state ?? data?.lifecycleState
                // A project's own state says it already; what sits in one pending deletion says so too.
                let home = asset.assetType == "cloudresourcemanager.googleapis.com/Project" ? nil
                    : (asset.ancestors?.first.flatMap(GoogleCloud.project(in:)) ?? asset.name.flatMap(GoogleCloud.project(in:))).flatMap { retired[$0] }
                return "\(label(asset)) (\(asset.assetType ?? "?"))\(asset.resource?.location.map { " in \($0)" } ?? "")\(state.map { ", \($0)" } ?? "")"
                    + (home.map { ", in a project \($0)" } ?? "")
            }.joined(separator: "\n")
            struct Kept: Encodable { let resources: [Asset] }
            return try ServiceResult(text: text, structured: Kept(resources: Array(matching.prefix(100))))
        }
    }
}
