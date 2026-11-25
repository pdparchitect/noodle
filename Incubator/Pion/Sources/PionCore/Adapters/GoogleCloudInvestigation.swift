import Foundation
import NoodleCore
import NoodleToolConnections

/// Google Cloud Detection's deeper reads, all through the scopes it already holds: who can act as a service account,
/// what is public, which keys exist, what changed in the last 35 days, which organisation policies are set, where
/// Data Access logging is on, and one Security Command Center finding in full or all of them counted.
extension GoogleCloud {
    // MARK: JSON

    /// Any JSON value, for the parts of Google's answers whose shape differs by service or type.
    enum JSON: Codable, Equatable, Sendable {
        case string(String), number(Double), bool(Bool), array([JSON]), object([String: JSON]), null

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else if let text = try? value.decode(String.self) { self = .string(text) }
            else if let array = try? value.decode([JSON].self) { self = .array(array) }
            else { self = .object(try value.decode([String: JSON].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .string(let text): try value.encode(text)
            case .number(let number): try value.encode(number)
            case .bool(let bool): try value.encode(bool)
            case .array(let array): try value.encode(array)
            case .object(let object): try value.encode(object)
            case .null: try value.encodeNil()
            }
        }

        subscript(key: String) -> JSON? {
            if case .object(let object) = self { return object[key] }
            return nil
        }

        var text: String? { if case .string(let text) = self { return text }; return nil }

        /// The value on one short line, at most `limit` characters: a list's first ten items, an object's first six
        /// fields as name=value.
        func compact(_ limit: Int = 200) -> String {
            let said: String
            switch self {
            case .string(let text): said = text
            case .number(let number): said = number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            case .bool(let bool): said = bool ? "true" : "false"
            case .null: said = "null"
            case .array(let items):
                said = items.prefix(10).map { $0.compact(limit) }.joined(separator: ", ") + (items.count > 10 ? " (+\(items.count - 10) more)" : "")
            case .object(let fields):
                said = "{" + fields.keys.sorted().prefix(6).map { "\($0)=\(fields[$0]!.compact(limit))" }.joined(separator: " ")
                    + (fields.count > 6 ? " …" : "") + "}"
            }
            return said.count > limit ? String(said.prefix(limit - 1)) + "…" : said
        }
    }

    // MARK: Cloud Asset listings

    struct AssetPage<Asset: Decodable>: Decodable { let assets: [Asset]?; let nextPageToken: String? }

    /// What a listing read: the assets kept, how many it read in all, and why it stopped short when it did.
    struct Listing<Asset> {
        var assets: [Asset] = [], read = 0, pages = 0, token: String? = nil, stopped: String? = nil
        /// Whether every asset there was read.
        var complete: Bool { token == nil && stopped == nil }
    }

    /// Cloud Asset's read-only listing of the scope, page after page, up to `pages` pages of 1000, keeping what `keep`
    /// takes, until `enough` of them are kept. A first page refused says what to change; a later one that fails keeps
    /// what was read and says why it stopped.
    static func listAssets<Asset: Decodable>(_ service: ServiceClient, _ scope: (level: String, id: String), content: String, types: [String] = [],
                                             readTime: String? = nil, pages: Int, keep: (Asset) -> Bool = { _ in true },
                                             enough: Int = .max) async throws -> Listing<Asset> {
        let own = "\(scope.level)/\(scope.id)", assets = try service.at(host: "cloudasset.googleapis.com")
        var found = Listing<Asset>()
        repeat {
            let page: AssetPage<Asset>
            do {
                page = try await read(.assets, own) {
                    try await assets.get(["v1", scope.level, scope.id, "assets"], query: [
                        "contentType": content, "pageSize": "1000", "pageToken": found.token, "readTime": readTime,
                    ], repeated: types.isEmpty ? [:] : ["assetTypes": types], as: AssetPage<Asset>.self)
                }
            } catch where found.pages > 0 {
                found.stopped = error.localizedDescription
                return found
            }
            found.pages += 1
            found.read += page.assets?.count ?? 0
            found.assets += (page.assets ?? []).filter(keep)
            found.token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while found.token != nil && found.pages < pages && found.assets.count < enough
        return found
    }

    /// What a listing that stopped short leaves out, said for the text, or nil when it read everything.
    static func shortfall<Asset>(_ listing: Listing<Asset>, _ what: String) -> String? {
        if let stopped = listing.stopped {
            return "Read only in part: a later page could not be read (\(stopped)), so \(what) after the first \(listing.read) were not checked."
        }
        if listing.token != nil {
            return "Not read: more \(what) than the \(listing.read) one call reads; narrow it, or set the account to a folder or project."
        }
        return nil
    }

    static let organizationType = "cloudresourcemanager.googleapis.com/Organization"

    /// A resource's relative name from its full one, such as projects/1001 from
    /// //cloudresourcemanager.googleapis.com/projects/1001.
    static func relative(_ name: String) -> String {
        guard name.hasPrefix("//"), let slash = name.dropFirst(2).firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// One logged permission type for one service in an IAM policy, and whom it leaves unlogged.
    struct AuditLogConfig: Codable { let logType: String?; let exemptedMembers: [String]? }
    struct AuditConfig: Codable { let service: String?; let auditLogConfigs: [AuditLogConfig]? }
    struct Policy: Codable {
        let bindings: [IAMPolicies.Binding]?, auditConfigs: [AuditConfig]?
        enum CodingKeys: String, CodingKey { case bindings, auditConfigs }
        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            bindings = try? fields?.decodeIfPresent([IAMPolicies.Binding].self, forKey: .bindings)
            auditConfigs = try? fields?.decodeIfPresent([AuditConfig].self, forKey: .auditConfigs)
        }
    }
    /// An IAM policy as Cloud Asset lists it, with the resource it is set on and that resource's ancestors.
    struct PolicyAsset: Codable {
        let name: String?, assetType: String?, iamPolicy: Policy?, ancestors: [String]?, updateTime: String?
        enum CodingKeys: String, CodingKey { case name, assetType, iamPolicy, ancestors, updateTime }
        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            name = try? fields?.decodeIfPresent(String.self, forKey: .name)
            assetType = try? fields?.decodeIfPresent(String.self, forKey: .assetType)
            iamPolicy = try? fields?.decodeIfPresent(Policy.self, forKey: .iamPolicy)
            ancestors = try? fields?.decodeIfPresent([String].self, forKey: .ancestors)
            updateTime = try? fields?.decodeIfPresent(String.self, forKey: .updateTime)
        }
    }

    // MARK: Findings

    struct FindingDetail: ServiceOperation {
        struct Input: Decodable, Sendable { let name: String }
        static let name = "scc-finding"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "One Security Command Center finding in full, by the name scc-findings shows: its description and next steps, MITRE ATT&CK tactic and techniques, who acted, from where, with which key and through whom for a threat, the resource and its project, when it was created and last seen, and its source's own properties."
        static let input = JSONSchema.object([
            "name": .string("The finding's full name, such as organizations/123/sources/456/findings/abc."),
        ], required: ["name"])

        /// How much of the description, next steps and each source property is kept, and how many properties.
        static let textLength = 1000, propertyLength = 300, properties = 40

        struct Mitre: Codable { let primaryTactic: String?, primaryTechniques: [String]?, additionalTactics: [String]?, additionalTechniques: [String]? }
        struct Delegation: Codable { let principalEmail: String?, principalSubject: String? }
        struct Geo: Codable { let regionCode: String? }
        struct Access: Codable {
            let principalEmail: String?, principalSubject: String?, callerIp: String?, callerIpGeo: Geo?, userAgent: String?, methodName: String?
            let serviceName: String?, serviceAccountKeyName: String?, serviceAccountDelegationInfo: [Delegation]?
        }
        struct Detail: Codable {
            let name: String?, parent: String?, category: String?, severity: String?, state: String?, findingClass: String?, mute: String?
            let eventTime: String?, createTime: String?, resourceName: String?, externalUri: String?, description: String?, nextSteps: String?
            let access: Access?, mitreAttack: Mitre?
            /// The source's own fields, each on one short line.
            let sourceProperties: [String: String]?

            enum CodingKeys: String, CodingKey {
                case name, parent, category, severity, state, findingClass, mute, eventTime, createTime, resourceName, externalUri, description, nextSteps
                case access, mitreAttack, sourceProperties
            }
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                func text(_ key: CodingKeys, _ limit: Int = 500) -> String? { (try? fields.decodeIfPresent(String.self, forKey: key))?.map { String($0.prefix(limit)) } }
                name = text(.name); parent = text(.parent); category = text(.category); severity = text(.severity); state = text(.state)
                findingClass = text(.findingClass); mute = text(.mute); eventTime = text(.eventTime); createTime = text(.createTime)
                resourceName = text(.resourceName); externalUri = text(.externalUri)
                description = text(.description, FindingDetail.textLength); nextSteps = text(.nextSteps, FindingDetail.textLength)
                access = try? fields.decodeIfPresent(Access.self, forKey: .access)
                mitreAttack = try? fields.decodeIfPresent(Mitre.self, forKey: .mitreAttack)
                let properties = (try? fields.decodeIfPresent([String: JSON].self, forKey: .sourceProperties)) ?? nil
                sourceProperties = properties.map { all in
                    Dictionary(uniqueKeysWithValues: all.keys.sorted().prefix(FindingDetail.properties).map { ($0, all[$0]!.compact(FindingDetail.propertyLength)) })
                }
                propertyCount = properties?.count ?? 0
            }
            /// How many properties the source gave, kept or not.
            var propertyCount = 0
        }
        struct Metadata: Codable { let project: String?, projectDisplayName: String?, parentDisplayName: String? }
        struct Resource: Codable { let name: String?, displayName: String?, type: String?, location: String?, gcpMetadata: Metadata? }
        struct Result: Codable { let finding: Detail?; let resource: Resource? }
        struct Answer: Codable { let listFindingsResults: [Result]? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let name = try ServiceInput.quoted(input.name, "the finding's name")
            guard name.range(of: #"^(organizations|folders|projects)/[^/]+/sources/[^/]+(/locations/[^/]+)?/findings/[^/]+$"#, options: .regularExpression) != nil else {
                throw ServiceError.input("Give the finding's full name, as scc-findings shows it in brackets, such as organizations/123/sources/456/findings/abc.")
            }
            // Version 2 of the API gets no finding by name, so its source's findings are listed by that name alone.
            let source = Array(name.split(separator: "/").map(String.init).dropLast())
            let answer = try await GoogleCloud.read(.findings, own) {
                try await service.at(host: "securitycenter.googleapis.com").get(["v2"] + source, query: ["filter": "name=\"\(name)\"", "pageSize": "1"], as: Answer.self)
            }
            guard let result = answer.listFindingsResults?.first, let finding = result.finding else {
                return try ServiceResult(text: "No finding named \(name) could be read: it may not exist, or this account may not see it. Its name is as scc-findings shows it in brackets.",
                                         structured: ["found": false])
            }
            var lines = ["\(finding.category ?? "?") — \(finding.severity ?? "?")\(finding.findingClass.map { " \($0)" } ?? ""), \(finding.state ?? "?")\(finding.mute == "MUTED" ? ", muted" : "")"]
            lines.append("Last seen \(finding.eventTime ?? "?"); created \(finding.createTime ?? "?").")
            let resource = result.resource, project = resource?.gcpMetadata?.projectDisplayName ?? resource?.gcpMetadata?.project
            lines.append("Resource: \(resource?.displayName.map { "\($0), " } ?? "")\(resource?.name ?? finding.resourceName ?? "?")\(resource?.type.map { " (\($0))" } ?? "")"
                         + (project.map { " in project \($0)" } ?? "") + (resource?.location.map { ", \($0)" } ?? "") + ".")
            if let description = finding.description { lines.append("Description: \(description)") }
            if let mitre = finding.mitreAttack {
                let techniques = (mitre.primaryTechniques ?? []) + (mitre.additionalTechniques ?? [])
                lines.append("MITRE ATT&CK: \(([mitre.primaryTactic].compactMap { $0 } + (mitre.additionalTactics ?? [])).joined(separator: ", "))"
                             + (techniques.isEmpty ? "" : "; techniques \(techniques.joined(separator: ", "))") + ".")
            }
            if let access = finding.access, access.principalEmail != nil || access.principalSubject != nil || access.callerIp != nil {
                var line = "Who acted: \(access.principalEmail ?? access.principalSubject ?? "?")"
                let chain = (access.serviceAccountDelegationInfo ?? []).compactMap { $0.principalEmail ?? $0.principalSubject }
                if !chain.isEmpty { line += " (delegated by \(chain.joined(separator: " → ")))" }
                if let key = access.serviceAccountKeyName { line += " with key \(key.split(separator: "/").last.map(String.init) ?? key)" }
                if let ip = access.callerIp { line += " from \(ip)\(access.callerIpGeo?.regionCode.map { " (\($0))" } ?? "")" }
                if let method = access.methodName { line += " calling \(method)\(access.serviceName.map { " of \($0)" } ?? "")" }
                if let agent = access.userAgent { line += ", agent \(agent.prefix(80))" }
                lines.append(line + ". This is the credential used, not proof of who held it.")
            }
            if let steps = finding.nextSteps { lines.append("Next steps: \(steps)") }
            if let properties = finding.sourceProperties, !properties.isEmpty {
                let shownProperties = 15
                lines.append("Source properties: " + properties.keys.sorted().prefix(shownProperties).map { "\($0)=\(properties[$0]!)" }.joined(separator: "; ")
                             + (finding.propertyCount > shownProperties ? " (showing \(shownProperties) of \(finding.propertyCount); the structured result keeps up to \(Self.properties), each shortened to \(Self.propertyLength) characters)" : ""))
            }
            if let uri = finding.externalUri { lines.append("Console: \(uri)") }
            lines.append("[\(finding.name ?? name)]")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: result)
        }
    }

    struct FindingSummary: ServiceOperation {
        struct Input: Decodable, Sendable { let groupBy: [String]?, severities: [String]?, since: String?, includeMuted: Bool? }
        static let name = "scc-summary"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "How many active Security Command Center findings there are across the scope, counted by category, severity, project or resource type, most first, to see where to look; muted ones only when asked."
        static let input = JSONSchema.object([
            "groupBy": .array(.string("What to count by.", oneOf: ["category", "severity", "project", "resourceType"]), "What to count by, up to 2. Category and severity when left out."),
            "severities": .array(.string("A severity.", oneOf: ["CRITICAL", "HIGH", "MEDIUM", "LOW"]), "Only these severities. All when left out."),
            "since": .string("Only findings last seen from this time on, in ISO 8601."),
            "includeMuted": .boolean("Count findings muted as accepted or known too; left out when not given."),
        ])

        /// Each grouping, as Security Command Center names the field.
        static let fields = ["category": "category", "severity": "severity", "project": "resource.project_display_name", "resourceType": "resource.type"]

        struct Body: Encodable { let filter: String, groupBy: String, pageSize: Int, pageToken: String? }
        struct Group: Codable {
            let properties: [String: JSON]?, count: Int
            enum CodingKeys: String, CodingKey { case properties, count }
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                properties = try? fields.decodeIfPresent([String: JSON].self, forKey: .properties)
                // Google sends a 64-bit count as a string.
                count = (try? fields.decode(Int.self, forKey: .count)) ?? Int((try? fields.decode(String.self, forKey: .count)) ?? "") ?? 0
            }
        }
        struct Answer: Decodable { let groupByResults: [Group]?; let nextPageToken: String?; let totalSize: Int? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let asked = input.groupBy ?? []
            let groups = try asked.isEmpty ? ["category", "severity"]
                : ServiceInput.list(asked, limit: 2) { try ServiceInput.oneOf($0, Array(Self.fields.keys).sorted(), "groupBy") }
            guard Swift.Set(groups).count == groups.count else { throw ServiceError.input("Give each groupBy once.") }
            let includeMuted = input.includeMuted ?? false
            var filter = [#"state="ACTIVE""#] + (includeMuted ? [] : [#"NOT mute="MUTED""#])
            if let severities = input.severities, !severities.isEmpty {
                let checked = try severities.map { try ServiceInput.oneOf($0, ["CRITICAL", "HIGH", "MEDIUM", "LOW"], "severity") }
                filter.append("(" + checked.map { "severity=\"\($0)\"" }.joined(separator: " OR ") + ")")
            }
            if let since = input.since { filter.append("event_time>=\"\(try ServiceInput.time(since))\"") }
            let groupBy = groups.map { Self.fields[$0]! }
            let center = try service.at(host: "securitycenter.googleapis.com")
            var results: [Group] = [], token: String?, pages = 0, stopped: String?
            repeat {
                let answer: Answer
                do {
                    answer = try await GoogleCloud.read(.findings, own) {
                        try await center.post(["v2", scope.level, scope.id, "sources", "-", "findings:group"],
                                              body: Body(filter: filter.joined(separator: " AND "), groupBy: groupBy.joined(separator: ","), pageSize: 1000, pageToken: token),
                                              as: Answer.self)
                    }
                } catch where pages > 0 {
                    stopped = error.localizedDescription
                    break
                }
                pages += 1
                results += answer.groupByResults ?? []
                token = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && pages < groupPages
            results.sort { $0.count > $1.count }
            func label(_ group: Group) -> [String] {
                groupBy.map { field in (group.properties?[field] ?? group.properties?[String(field.split(separator: ".").last ?? "")])?.compact(120) ?? "(none)" }
            }
            let total = results.reduce(0) { $0 + $1.count }
            var lines: [String]
            if results.isEmpty {
                lines = ["No active findings\(includeMuted ? "" : ", leaving out muted ones,") at \(own)\(input.since.map { " since \($0)" } ?? "")."]
            } else {
                lines = ["\(total) active findings in \(results.count) groups by \(GoogleCloud.listed(groups)) at \(own)\(input.since.map { " since \($0)" } ?? ""), most first:"]
                lines += results.prefix(shown).map { "\($0.count) — \(label($0).joined(separator: " · "))" }
                if results.count > shown { lines.append("Showing \(shown) of the \(results.count) groups; the structured result holds all of them.") }
            }
            if token != nil { lines.append("More groups exist than the \(results.count) read in \(groupPages) pages, and their findings are not in the total; filter by severity or since.") }
            if let stopped { lines.append("Read only in part: a later page could not be read (\(stopped)), so the total leaves groups out.") }
            if !includeMuted { lines.append("Muted findings are left out; set includeMuted to count them.") }
            lines.append("scc-findings lists the findings of a category or severity; scc-finding reads one in full.")
            struct Counted: Encodable { let values: [String: String]; let count: Int }
            struct Kept: Encodable { let groups: [Counted]; let groupBy: [String]; let total: Int; let more: Bool; let stopped: String?; let filter: String; let mutedLeftOut: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                groups: results.map { group in Counted(values: Dictionary(uniqueKeysWithValues: zip(groups, label(group))), count: group.count) },
                groupBy: groups, total: total, more: token != nil, stopped: stopped, filter: filter.joined(separator: " AND "), mutedLeftOut: !includeMuted))
        }
    }

    // MARK: Service accounts

    struct Impersonation: ServiceOperation {
        struct Input: Decodable, Sendable { let serviceAccount: String?, member: String?, project: String?, throughOtherAccounts: Bool? }
        static let name = "who-can-impersonate"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Who can act as a service account, or which service accounts a member can act as, under IAM allow policies: who can mint its tokens, sign as it, attach it to what they run or make it a key, including through groups, with each binding's condition. Each call is one of the organisation's daily IAM analyses."
        static let input = JSONSchema.object([
            "serviceAccount": .string("A service account's email, to find who can act as it."),
            "member": .string("Instead, a user's, group's or service account's email, or a principal such as group:admins@example.com, to find which service accounts it can act as."),
            "project": .string("The service account's project ID, when its email does not name it, as a default one's may not."),
            "throughOtherAccounts": .boolean("Follow chains too: who can reach it by acting first as another service account. Google warns this is slow and may time out at an organisation."),
        ])

        /// What lets someone act as a service account, as Google names it: run things as it, mint its access and ID
        /// tokens, sign blobs and JWTs as it, act through a chain of accounts, or make it a key that acts as it for as
        /// long as the key lives.
        static let permissions = ["iam.serviceAccounts.actAs", "iam.serviceAccounts.getAccessToken", "iam.serviceAccounts.getOpenIdToken",
                                  "iam.serviceAccounts.signBlob", "iam.serviceAccounts.signJwt", "iam.serviceAccounts.implicitDelegation",
                                  "iam.serviceAccountKeys.create"]

        struct Access: Codable { let permission: String?, role: String? }
        struct Reached: Codable { let fullResourceName: String? }
        struct Control: Codable { let accesses: [Access]?, resources: [Reached]?, conditionEvaluation: IAMPolicies.Evaluation? }
        struct Result: Codable {
            let attachedResourceFullName: String?, iamBinding: IAMPolicies.Binding?, identityList: IAMPolicies.Identities?
            let accessControlLists: [Control]?, fullyExplored: Bool?
        }
        struct Analysis: Codable { let analysisResults: [Result]?, fullyExplored: Bool?, nonCriticalErrors: [IAMPolicies.Problem]? }
        struct Answer: Codable { let mainAnalysis: Analysis?, serviceAccountImpersonationAnalysis: [Analysis]?, fullyExplored: Bool? }

        /// The project a service account's email names: its own for one made in a project, the App Engine default's,
        /// or the number of the project whose Compute Engine default it is.
        static func project(of email: String) -> String? {
            let parts = email.split(separator: "@").map(String.init)
            // A Google-managed service agent's domain names Google's project, not the one it serves.
            guard parts.count == 2, !parts[1].hasPrefix("gcp-sa-") else { return nil }
            if parts[1].hasSuffix(".iam.gserviceaccount.com") { return String(parts[1].dropLast(".iam.gserviceaccount.com".count)) }
            if parts[1] == "appspot.gserviceaccount.com" { return parts[0] }
            if parts[1] == "developer.gserviceaccount.com", parts[0].hasSuffix("-compute") { return String(parts[0].dropLast("-compute".count)) }
            return nil
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            guard (input.serviceAccount == nil) != (input.member == nil) else {
                throw ServiceError.input("Give a service account, to find who can act as it, or a member, to find which service accounts it can act as.")
            }
            var query: [String: String?] = [:], subject: String
            if let account = input.serviceAccount {
                let email = try ServiceInput.email(account.replacingOccurrences(of: "serviceAccount:", with: ""))
                guard email.hasSuffix(".gserviceaccount.com") else { throw ServiceError.input("\(email) is not a service account's email, which ends in .gserviceaccount.com.") }
                guard let project = try input.project.map({ try ServiceInput.quoted($0, "the project") }) ?? Self.project(of: email) else {
                    throw ServiceError.input("Give project too: \(email) does not say which project it belongs to.")
                }
                guard !project.contains("/") else { throw ServiceError.input("Give the project's ID alone, such as kestrel-prod.") }
                subject = "//iam.googleapis.com/projects/\(project)/serviceAccounts/\(email)"
                query["analysisQuery.resourceSelector.fullResourceName"] = subject
                // Members of groups holding these are named; that needs Groups Reader, said when missing.
                query["analysisQuery.options.expandGroups"] = "true"
            } else {
                let value = try ServiceInput.quoted((input.member ?? "").trimmingCharacters(in: .whitespaces), "the member")
                // A bare email is a person's, or a service account's when it ends as theirs do; a group is named as one.
                subject = value.contains(":") ? value : value.lowercased().hasSuffix(".gserviceaccount.com") ? "serviceAccount:" + value.lowercased() : "user:" + value.lowercased()
                query["analysisQuery.identitySelector.identity"] = subject
                // Access granted on a project or folder reaches each service account below it, named as such.
                query["analysisQuery.options.expandResources"] = "true"
            }
            if input.throughOtherAccounts == true { query["analysisQuery.options.analyzeServiceAccountImpersonation"] = "true" }
            let answer = try await GoogleCloud.read(.analysis, own) {
                try await service.at(host: "cloudasset.googleapis.com").get(["v1", scope.level, "\(scope.id):analyzeIamPolicy"], query: query,
                                                                            repeated: ["analysisQuery.accessSelector.permissions": Self.permissions], as: Answer.self)
            }
            let forward = input.serviceAccount != nil
            func line(_ result: Result) -> String {
                let controls = result.accessControlLists ?? []
                let granted = Array(Set(controls.flatMap { $0.accesses ?? [] }.compactMap(\.permission))).sorted()
                    .map { $0.replacingOccurrences(of: "iam.serviceAccounts.", with: "").replacingOccurrences(of: "iam.serviceAccountKeys.create", with: "keys.create") }
                let attached = result.attachedResourceFullName ?? "?", role = result.iamBinding?.role ?? "?"
                var line: String
                if forward {
                    let members = result.iamBinding?.members ?? [], who = (result.identityList?.identities ?? []).compactMap(\.name)
                    line = "\(attached): \(role) to " + members.prefix(5).joined(separator: ", ") + (members.count > 5 ? " (+\(members.count - 5) more)" : "")
                    if !who.isEmpty, Set(who) != Set(members) { line += " (reaching \(who.prefix(5).joined(separator: ", "))\(who.count > 5 ? " +\(who.count - 5) more" : ""))" }
                } else {
                    let accounts = Array(Set(controls.flatMap { $0.resources ?? [] }.compactMap(\.fullResourceName).filter { $0.contains("/serviceAccounts/") })).sorted()
                    line = "\(role) on \(attached)"
                    if !accounts.isEmpty, accounts != [attached] {
                        line += ", reaching \(accounts.count) service account\(accounts.count == 1 ? "" : "s"): " + accounts.prefix(5).joined(separator: ", ") + (accounts.count > 5 ? " (+\(accounts.count - 5) more)" : "")
                    }
                }
                if !granted.isEmpty { line += " — can \(granted.joined(separator: ", "))" }
                if let condition = result.iamBinding?.condition {
                    let evaluated = controls.compactMap { $0.conditionEvaluation?.evaluationValue }.first
                    line += " — only when \(condition.title ?? condition.expression ?? "a condition holds")\(evaluated.map { " (\($0.lowercased()))" } ?? "")"
                }
                if result.fullyExplored == false { line += " — not fully analysed" }
                return line
            }
            let results = answer.mainAnalysis?.analysisResults ?? []
            let chains = (answer.serviceAccountImpersonationAnalysis ?? []).flatMap { $0.analysisResults ?? [] }
            var lines: [String] = []
            if results.isEmpty {
                lines.append(forward ? "Nobody is granted any of these on \(subject) across \(own): \(GoogleCloud.listed(Self.permissions))."
                                     : "\(subject) is granted none of these on any service account across \(own): \(GoogleCloud.listed(Self.permissions)).")
            } else {
                lines.append(forward ? "Who can act as \(subject):" : "What \(subject) can act as:")
                lines += results.prefix(shown).map(line)
                if results.count > shown { lines.append("Showing \(shown) of \(results.count) results, each naming up to 5 members and 5 accounts; the structured result holds all of them.") }
            }
            if !chains.isEmpty {
                lines.append("Through other service accounts:")
                lines += chains.prefix(10).map(line)
                if chains.count > 10 { lines.append("Showing 10 of \(chains.count) chained results; the structured result holds all of them.") }
            } else if input.throughOtherAccounts == true {
                lines.append("No access through other service accounts was found.")
            }
            let problems = (answer.mainAnalysis?.nonCriticalErrors ?? []) + (answer.serviceAccountImpersonationAnalysis ?? []).flatMap { $0.nonCriticalErrors ?? [] }
            let explored = answer.fullyExplored != false && answer.mainAnalysis?.fullyExplored != false
            if !explored { lines.append("The analysis was not complete; ask about one service account or member, or set the account to a folder or project.") }
            if !problems.isEmpty {
                lines.append("Google could not analyse all of it: " + problems.prefix(5).map { "\($0.code ?? "?")\($0.cause.map { ": \($0)" } ?? "")" }.joined(separator: "; ")
                             + ". Access through groups needs Groups Reader in Google Workspace and custom roles need Role Viewer, so what they grant may be missing here.")
            }
            if results.contains(where: { line($0).contains("keys.create") }) {
                lines.append("Whoever can make a key can act as the account for as long as the key lives, without anyone's further say; sa-keys lists the keys it has.")
            }
            lines.append("These are IAM allow policies only: deny policies, which can block what they grant, are not evaluated. This counted as one of the 20 IAM analyses a day Google allows an organisation without Security Command Center Premium or Enterprise.")
            struct Kept: Encodable {
                let subject: String, permissions: [String], results: [Result], throughOtherAccounts: [Result], fullyExplored: Bool, nonCriticalErrors: [IAMPolicies.Problem]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(subject: subject, permissions: Self.permissions, results: results,
                                                                                    throughOtherAccounts: chains, fullyExplored: explored, nonCriticalErrors: problems))
        }
    }

    struct ServiceAccountKeys: ServiceOperation {
        struct Input: Decodable, Sendable { let serviceAccount: String?, recentDays: Int?, includeSystemManaged: Bool? }
        static let name = "sa-keys"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Service account keys across the scope, newest first, flagging user-managed keys, which work from anywhere until deleted, and those made lately, with when each was made and expires, whether it is disabled and why, and whether it was uploaded."
        static let input = JSONSchema.object([
            "serviceAccount": .string("Only this service account's keys, by its email."),
            "recentDays": .integer("Flag keys made in this many days. 30 when left out.", minimum: 1, maximum: 400),
            "includeSystemManaged": .boolean("List the keys Google holds and rotates itself too; counted only when not given."),
        ])

        static let type = "iam.googleapis.com/ServiceAccountKey"
        /// The most keys the structured result keeps.
        static let kept = 200

        struct Extended: Codable { let key: String?, value: String? }
        struct Key: Codable {
            let name: String?, keyType: String?, keyOrigin: String?, keyAlgorithm: String?, validAfterTime: String?, validBeforeTime: String?
            let disabled: Bool?, disableReason: String?, extendedStatus: [Extended]?
            enum CodingKeys: String, CodingKey { case name, keyType, keyOrigin, keyAlgorithm, validAfterTime, validBeforeTime, disabled, disableReason, extendedStatus }
            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: CodingKeys.self)
                func text(_ key: CodingKeys) -> String? { try? fields?.decodeIfPresent(String.self, forKey: key) }
                name = text(.name); keyType = text(.keyType); keyOrigin = text(.keyOrigin); keyAlgorithm = text(.keyAlgorithm)
                validAfterTime = text(.validAfterTime); validBeforeTime = text(.validBeforeTime); disableReason = text(.disableReason)
                disabled = try? fields?.decodeIfPresent(Bool.self, forKey: .disabled)
                extendedStatus = try? fields?.decodeIfPresent([Extended].self, forKey: .extendedStatus)
            }
        }
        struct Details: Codable { let data: Key? }
        struct Asset: Codable { let name: String?; let resource: Details? }
        /// One key as said: its account, ID and what makes it matter.
        struct Kept: Codable {
            let name: String, serviceAccount: String, keyID: String, keyType: String?, keyOrigin: String?, created: String?, expires: String?
            let disabled: Bool, disableReason: String?, flags: [String]
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let account = try input.serviceAccount.map { try ServiceInput.email($0.replacingOccurrences(of: "serviceAccount:", with: "")) }
            let days = input.recentDays ?? 30
            guard (1...400).contains(days) else { throw ServiceError.input("Give recentDays between 1 and 400.") }
            let includeSystem = input.includeSystemManaged ?? false
            let listing: Listing<Asset> = try await GoogleCloud.listAssets(service, scope, content: "RESOURCE", types: [Self.type], pages: policyPages) { asset in
                // Its address names the account by unique ID; its own name by email.
                account.map { (asset.resource?.data?.name ?? asset.name ?? "").lowercased().contains("/serviceaccounts/\($0)/") } ?? true
            }
            let now = Date(), recent = now.addingTimeInterval(-Double(days) * 86_400)
            var keys: [Kept] = []
            for asset in listing.assets {
                let data = asset.resource?.data, name = data?.name ?? asset.name ?? "?"
                let parts = name.split(separator: "/").map(String.init)
                let accountName = parts.firstIndex(of: "serviceAccounts").flatMap { $0 + 1 < parts.count ? parts[$0 + 1] : nil } ?? "?"
                let created = ServiceAlert.time(data?.validAfterTime), ends = ServiceAlert.time(data?.validBeforeTime)
                var flags: [String] = []
                if data?.keyType == "USER_MANAGED" { flags.append("user-managed") }
                if data?.keyOrigin == "USER_PROVIDED" { flags.append("uploaded") }
                if let created, created >= recent { flags.append("made in the last \(days) days") }
                if let ends, ends < now { flags.append("expired") }
                for status in data?.extendedStatus ?? [] { if let key = status.key { flags.append("Google flags it \(key.replacingOccurrences(of: "SERVICE_ACCOUNT_KEY_EXTENDED_STATUS_", with: ""))") } }
                keys.append(Kept(name: name, serviceAccount: accountName, keyID: parts.last ?? "?", keyType: data?.keyType, keyOrigin: data?.keyOrigin,
                                 created: data?.validAfterTime,
                                 expires: ends.map { Calendar(identifier: .gregorian).component(.year, from: $0) >= 9999 ? "never" : data?.validBeforeTime ?? "?" },
                                 disabled: data?.disabled ?? false, disableReason: data?.disableReason, flags: flags))
            }
            keys.sort { (ServiceAlert.time($0.created) ?? .distantPast) > (ServiceAlert.time($1.created) ?? .distantPast) }
            let system = keys.filter { $0.keyType == "SYSTEM_MANAGED" }, listed = includeSystem ? keys : keys.filter { $0.keyType != "SYSTEM_MANAGED" }
            let user = keys.filter { $0.keyType == "USER_MANAGED" }
            let newUser = user.filter { $0.flags.contains("made in the last \(days) days") }
            var lines: [String] = []
            if listed.isEmpty {
                lines.append("No \(includeSystem ? "" : "user-managed ")service account keys\(account.map { " of \($0)" } ?? "") among the \(listing.read) keys read in \(own).")
            } else {
                lines += listed.prefix(shown).map { key in
                    let warn = key.keyType == "USER_MANAGED" && !key.disabled
                    var line = "\(warn ? "⚠ " : "")\(key.keyType == "USER_MANAGED" ? "user-managed" : key.keyType == "SYSTEM_MANAGED" ? "system-managed" : "unknown type") key \(key.keyID) of \(key.serviceAccount)"
                    line += ", made \(key.created ?? "?"), \(key.expires == "never" ? "never expires" : key.expires.map { "expires \($0)" } ?? "expiry unknown")"
                    line += key.disabled ? ", disabled\(key.disableReason.map { " (\($0.replacingOccurrences(of: "SERVICE_ACCOUNT_KEY_DISABLE_REASON_", with: "").lowercased()))" } ?? "")" : ", enabled"
                    let more = key.flags.filter { $0 != "user-managed" }
                    if !more.isEmpty { line += " — \(more.joined(separator: ", "))" }
                    return line
                }
                if listed.count > shown { lines.append("Showing \(shown) of \(listed.count) keys, newest first; the structured result holds up to \(Self.kept).") }
            }
            lines.append("\(user.count) user-managed, \(newUser.count) made in the last \(days) days and \(user.filter(\.disabled).count) disabled; \(system.count) system-managed, which Google holds and rotates\(includeSystem || system.isEmpty ? "" : ", counted, not listed; set includeSystemManaged to list them").")
            if let shortfall = GoogleCloud.shortfall(listing, "keys") { lines.append(shortfall) }
            lines.append("Cloud Asset's IAM data can lag by up to 7 days, so a key made or deleted lately may not show: audit-logs method CreateServiceAccountKey or UploadServiceAccountKey shows each one made, with its name. When each key was last used is not available: Google gives it only through Policy Analyzer's activity API, which needs a scope this tool does not take.")
            struct Result: Encodable { let keys: [Kept]; let userManaged: Int; let systemManaged: Int; let recent: Int; let read: Int; let more: Bool; let stopped: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Result(keys: Array(listed.prefix(Self.kept)), userManaged: user.count, systemManaged: system.count,
                                                                                      recent: newUser.count, read: listing.read, more: listing.token != nil, stopped: listing.stopped))
        }
    }

    // MARK: Exposure and change

    struct PublicResources: ServiceOperation {
        struct Input: Decodable, Sendable { let assetTypes: [String]? }
        static let name = "public-resources"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Resources whose IAM allow policy grants a role to anyone on the internet (allUsers) or any Google account (allAuthenticatedUsers), across the scope, by resource type, with the role and any condition, saying how many policies it read."
        static let input = JSONSchema.object([
            "assetTypes": .array(.string("An asset type, such as storage.googleapis.com/Bucket or run.googleapis.com/Service."), "Only these types, up to 20. Every type when left out."),
        ])

        static let everyone = ["allUsers", "allAuthenticatedUsers"]
        /// The most public resources the structured result keeps.
        static let kept = 200

        struct Grant: Codable { let role: String?; let members: [String]; let condition: IAMPolicies.Expr? }
        struct Exposed: Codable { let name: String; let assetType: String; let grants: [Grant] }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let types = try (input.assetTypes ?? []).isEmpty ? [] : ServiceInput.list(input.assetTypes ?? [], limit: 20) { try ServiceInput.quoted($0, "the asset type") }
            let listing: Listing<PolicyAsset> = try await GoogleCloud.listAssets(service, scope, content: "IAM_POLICY", types: types, pages: policyPages) { asset in
                asset.iamPolicy?.bindings?.contains { ($0.members ?? []).contains(where: Self.everyone.contains) } ?? false
            }
            let exposed = listing.assets.map { asset in
                Exposed(name: asset.name ?? "?", assetType: asset.assetType ?? "?", grants: (asset.iamPolicy?.bindings ?? []).compactMap { binding in
                    let members = (binding.members ?? []).filter(Self.everyone.contains)
                    return members.isEmpty ? nil : Grant(role: binding.role, members: members, condition: binding.condition)
                })
            }.sorted { ($0.assetType, $0.name) < ($1.assetType, $1.name) }
            var lines: [String] = []
            if exposed.isEmpty {
                lines.append("No IAM allow policy among the \(listing.read) read in \(own)\(types.isEmpty ? "" : " for \(GoogleCloud.listed(types))") grants a role to allUsers or allAuthenticatedUsers.")
            } else {
                let byType = Dictionary(grouping: exposed, by: \.assetType)
                lines.append("\(exposed.count) resources grant a role to allUsers or allAuthenticatedUsers: " + byType.keys.sorted().map { "\(byType[$0]!.count) \($0)" }.joined(separator: ", ") + ".")
                var type = ""
                for resource in exposed.prefix(shown) {
                    if resource.assetType != type { type = resource.assetType; lines.append("\(type):") }
                    lines.append("  \(resource.name): " + resource.grants.map { grant in
                        "\(grant.role ?? "?") to \(grant.members.joined(separator: " and "))" + (grant.condition.map { " only when \($0.title ?? $0.expression ?? "a condition holds")" } ?? "")
                    }.joined(separator: "; "))
                }
                if exposed.count > shown { lines.append("Showing \(shown) of \(exposed.count); the structured result holds up to \(Self.kept).") }
            }
            lines.append("Read \(listing.read) IAM policies in \(own).")
            if let shortfall = GoogleCloud.shortfall(listing, "IAM policies") { lines.append(shortfall) }
            lines.append("These are IAM allow policies only: objects shared through legacy access control lists, public IP addresses, open firewall rules and signed URLs do not show here, and a change made in the last few minutes may not yet. asset-history shows when a grant appeared, audit-logs who made it.")
            struct Kept: Encodable { let resources: [Exposed]; let read: Int; let more: Bool; let stopped: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(resources: Array(exposed.prefix(Self.kept)), read: listing.read,
                                                                                    more: listing.token != nil, stopped: listing.stopped))
        }
    }

    struct AssetHistory: ServiceOperation {
        struct Input: Decodable, Sendable { let assetType: String, since: String, name: String?, content: String? }
        static let name = "asset-history"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "How the IAM policies, or the resources, of one asset type across the scope differ now from how they were at a time up to 35 days ago: what was added, removed and changed, and for IAM policies each role granted and revoked."
        static let input = JSONSchema.object([
            "assetType": .string("The asset type, such as storage.googleapis.com/Bucket or cloudresourcemanager.googleapis.com/Project."),
            "since": .string("The earlier time to compare with now, in ISO 8601, within the last 35 days."),
            "name": .string("Only resources whose full name contains this, such as payroll."),
            "content": .string("What to compare: the IAM policies, or the resources' own settings. IAM policies when left out.", oneOf: ["iamPolicy", "resource"]),
        ], required: ["assetType", "since"])

        /// How far back Cloud Asset keeps its history.
        static let history: TimeInterval = 35 * 86_400

        struct Content: Codable { let data: JSON? }
        struct Snapshot: Codable {
            let name: String?, iamPolicy: Policy?, resource: Content?, updateTime: String?
            enum CodingKeys: String, CodingKey { case name, iamPolicy, resource, updateTime }
            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: CodingKeys.self)
                name = try? fields?.decodeIfPresent(String.self, forKey: .name)
                iamPolicy = try? fields?.decodeIfPresent(Policy.self, forKey: .iamPolicy)
                resource = try? fields?.decodeIfPresent(Content.self, forKey: .resource)
                updateTime = try? fields?.decodeIfPresent(String.self, forKey: .updateTime)
            }
            /// Each role given to each member, with its condition.
            var grants: Set<String> {
                Set((iamPolicy?.bindings ?? []).flatMap { binding in
                    (binding.members ?? []).map { "\(binding.role ?? "?") to \($0)" + (binding.condition.map { " only when \($0.title ?? $0.expression ?? "a condition holds")" } ?? "") }
                })
            }
        }
        struct Change: Codable {
            let name: String, change: String
            var granted: [String] = [], revoked: [String] = [], fields: [String] = [], updateTime: String? = nil
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let type = try ServiceInput.quoted(input.assetType, "the asset type")
            let since = try ServiceInput.time(input.since)
            guard let then = ServiceAlert.time(since), then < Date() else { throw ServiceError.input("Give since as a past time in ISO 8601.") }
            guard then >= Date().addingTimeInterval(-Self.history) else {
                throw ServiceError.input("Cloud Asset keeps 35 days of history: give since within the last 35 days; audit-logs reaches further back for what changed.")
            }
            let policies = try ServiceInput.oneOf(input.content ?? "iamPolicy", ["iamPolicy", "resource"], "content") == "iamPolicy"
            let word = try input.name.map { try ServiceInput.quoted($0, "the name").lowercased() }
            let keep: (Snapshot) -> Bool = { snapshot in word.map { (snapshot.name ?? "").lowercased().contains($0) } ?? true }
            let content = policies ? "IAM_POLICY" : "RESOURCE"
            let before: Listing<Snapshot> = try await GoogleCloud.listAssets(service, scope, content: content, types: [type], readTime: since, pages: historyPages, keep: keep)
            let after: Listing<Snapshot> = try await GoogleCloud.listAssets(service, scope, content: content, types: [type], pages: historyPages, keep: keep)
            func named(_ listing: Listing<Snapshot>) -> [String: Snapshot] {
                Dictionary(listing.assets.compactMap { asset in asset.name.map { ($0, asset) } }, uniquingKeysWith: { first, _ in first })
            }
            let old = named(before), new = named(after)
            // What is missing from one side is added or removed only when both were read whole.
            let complete = before.complete && after.complete
            var changes: [Change] = []
            if complete {
                for name in Set(new.keys).subtracting(old.keys).sorted() {
                    changes.append(Change(name: name, change: "added", granted: policies ? new[name]!.grants.sorted() : [], updateTime: new[name]!.updateTime))
                }
                for name in Set(old.keys).subtracting(new.keys).sorted() {
                    changes.append(Change(name: name, change: "removed", revoked: policies ? old[name]!.grants.sorted() : []))
                }
            }
            for name in Set(old.keys).intersection(new.keys).sorted() {
                let was = old[name]!, now = new[name]!
                if policies {
                    let granted = now.grants.subtracting(was.grants).sorted(), revoked = was.grants.subtracting(now.grants).sorted()
                    if !granted.isEmpty || !revoked.isEmpty { changes.append(Change(name: name, change: "changed", granted: granted, revoked: revoked, updateTime: now.updateTime)) }
                } else if was.resource?.data != now.resource?.data {
                    let fields: [String]
                    if case .object(let a) = was.resource?.data ?? .null, case .object(let b) = now.resource?.data ?? .null {
                        fields = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
                    } else { fields = [] }
                    changes.append(Change(name: name, change: "changed", fields: fields, updateTime: now.updateTime))
                }
            }
            let what = policies ? "IAM policies" : "resources"
            let counts = ["added", "removed", "changed"].map { kind in changes.filter { $0.change == kind }.count }
            var lines = ["Compared the \(what) of \(type)\(word.map { " named with \($0)" } ?? "") in \(own) at \(since) with now: "
                         + (complete ? "\(counts[0]) added, \(counts[1]) removed and \(counts[2]) changed." : "\(counts[2]) changed among the \(Set(old.keys).intersection(new.keys).count) read at both times.")]
            for change in changes.prefix(shown) {
                var line = "\(change.change == "added" ? "+" : change.change == "removed" ? "−" : "~") \(change.name)"
                if !change.granted.isEmpty { line += ": granted " + change.granted.prefix(5).joined(separator: "; ") + (change.granted.count > 5 ? " (+\(change.granted.count - 5) more)" : "") }
                if !change.revoked.isEmpty { line += "\(change.granted.isEmpty ? ":" : ";") revoked " + change.revoked.prefix(5).joined(separator: "; ") + (change.revoked.count > 5 ? " (+\(change.revoked.count - 5) more)" : "") }
                if !change.fields.isEmpty { line += ": \(change.fields.prefix(8).joined(separator: ", ")) changed" + (change.fields.count > 8 ? " (+\(change.fields.count - 8) more)" : "") }
                if let time = change.updateTime { line += " (last updated \(time))" }
                lines.append(line)
            }
            if changes.count > shown { lines.append("Showing \(shown) of \(changes.count) differences, each naming up to 5 grants; the structured result holds all of them.") }
            if !complete {
                let why = [GoogleCloud.shortfall(before, "\(what) at \(since)"), GoogleCloud.shortfall(after, "\(what) now")].compactMap { $0 }
                lines.append("What was added or removed is not established, as not every one was read at both times: " + why.joined(separator: " "))
            }
            lines.append("A change made and undone between the two times does not show here; audit-logs shows each change and who made it. Cloud Asset's snapshot can lag a change by a few minutes\(type.hasPrefix("iam.googleapis.com") ? ", and its IAM data up to 7 days" : "").")
            struct Kept: Encodable { let since: String; let content: String; let complete: Bool; let changes: [Change]; let readThen: Int; let readNow: Int }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(since: since, content: input.content ?? "iamPolicy", complete: complete,
                                                                                    changes: changes, readThen: before.read, readNow: after.read))
        }
    }

    // MARK: Guardrails

    struct OrgPolicies: ServiceOperation {
        struct Input: Decodable, Sendable { let constraint: String?, all: Bool? }
        static let name = "org-policies"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Organisation policies set across the scope, on the organisation, its folders and projects, flagging security constraints loosened, such as service account key creation allowed, public buckets allowed or members of any domain allowed, with when each was last set."
        static let input = JSONSchema.object([
            "constraint": .string("Only this constraint, such as iam.disableServiceAccountKeyCreation."),
            "all": .boolean("List every constraint set, not only the security ones."),
        ])

        /// Constraints that protect when enforced, and what they stop.
        static let protective = [
            "iam.disableServiceAccountKeyCreation": "it stops service account keys being made",
            "iam.managed.disableServiceAccountKeyCreation": "it stops service account keys being made",
            "iam.disableServiceAccountKeyUpload": "it stops keys being uploaded to service accounts",
            "iam.managed.disableServiceAccountKeyUpload": "it stops keys being uploaded to service accounts",
            "iam.automaticIamGrantsForDefaultServiceAccounts": "it stops default service accounts being made Editor",
            "storage.publicAccessPrevention": "it stops buckets being made public",
            "storage.uniformBucketLevelAccess": "it stops objects being shared through their own access lists",
            "compute.requireOsLogin": "it puts SSH to VMs under IAM",
            "compute.managed.requireOsLogin": "it puts SSH to VMs under IAM",
            "compute.skipDefaultNetworkCreation": "it stops the default network, with its open firewall rules, being made",
            "sql.restrictPublicIp": "it stops Cloud SQL instances getting public IPs",
        ]
        /// Constraints that protect by listing what is allowed, and what they limit.
        static let restrictive = [
            "iam.allowedPolicyMemberDomains": "it limits roles to members of the organisation's own domains",
            "compute.vmExternalIpAccess": "it limits which VMs may have external IPs",
            "compute.restrictVpcPeering": "it limits which networks may be peered",
            "gcp.resourceLocations": "it limits where resources may be made",
        ]

        struct BooleanPolicy: Codable { let enforced: Bool? }
        struct ListPolicy: Codable { let allValues: String?, allowedValues: [String]?, deniedValues: [String]?, inheritFromParent: Bool? }
        struct OrgPolicy: Codable {
            let constraint: String?, booleanPolicy: BooleanPolicy?, listPolicy: ListPolicy?, restoreDefault: JSON?, updateTime: String?
            enum CodingKeys: String, CodingKey { case constraint, booleanPolicy, listPolicy, restoreDefault, updateTime }
            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: CodingKeys.self)
                constraint = try? fields?.decodeIfPresent(String.self, forKey: .constraint)
                booleanPolicy = try? fields?.decodeIfPresent(BooleanPolicy.self, forKey: .booleanPolicy)
                listPolicy = try? fields?.decodeIfPresent(ListPolicy.self, forKey: .listPolicy)
                restoreDefault = try? fields?.decodeIfPresent(JSON.self, forKey: .restoreDefault)
                updateTime = try? fields?.decodeIfPresent(String.self, forKey: .updateTime)
            }
        }
        struct Asset: Codable { let name: String?; let orgPolicy: [OrgPolicy]? }
        /// `verdict` is loosened when the rule set says so outright, default when it hands the constraint back to Google's
        /// default, unknown when its rule is in no form read here, and set otherwise.
        struct Judged: Codable {
            let resource: String, constraint: String, state: String, security: Bool, loosened: Bool, verdict: String, updateTime: String?
        }

        /// What a policy sets, and how it leaves a security constraint: loosened only when its rule says so outright, not
        /// enforced or allowing every value; reset to Google's default, which enforces some only for organisations made
        /// lately, told apart from that; and unknown when its rule is in no form read here, rather than taken for not
        /// enforced. A boolean rule without enforced is not enforced: Google leaves a false value out of its answers.
        static func judge(_ policy: OrgPolicy) -> (state: String, security: Bool, verdict: String) {
            let name = (policy.constraint ?? "?").replacingOccurrences(of: "constraints/", with: "")
            let security = protective[name] != nil || restrictive[name] != nil
            if policy.restoreDefault != nil { return ("reset to Google's default", security, security ? "default" : "set") }
            if let list = policy.listPolicy {
                if list.allValues == "ALLOW" { return ("allows every value", security, restrictive[name] != nil ? "loosened" : "set") }
                if list.allValues == "DENY" { return ("denies every value", security, "set") }
                let inherit = list.inheritFromParent == true ? ", merged with its parent's" : ""
                if let allowed = list.allowedValues, !allowed.isEmpty {
                    return ("allows only \(allowed.prefix(5).joined(separator: ", "))\(allowed.count > 5 ? " (+\(allowed.count - 5) more)" : "")\(inherit)", security, "set")
                }
                if let denied = list.deniedValues, !denied.isEmpty {
                    return ("denies \(denied.prefix(5).joined(separator: ", "))\(denied.count > 5 ? " (+\(denied.count - 5) more)" : "")\(inherit)", security, "set")
                }
                return ("set with no values\(inherit)", security, "set")
            }
            guard let boolean = policy.booleanPolicy else { return ("set in a form not read here", security, security ? "unknown" : "set") }
            let enforced = boolean.enforced ?? false
            return (enforced ? "enforced" : "not enforced", security, protective[name] != nil && !enforced ? "loosened" : "set")
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let only = try input.constraint.map { try ServiceInput.quoted($0, "the constraint").replacingOccurrences(of: "constraints/", with: "") }
            let listing: Listing<Asset> = try await GoogleCloud.listAssets(service, scope, content: "ORG_POLICY", pages: policyPages)
            var judged: [Judged] = []
            for asset in listing.assets {
                for policy in asset.orgPolicy ?? [] {
                    let name = (policy.constraint ?? "?").replacingOccurrences(of: "constraints/", with: "")
                    if let only, name != only { continue }
                    let (state, security, verdict) = Self.judge(policy)
                    judged.append(Judged(resource: GoogleCloud.relative(asset.name ?? "?"), constraint: name, state: state, security: security,
                                         loosened: verdict == "loosened", verdict: verdict, updateTime: policy.updateTime))
                }
            }
            // Loosened first, then those whose effect is Google's default or unknown, then the other security ones.
            let rank = { (item: Judged) in item.loosened ? 0 : item.verdict != "set" ? 1 : item.security ? 2 : 3 }
            judged.sort { (rank($0), $0.constraint, $0.resource) < (rank($1), $1.constraint, $1.resource) }
            let listed = input.all == true || only != nil ? judged : judged.filter(\.security)
            let loosened = judged.filter(\.loosened)
            let reset = judged.filter { $0.verdict == "default" }.count, unknown = judged.filter { $0.verdict == "unknown" }.count
            var lines = ["\(listing.read) resources in \(own) have organisation policies set\(only.map { "; \($0) is set on \(judged.count)" } ?? ""): \(judged.filter(\.security).count) set a security constraint, \(loosened.count) leave one loosened"
                         + (reset > 0 ? ", \(reset) reset one to Google's default" : "") + (unknown > 0 ? ", \(unknown) set one in a form not read here" : "") + "."]
            lines += listed.prefix(shown).map { item in
                let why = Self.protective[item.constraint] ?? Self.restrictive[item.constraint]
                let said = switch item.verdict {
                case "loosened": ", loosened"
                case "default": ", so whether it is enforced depends on Google's default for this organisation"
                case "unknown": ", so whether it is enforced is unknown"
                default: ""
                }
                return "\(item.loosened ? "⚠" : item.verdict == "set" ? "·" : "?") \(item.constraint) on \(item.resource): \(item.state)\(said)" + (why.map { " — \($0)" } ?? "")
                    + (item.updateTime.map { " (set \($0))" } ?? "")
            }
            if listed.count > shown { lines.append("Showing \(shown) of \(listed.count), loosened first; the structured result holds all of them.") }
            let others = judged.count - judged.filter(\.security).count
            if input.all != true, only == nil, others > 0 { lines.append("\(others) other constraints are set; set all to list them.") }
            if let shortfall = GoogleCloud.shortfall(listing, "resources with policies") { lines.append(shortfall) }
            lines.append("Each is the policy set on that resource, not the effective one: a resource without its own takes its parent's, and at the top Google's default, which for some security constraints depends on when the organisation was made. Cloud Asset shows policies in Org Policy's first form, so managed and custom constraints and dry runs may not show. audit-logs method SetOrgPolicy or OrgPolicy.UpdatePolicy shows who changed one and when.")
            struct Kept: Encodable { let policies: [Judged]; let loosened: Int; let resetToDefault: Int; let unknown: Int; let read: Int; let more: Bool; let stopped: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(policies: judged, loosened: loosened.count, resetToDefault: reset, unknown: unknown,
                                                                                    read: listing.read, more: listing.token != nil, stopped: listing.stopped))
        }
    }

    struct LoggingCoverage: ServiceOperation {
        struct Input: Decodable, Sendable { let service: String? }
        static let name = "logging-coverage"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Where Data Access audit logging is on across the scope, from the audit configuration in the organisation's, folders' and projects' IAM policies: for a service, such as storage.googleapis.com, whether each project logs data reads, data writes and admin reads, each on, off or unknown and why, with whom it exempts; otherwise every configuration set. Run it before taking no reads found as none."
        static let input = JSONSchema.object([
            "service": .string("The service to check, such as storage.googleapis.com, secretmanager.googleapis.com or iamcredentials.googleapis.com. Every configuration set when left out."),
        ])

        static let types = [organizationType, folderType, projectType]
        /// The audit log types an audit configuration turns on, each judged apart: reads of data, writes of data and
        /// reads of configuration.
        static let logTypes = ["DATA_READ", "DATA_WRITE", "ADMIN_READ"]
        /// Services whose Data Access logs Google writes whatever is set, and cannot be turned off: BigQuery's
        /// (https://docs.cloud.google.com/logging/docs/audit/configure-data-access).
        static let onByDefault: Set<String> = ["bigquery.googleapis.com"]

        /// One project's audit logging for the service asked about, and where it comes from: each log type on, off or
        /// unknown, and `status` on when data reads and writes are both logged, partly on when one is, off when neither
        /// is, and unknown otherwise.
        struct Project: Codable {
            let project: String, status: String
            var types: [String: String] = [:]
            var setOn: [String] = [], exempted: [String] = [], unread: [String] = []
            /// Whether any audit configuration came back on its own policy or one above it, which shows Cloud Asset
            /// gives them for it, so a type set on none of them is off rather than unknown.
            var configured = false
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let wanted = try input.service.map { try ServiceInput.domain($0) }
            let listing: Listing<PolicyAsset> = try await GoogleCloud.listAssets(service, scope, content: "IAM_POLICY", types: Self.types, pages: policyPages)
            // A resource whose policy did not come back is left out, so it counts as unread, never as setting nothing.
            var configs: [String: [AuditConfig]] = [:]
            for asset in listing.assets { if let name = asset.name, let policy = asset.iamPolicy { configs[GoogleCloud.relative(name)] = policy.auditConfigs ?? [] } }
            let projects = listing.assets.filter { $0.assetType == projectType }
            // Projects by ID rather than number, as the other operations name them; numbers when they cannot be listed.
            var ids: [String: String] = [:]
            if scope.level == "projects", projects.count == 1, let name = projects.first?.name { ids[GoogleCloud.relative(name)] = "projects/\(scope.id)" }
            else if !projects.isEmpty, let found = try? await GoogleCloud.hierarchy(service, scope, types: [projectType]) {
                for project in found.containers { ids["projects/\(project.number)"] = project.name }
            }
            let reported = configs.values.contains { !$0.isEmpty }
            var lines: [String] = [], judged: [Project] = []
            if let wanted {
                for asset in projects {
                    let name = GoogleCloud.relative(asset.name ?? "?"), label = ids[name] ?? name
                    var on = Swift.Set<String>(), setOn: [String] = [], exempted = Swift.Set<String>(), unread: [String] = [], configured = false
                    // Audit configuration adds up down the hierarchy: the project's own and every ancestor's apply, and
                    // nothing set on another project says anything of this one.
                    for ancestor in asset.ancestors ?? [name] {
                        guard let set = configs[ancestor] else { unread.append(ancestor); continue }
                        if !set.isEmpty { configured = true }
                        for config in set where config.service == wanted || config.service == "allServices" {
                            for log in config.auditLogConfigs ?? [] {
                                if let type = log.logType { on.insert(type) }
                                exempted.formUnion((log.exemptedMembers ?? []).map { "\($0) (\(log.logType ?? "?"))" })
                            }
                            setOn.append(ids[ancestor] ?? ancestor)
                        }
                    }
                    var types: [String: String] = [:]
                    for type in Self.logTypes {
                        types[type] = on.contains(type) ? "on"
                            : Self.onByDefault.contains(wanted) && type != "ADMIN_READ" ? "on by default"
                            : unread.isEmpty && configured ? "off" : "unknown"
                    }
                    let data = ["DATA_READ", "DATA_WRITE"].map { types[$0] ?? "unknown" }
                    let logged = data.filter { $0.hasPrefix("on") }.count
                    let status = logged == 2 ? "on" : logged == 1 ? "partly on" : data.allSatisfy { $0 == "off" } ? "off" : "unknown"
                    judged.append(Project(project: label, status: status, types: types, setOn: Array(Swift.Set(setOn)).sorted(), exempted: exempted.sorted(),
                                          unread: unread, configured: configured))
                }
                let order = ["off": 0, "partly on": 1, "unknown": 2, "on": 3]
                judged.sort { (order[$0.status] ?? 4, $0.project) < (order[$1.status] ?? 4, $1.project) }
                let count = { (status: String) in judged.filter { $0.status == status }.count }
                lines.append("Audit logging for \(wanted) in the \(judged.count) projects read in \(own): data reads and writes both logged in \(count("on")), only one of them in \(count("partly on")), neither in \(count("off")), unknown in \(count("unknown")).")
                for project in judged.prefix(shown) {
                    let mark = project.status == "off" || project.status == "partly on" ? "⚠ " : ""
                    var line = "\(mark)\(project.status) in \(project.project): " + Self.logTypes.map { "\($0) \(project.types[$0] ?? "unknown")" }.joined(separator: ", ")
                    if !project.setOn.isEmpty { line += "; set on \(GoogleCloud.listed(project.setOn))" }
                    if project.types.values.contains("unknown") {
                        let itself = project.unread.contains { ids[$0] == project.project || $0 == project.project }
                        let above = project.unread.filter { ids[$0] != project.project && $0 != project.project }
                        if itself { line += "; its own IAM policy did not come back" }
                        if !above.isEmpty { line += "; \(GoogleCloud.listed(above)) above it could not be read from this account's scope" }
                        if project.unread.isEmpty, !project.configured { line += "; no audit configuration came back for it or above it, so off cannot be told from left out" }
                    }
                    if !project.exempted.isEmpty { line += "; not logged for \(project.exempted.prefix(5).joined(separator: ", "))" }
                    lines.append(line)
                }
                if judged.count > shown { lines.append("Showing \(shown) of \(judged.count) projects; the structured result holds all of them.") }
                if Self.onByDefault.contains(wanted) {
                    lines.append("BigQuery writes its Data Access logs whether or not they are set here, and they cannot be turned off.")
                }
            } else {
                let set = configs.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
                lines.append(set.isEmpty ? "No Data Access audit logging is set on any of the \(listing.read) IAM policies read in \(own)."
                                         : "Data Access audit logging is set on \(set.count) of the \(listing.read) organisations, folders and projects read in \(own):")
                for (resource, audits) in set.prefix(shown) {
                    lines.append("\(ids[resource] ?? resource): " + audits.map { config in
                        "\(config.service ?? "?") " + (config.auditLogConfigs ?? []).map { log in
                            (log.logType ?? "?") + ((log.exemptedMembers ?? []).isEmpty ? "" : " (not for \((log.exemptedMembers ?? []).prefix(3).joined(separator: ", ")))")
                        }.joined(separator: ", ")
                    }.joined(separator: "; "))
                }
                if set.count > shown { lines.append("Showing \(shown) of \(set.count); the structured result holds all of them.") }
                let missing = listing.assets.filter { $0.iamPolicy == nil }.count
                if missing > 0 { lines.append("\(missing) of them gave no IAM policy, so what is set there is unknown.") }
                lines.append("A project takes what is set on it and on every folder and organisation above it. Give service to see each project's data reads and writes for one.")
            }
            if !reported {
                lines.append("No audit configuration came back on any policy read, so whether Data Access logging is off everywhere, as it is by default for every service but BigQuery, or Cloud Asset left it out is not established: confirm in the console's Audit Logs page (https://console.cloud.google.com/iam-admin/audit).")
            }
            if scope.level != "organizations" { lines.append("What is set above \(own) cannot be read from an account set to it; set the account to the organisation to include it.") }
            if let shortfall = GoogleCloud.shortfall(listing, "IAM policies") { lines.append(shortfall) }
            lines.append("On means entries are written, not that this account can read them: that needs Private Logs Viewer, which check-access tries. Exclusions and sinks can still keep entries out of the buckets searched.")
            struct Configured: Encodable { let resource: String; let auditConfigs: [AuditConfig] }
            struct Kept: Encodable { let service: String?; let projects: [Project]; let configured: [Configured]; let reported: Bool; let read: Int; let more: Bool; let stopped: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                service: wanted, projects: judged,
                configured: configs.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { Configured(resource: ids[$0.key] ?? $0.key, auditConfigs: $0.value) },
                reported: reported, read: listing.read, more: listing.token != nil, stopped: listing.stopped))
        }
    }
}
