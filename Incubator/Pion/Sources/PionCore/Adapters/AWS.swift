import Foundation
import NoodleCore
import NoodleToolConnections

/// AWS, as a defender reads it: who did what in CloudTrail, what GuardDuty, Security Hub and Access Analyzer found,
/// who an access key belongs to, every user's credentials, what instances and open security groups exist, and
/// CloudWatch Logs Insights queries. One connection covers a whole organisation: it signs in through the organisation's
/// IAM Identity Center and takes one read-only role in whichever of its accounts a lookup names.
public enum AWS {
    static let regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "sa-east-1", "eu-west-1", "eu-west-2",
                          "eu-west-3", "eu-central-1", "eu-north-1", "eu-south-1", "ap-south-1", "ap-southeast-1", "ap-southeast-2",
                          "ap-northeast-1", "ap-northeast-2", "me-south-1", "af-south-1"]

    public static let preset = ToolDefinition(
        id: "c2b701c3-9057-41aa-8bda-9b7635180fce", name: "AWS Security",
        summary: "CloudTrail, GuardDuty, Security Hub, IAM, Access Analyzer, EC2 and CloudWatch Logs across an organisation, read-only.",
        defaultInstructions: """
        Use AWS to investigate an organisation's accounts: look up CloudTrail events by user, event name, source, resource or access key; \
        list GuardDuty, Security Hub and IAM Access Analyzer findings; trace an access key to its owner and last use; read \
        the credential report for every user's password, keys and MFA; see who holds which permissions with iam-access, \
        full administrators first; find EC2 instances by ID or IP address and security \
        groups open to the internet; and query CloudWatch Logs Insights, such as VPC Flow Logs. It covers every account the \
        sign-in may use: list them with accounts, and name the account in each lookup, by ID or name, unless there is only \
        one; an access key's own account is found for you. Most services are regional: name another region when the \
        activity may be there. Record each finding as evidence, citing the account, region and time window. These tools \
        only read: recommend disabling a key, isolating an instance or changing a policy to the champion.
        """,
        iconName: "aws",
        configuration: .connection(.init(endpointTemplate: "https://amazonaws.com",
            fields: [ToolField(key: "startURL", title: "AWS access portal URL", placeholder: "https://example.awsapps.com/start", kind: .text),
                     ToolField(key: "role", title: "Role in each account", placeholder: "SecurityAudit", kind: .text),
                     ToolField(key: "region", title: "Default region", placeholder: "us-east-1",
                               kind: .choice(regions.map { .init(value: $0, title: $0) }))],
            signsInWithAWSIdentityCenter: true, adapter: "aws")),
        setup: setup)

    static let setup = [
        "In the **IAM Identity Center** console, open **Permission sets** and create one from the AWS managed policy **SecurityAudit**, AWS's read-only policy for security reviews, named such as `SecurityAudit`.",
        "On that permission set, add an inline policy allowing `logs:StartQuery` and `logs:GetQueryResults` on all resources, for Logs Insights.",
        "Under **AWS accounts**, assign the permission set to whoever signs in to Pion, in every account to investigate; select them all to cover the organisation.",
        "Enter the **AWS access portal URL** from the Identity Center dashboard, and the permission set's name as the role. For the default region, choose the one most activity is in; agents can name any other, and any account.",
        "Choose **Add & Connect**. Your organisation's sign-in page opens with a code: check it matches the one Pion shows, and approve it. Pion stays signed in for as long as your organisation lets a session last, then asks again.",
    ]

    public static let adapter = OperationAdapter(operations: [Accounts(), CloudTrailEvents(), GuardDutyFindings(), SecurityHubFindings(), AccessKey(),
                                                              CredentialReport(), IAMAccess(), AccessAnalyzerFindings(), Instances(), OpenSecurityGroups(),
                                                              LogsInsights()])

    /// The client for one AWS service, as the connection's role in the account named, in the region asked for or the
    /// connection's own.
    static func client(_ service: String, region: String?, account: String?, on client: ServiceClient) async throws -> ServiceClient {
        let region = try region.map(checkedRegion) ?? client.setting("region")
        return try await Self.account(account, on: client).at(host: "\(service).\(region).amazonaws.com")
    }

    /// The client signing as the connection's role in `wanted`, an account named by its ID or name, or in the only
    /// account when the sign-in covers just one.
    static func account(_ wanted: String?, on service: ServiceClient) async throws -> ServiceClient {
        let accounts = try await service.access.awsAccounts()
        let chosen: AWSAccount
        if let wanted = wanted?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            guard let match = accounts.first(where: { $0.id == wanted })
                    ?? accounts.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ServiceError.input("The sign-in has no account \(wanted). Its accounts: \(listing(accounts)).")
            }
            chosen = match
        } else {
            guard accounts.count == 1 else {
                throw ServiceError.input(accounts.isEmpty ? "The sign-in covers no AWS accounts." : "Name the account: \(listing(accounts)).")
            }
            chosen = accounts[0]
        }
        // AWS says why it turns a request down, such as Security Hub not being enabled or the role lacking a permission.
        return ServiceClient(base: service.base, access: try await service.access.access(asAWSAccount: chosen.id), settings: service.settings,
                             explainsRefusals: true)
    }

    static func listing(_ accounts: [AWSAccount]) -> String {
        accounts.prefix(20).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
            + (accounts.count > 20 ? ", and \(accounts.count - 20) more" : "")
    }

    static func checkedRegion(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard (1...32).contains(value.count), value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains) else {
            throw ServiceError.input("Give a region such as eu-west-1.")
        }
        return value
    }

    /// Seconds since 1970, as AWS's JSON APIs take times.
    static func seconds(_ time: String) throws -> Int {
        let plain = ISO8601DateFormatter(), precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let checked = try ServiceInput.time(time)
        guard let date = plain.date(from: checked) ?? precise.date(from: checked) else { throw ServiceError.input("Give times in ISO 8601.") }
        return Int(date.timeIntervalSince1970)
    }

    static func limit(_ value: Int?, default fallback: Int, maximum: Int) throws -> Int {
        let limit = value ?? fallback
        guard (1...maximum).contains(limit) else { throw ServiceError.input("Ask for between 1 and \(maximum).") }
        return limit
    }

    /// The region a regional operation may name.
    static let regionInput = JSONSchema.string("The region, when not the connection's default, such as us-east-1.")
    /// The account every operation may name.
    static let accountInput = JSONSchema.string("The account, by its 12-digit ID or its name, as accounts lists them. Needed unless the sign-in covers only one.")
}

extension AWS {
    struct Accounts: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "accounts"
        static let summary = "Every AWS account the sign-in covers, with its ID, name and email. Other lookups name one of them."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let accounts = try await service.access.awsAccounts()
            struct Account: Encodable { let id: String, name: String, email: String? }
            struct Listed: Encodable { let accounts: [Account] }
            let text = accounts.isEmpty ? "The sign-in covers no AWS accounts." : "\(accounts.count) accounts:\n" + accounts.map { account in
                "\(account.name) (\(account.id))" + (account.email.map { " — \($0)" } ?? "")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Listed(accounts: accounts.map { Account(id: $0.id, name: $0.name, email: $0.email) }))
        }
    }

    struct CloudTrailEvents: ServiceOperation {
        struct Input: Decodable, Sendable {
            let user: String?, eventName: String?, eventSource: String?, resource: String?, accessKeyId: String?
            let since: String?, until: String?, limit: Int?, region: String?, account: String?
        }
        static let name = "cloudtrail-events"
        static let summary = "CloudTrail management events, newest first, by one of user, event name, event source, resource or access key, with source IP, agent and error."
        static let input = JSONSchema.object([
            "user": .string("The IAM user or role session name."), "eventName": .string("An API call, such as ConsoleLogin or CreateAccessKey."),
            "eventSource": .string("A service, such as iam.amazonaws.com."), "resource": .string("A resource's name or ARN."),
            "accessKeyId": .string("The access key used."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out; CloudTrail keeps 90."),
            "until": .string("The latest time, in ISO 8601."), "limit": .integer("How many events, at most.", minimum: 1, maximum: 50),
            "region": AWS.regionInput, "account": AWS.accountInput,
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let attributes = [("Username", input.user), ("EventName", input.eventName), ("EventSource", input.eventSource),
                              ("ResourceName", input.resource), ("AccessKeyId", input.accessKeyId)]
                .compactMap { key, value in value.map { (key, $0) } }
            guard attributes.count <= 1 else { throw ServiceError.input("CloudTrail looks events up by one of user, event name, source, resource or access key at a time.") }
            struct Attribute: Encodable { let AttributeKey: String; let AttributeValue: String }
            struct Body: Encodable { let LookupAttributes: [Attribute]?; let StartTime: Int; let EndTime: Int?; let MaxResults: Int }
            let body = Body(LookupAttributes: try attributes.isEmpty ? nil : attributes.map { Attribute(AttributeKey: $0.0, AttributeValue: try ServiceInput.quoted($0.1, "the value")) },
                            StartTime: try AWS.seconds(input.since ?? ServiceInput.daysAgo(7)), EndTime: try input.until.map(AWS.seconds),
                            MaxResults: try AWS.limit(input.limit, default: 50, maximum: 50))
            struct Resource: Codable { let ResourceType: String?; let ResourceName: String? }
            struct Event: Decodable { let EventId: String?, EventName: String?, EventTime: Double?, EventSource: String?, Username: String?, Resources: [Resource]?, CloudTrailEvent: String? }
            struct Answer: Decodable { let Events: [Event]? }
            struct Detail: Decodable { let sourceIPAddress: String?, userAgent: String?, awsRegion: String?, errorCode: String?, errorMessage: String? }
            struct Kept: Encodable {
                let id: String?, time: String?, name: String?, source: String?, user: String?, ip: String?, userAgent: String?
                let region: String?, error: String?, resources: [Resource]
            }
            struct Events: Encodable { let events: [Kept] }
            let answer = try await AWS.client("cloudtrail", region: input.region, account: input.account, on: service).post([], body: body,
                headers: ["X-Amz-Target": "com.amazonaws.cloudtrail.v20131101.CloudTrail_20131101.LookupEvents"],
                contentType: "application/x-amz-json-1.1", as: Answer.self)
            let events = (answer.Events ?? []).map { event in
                let detail = event.CloudTrailEvent.flatMap { try? JSONDecoder().decode(Detail.self, from: Data($0.utf8)) }
                return Kept(id: event.EventId, time: event.EventTime.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) },
                            name: event.EventName, source: event.EventSource, user: event.Username, ip: detail?.sourceIPAddress,
                            userAgent: detail?.userAgent, region: detail?.awsRegion, error: detail?.errorCode, resources: event.Resources ?? [])
            }
            let text = events.isEmpty ? "No CloudTrail events match." : events.prefix(30).map { event in
                var line = "\(event.time ?? "?") \(event.name ?? "?")"
                if let user = event.user { line += " by \(user)" }
                if let ip = event.ip { line += " from \(ip)" }
                if let error = event.error { line += " — \(error)" }
                let names = event.resources.compactMap(\.ResourceName)
                if !names.isEmpty { line += " on \(names.prefix(3).joined(separator: ", "))" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Events(events: events))
        }
    }

    struct GuardDutyFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let minimumSeverity: Double?, limit: Int?, region: String?, account: String? }
        static let name = "guardduty-findings"
        static let summary = "GuardDuty findings, most recently updated first, from a minimum severity, with the resource and identity each concerns."
        static let input = JSONSchema.object([
            "minimumSeverity": .integer("The lowest severity, from 1 to 8; 7 and above is high. 4 when left out.", minimum: 1, maximum: 8),
            "limit": .integer("How many findings, at most.", minimum: 1, maximum: 50), "region": AWS.regionInput, "account": AWS.accountInput,
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let client = try await AWS.client("guardduty", region: input.region, account: input.account, on: service)
            struct Detectors: Decodable { let detectorIds: [String]? }
            guard let detector = try await client.get(["detector"], as: Detectors.self).detectorIds?.first else {
                return try ServiceResult(text: "GuardDuty is not enabled in this region.", structured: ["findings": [String]()])
            }
            let severity = Int(input.minimumSeverity ?? 4)
            guard (1...8).contains(severity) else { throw ServiceError.input("Give a severity from 1 to 8.") }
            struct Query: Encodable {
                struct Criteria: Encodable { let criterion: [String: [String: Int]] }
                struct Sort: Encodable { let attributeName: String; let orderBy: String }
                let findingCriteria: Criteria; let maxResults: Int; let sortCriteria: Sort
            }
            struct IDs: Decodable { let findingIds: [String]? }
            let ids = try await client.post(["detector", detector, "findings"], body: Query(
                findingCriteria: .init(criterion: ["severity": ["greaterThanOrEqual": severity]]),
                maxResults: try AWS.limit(input.limit, default: 25, maximum: 50), sortCriteria: .init(attributeName: "updatedAt", orderBy: "DESC")),
                as: IDs.self).findingIds ?? []
            struct Key: Codable { let userName: String?; let accessKeyId: String? }
            struct InstanceDetails: Codable { let instanceId: String? }
            struct Resource: Codable { let resourceType: String?; let accessKeyDetails: Key?; let instanceDetails: InstanceDetails? }
            struct Finding: Codable { let id: String, type: String?, severity: Double?, title: String?, updatedAt: String?, resource: Resource? }
            struct Found: Codable { let findings: [Finding]? }
            struct Get: Encodable { let findingIds: [String] }
            let findings = ids.isEmpty ? [] : try await client.post(["detector", detector, "findings", "get"], body: Get(findingIds: ids), as: Found.self).findings ?? []
            let text = findings.isEmpty ? "No GuardDuty findings at severity \(severity) or above." : findings.map { finding in
                var line = "\(finding.updatedAt ?? "?") severity \(finding.severity.map { String(format: "%.1f", $0) } ?? "?") \(finding.type ?? "?"): \(finding.title ?? finding.id)"
                if let key = finding.resource?.accessKeyDetails { line += " — \(key.userName ?? "?") (\(key.accessKeyId ?? "?"))" }
                if let instance = finding.resource?.instanceDetails?.instanceId { line += " — \(instance)" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Found(findings: findings))
        }
    }

    struct SecurityHubFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let severities: [String]?, limit: Int?, region: String?, account: String? }
        static let name = "securityhub-findings"
        static let summary = "Active Security Hub findings, most recently updated first, by severity, with the product and resources."
        static let input = JSONSchema.object([
            "severities": .array(.string("A severity.", oneOf: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"]), "Severities. Critical and high when left out."),
            "limit": .integer("How many findings, at most.", minimum: 1, maximum: 100), "region": AWS.regionInput, "account": AWS.accountInput,
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let severities = try (input.severities ?? ["CRITICAL", "HIGH"]).map { try ServiceInput.oneOf($0, ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"], "severity") }
            struct Filter: Encodable { let Value: String; let Comparison = "EQUALS" }
            struct Sort: Encodable { let Field: String; let SortOrder: String }
            struct Body: Encodable { let Filters: [String: [Filter]]; let MaxResults: Int; let SortCriteria: [Sort] }
            let body = Body(Filters: ["RecordState": [Filter(Value: "ACTIVE")], "SeverityLabel": severities.map { Filter(Value: $0) }],
                            MaxResults: try AWS.limit(input.limit, default: 25, maximum: 100), SortCriteria: [Sort(Field: "UpdatedAt", SortOrder: "desc")])
            struct Severity: Codable { let Label: String? }
            struct Resource: Codable { let `Type`: String?; let Id: String? }
            struct Finding: Codable { let Id: String, Title: String?, Severity: Severity?, ProductName: String?, UpdatedAt: String?, Resources: [Resource]? }
            struct Found: Codable { let Findings: [Finding]? }
            let findings = try await AWS.client("securityhub", region: input.region, account: input.account, on: service).post(["findings"], body: body, as: Found.self).Findings ?? []
            let text = findings.isEmpty ? "No active Security Hub findings match." : findings.map { finding in
                "\(finding.UpdatedAt ?? "?") \(finding.Severity?.Label ?? "?") \(finding.Title ?? finding.Id)\(finding.ProductName.map { " (\($0))" } ?? "")"
                    + ((finding.Resources ?? []).compactMap(\.Id).first.map { " — \($0)" } ?? "")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Found(Findings: findings))
        }
    }

    struct AccessKey: ServiceOperation {
        struct Input: Decodable, Sendable { let accessKeyId: String, account: String? }
        static let name = "access-key"
        static let summary = "Which account and user an access key belongs to, and when, where and with which service it was last used."
        static let input = JSONSchema.object(["accessKeyId": .string("The access key ID, such as AKIA… or ASIA…."),
                                              "account": .string("The account the key is in, by ID or name. Found from the key when left out.")],
                                             required: ["accessKeyId"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let key = input.accessKeyId.trimmingCharacters(in: .whitespaces)
            guard (16...128).contains(key.count), key.allSatisfy({ $0.isLetter && $0.isUppercase || $0.isNumber }) else {
                throw ServiceError.input("Give an access key ID such as AKIAIOSFODNN7EXAMPLE.")
            }
            // A key's account is found from the key itself, which STS answers for anyone, so a key from anywhere in the
            // organisation is traced to its own account.
            var account = input.account
            if account?.trimmingCharacters(in: .whitespaces).isEmpty != false, try await service.access.awsAccounts().count > 1 {
                let first = try await AWS.account(try await service.access.awsAccounts().first?.id, on: service)
                let info = try await first.at(host: "sts.amazonaws.com").xml([], query: ["Action": "GetAccessKeyInfo", "Version": "2011-06-15", "AccessKeyId": key])
                guard let owner = info.value("GetAccessKeyInfoResult", "Account") else { throw ServiceError.unreadable }
                guard try await service.access.awsAccounts().contains(where: { $0.id == owner }) else {
                    return try ServiceResult(text: "\(key) belongs to account \(owner), which the sign-in does not cover.",
                                             structured: ["accessKeyId": key, "account": owner])
                }
                account = owner
            }
            let answer = try await AWS.account(account, on: service).at(host: "iam.amazonaws.com")
                .xml([], query: ["Action": "GetAccessKeyLastUsed", "Version": "2010-05-08", "AccessKeyId": key])
            let result = answer.child("GetAccessKeyLastUsedResult")
            struct Use: Encodable { let accessKeyId: String, user: String?, lastUsed: String?, service: String?, region: String? }
            let use = Use(accessKeyId: key, user: result?.value("UserName"), lastUsed: result?.value("AccessKeyLastUsed", "LastUsedDate"),
                          service: result?.value("AccessKeyLastUsed", "ServiceName"), region: result?.value("AccessKeyLastUsed", "Region"))
            var text = "\(key) belongs to \(use.user ?? "an unknown user")"
            if let last = use.lastUsed { text += ", last used \(last) with \(use.service ?? "?") in \(use.region ?? "?")." } else { text += ", never used." }
            return try ServiceResult(text: text, structured: use)
        }
    }

    struct CredentialReport: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String? }
        static let name = "credential-report"
        static let summary = "Every IAM user's password and access key use, key ages and whether MFA is on, from the account's credential report."
        static let input = JSONSchema.object(["account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.account(input.account, on: service).at(host: "iam.amazonaws.com")
            // The report is made on request, usually in seconds.
            for attempt in 0..<6 {
                let state = try await iam.xml([], query: ["Action": "GenerateCredentialReport", "Version": "2010-05-08"])
                if state.value("GenerateCredentialReportResult", "State") == "COMPLETE" { break }
                if attempt == 5 { throw ServiceError.refused("the credential report is still being made; try again shortly") }
                try await Task.sleep(for: .seconds(2))
            }
            let report = try await iam.xml([], query: ["Action": "GetCredentialReport", "Version": "2010-05-08"])
            guard let content = report.value("GetCredentialReportResult", "Content"), let data = Data(base64Encoded: content),
                  let csv = String(data: data, encoding: .utf8) else { throw ServiceError.unreadable }
            let lines = csv.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            guard let columns = lines.first else { throw ServiceError.unreadable }
            return try ServiceTable(columns: columns, rows: lines.dropFirst().map { $0.map { CellValue.text($0) } }).result()
        }
    }

    /// Who holds which permissions in an account, from IAM's authorization details, which SecurityAudit may read: each
    /// user with what reaches it through its groups, and each role, with full administrators first. A full administrator
    /// holds AdministratorAccess, or any policy that allows every action on every resource.
    struct IAMAccess: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String? }
        static let name = "iam-access"
        static let summary = "Who holds which permissions in an account: each IAM user, with its groups' policies, and each role, with full administrators first."
        static let input = JSONSchema.object(["account": AWS.accountInput])

        struct Principal: Encodable {
            let kind: String, name: String, arn: String?
            let policies: [String]
            let fullAdministrator: Bool
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.account(input.account, on: service).at(host: "iam.amazonaws.com")
            var users: [XMLNode] = [], groups: [XMLNode] = [], roles: [XMLNode] = [], managed: [XMLNode] = []
            var marker: String?
            // An account answers in pages; a few cover any but the largest.
            for _ in 0..<20 {
                var query: [String: String?] = ["Action": "GetAccountAuthorizationDetails", "Version": "2010-05-08", "MaxItems": "1000",
                                                "Filter.member.1": "User", "Filter.member.2": "Group", "Filter.member.3": "Role",
                                                "Filter.member.4": "LocalManagedPolicy"]
                if let marker { query["Marker"] = marker }
                let page = try await iam.xml([], query: query)
                guard let result = page.child("GetAccountAuthorizationDetailsResult") else { throw ServiceError.unreadable }
                users += result.child("UserDetailList")?.children ?? []
                groups += result.child("GroupDetailList")?.children ?? []
                roles += result.child("RoleDetailList")?.children ?? []
                managed += result.child("Policies")?.children ?? []
                guard result.value("IsTruncated") == "true", let next = result.value("Marker") else { marker = nil; break }
                marker = next
            }
            // A customer managed policy grants what its default version says.
            let allowsEverything: [String: Bool] = Dictionary(managed.compactMap { policy in
                let document = policy.child("PolicyVersionList")?.children.first { $0.value("IsDefaultVersion") == "true" }?.value("Document")
                return policy.value("Arn").map { ($0, document.map(Self.allowsEverything) ?? false) }
            }, uniquingKeysWith: { first, _ in first })
            func attached(_ node: XMLNode) -> [(name: String, everything: Bool)] {
                (node.child("AttachedManagedPolicies")?.children ?? []).compactMap { policy in
                    guard let name = policy.value("PolicyName") else { return nil }
                    let arn = policy.value("PolicyArn") ?? ""
                    return (name, arn.hasSuffix(":policy/AdministratorAccess") || allowsEverything[arn] == true)
                }
            }
            func inline(_ node: XMLNode, _ list: String) -> [(name: String, everything: Bool)] {
                (node.child(list)?.children ?? []).compactMap { policy in
                    policy.value("PolicyName").map { ("\($0) (inline)", policy.value("PolicyDocument").map(Self.allowsEverything) ?? false) }
                }
            }
            let groupPolicies = Dictionary(groups.compactMap { group in
                group.value("GroupName").map { ($0, attached(group) + inline(group, "GroupPolicyList")) }
            }, uniquingKeysWith: { first, _ in first })
            var principals = users.compactMap { user -> Principal? in
                guard let name = user.value("UserName") else { return nil }
                let through = (user.child("GroupList")?.children ?? []).compactMap { $0.text.isEmpty ? nil : $0.text }.flatMap { group in
                    (groupPolicies[group] ?? []).map { ("\($0.name) (through group \(group))", $0.everything) }
                }
                let held = attached(user) + inline(user, "UserPolicyList") + through
                return Principal(kind: "user", name: name, arn: user.value("Arn"), policies: held.map(\.name), fullAdministrator: held.contains { $0.everything })
            }
            principals += roles.compactMap { role in
                guard let name = role.value("RoleName") else { return nil }
                let held = attached(role) + inline(role, "RolePolicyList")
                return Principal(kind: "role", name: name, arn: role.value("Arn"), policies: held.map(\.name), fullAdministrator: held.contains { $0.everything })
            }
            let admins = principals.filter(\.fullAdministrator), others = principals.filter { !$0.fullAdministrator }
            func line(_ principal: Principal) -> String {
                "\(principal.kind) \(principal.name): \(principal.policies.isEmpty ? "no policies" : principal.policies.joined(separator: ", "))"
            }
            var text = ["Full administrators (\(admins.count)):"] + admins.map { "- " + line($0) }
            text += ["Everyone else (\(others.count)):"] + others.prefix(100).map { "- " + line($0) }
            if others.count > 100 { text.append("\(others.count - 100) more; read them from the structured result.") }
            struct Kept: Encodable { let principals: [Principal] }
            return try ServiceResult(text: text.joined(separator: "\n"), structured: Kept(principals: admins + others))
        }

        /// Whether a policy document, as IAM gives it URL-encoded, allows every action on every resource.
        static func allowsEverything(_ encoded: String) -> Bool {
            guard let json = encoded.removingPercentEncoding,
                  let document = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
            let statements = (document["Statement"] as? [[String: Any]]) ?? (document["Statement"] as? [String: Any]).map { [$0] } ?? []
            func values(_ value: Any?) -> [String] { (value as? [String]) ?? (value as? String).map { [$0] } ?? [] }
            return statements.contains { statement in
                statement["Effect"] as? String == "Allow" && values(statement["Action"]).contains { $0 == "*" || $0 == "*:*" }
                    && values(statement["Resource"]).contains("*")
            }
        }
    }

    struct AccessAnalyzerFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let limit: Int?, region: String?, account: String? }
        static let name = "access-analyzer-findings"
        static let summary = "Active IAM Access Analyzer findings: resources shared outside the account, and whether publicly."
        static let input = JSONSchema.object(["limit": .integer("How many findings, at most.", minimum: 1, maximum: 100), "region": AWS.regionInput, "account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let client = try await AWS.client("access-analyzer", region: input.region, account: input.account, on: service)
            struct Analyzer: Decodable { let arn: String; let status: String? }
            struct Analyzers: Decodable { let analyzers: [Analyzer]? }
            guard let analyzer = try await client.get(["analyzer"], as: Analyzers.self).analyzers?.first(where: { $0.status != "DISABLED" }) else {
                return try ServiceResult(text: "No IAM Access Analyzer analyzer exists in this region.", structured: ["findings": [String]()])
            }
            struct Body: Encodable { let analyzerArn: String; let filter: [String: [String: [String]]]; let maxResults: Int }
            struct Finding: Codable { let id: String, resource: String?, resourceType: String?, isPublic: Bool?, status: String?, action: [String]?, updatedAt: String? }
            struct Found: Codable { let findings: [Finding]? }
            let findings = try await client.post(["finding"], body: Body(analyzerArn: analyzer.arn, filter: ["status": ["eq": ["ACTIVE"]]],
                                                                         maxResults: try AWS.limit(input.limit, default: 50, maximum: 100)), as: Found.self).findings ?? []
            let text = findings.isEmpty ? "Access Analyzer finds nothing shared outside the account." : findings.map { finding in
                "\(finding.resource ?? finding.id) is \(finding.isPublic == true ? "public" : "shared outside the account")\((finding.action ?? []).isEmpty ? "" : " for \((finding.action ?? []).prefix(4).joined(separator: ", "))")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Found(findings: findings))
        }
    }

    struct Instances: ServiceOperation {
        struct Input: Decodable, Sendable { let instanceId: String?, ip: String?, region: String?, account: String? }
        static let name = "ec2-instances"
        static let summary = "EC2 instances by instance ID or public or private IP address, with their state, addresses, security groups and Name tag."
        static let input = JSONSchema.object(["instanceId": .string("The instance ID, such as i-0abc…."),
                                              "ip": .string("A public or private IPv4 address."), "region": AWS.regionInput, "account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["Action": "DescribeInstances", "Version": "2016-11-15"]
            if let id = input.instanceId {
                guard id.hasPrefix("i-"), id.count <= 32, id.dropFirst(2).allSatisfy(\.isHexDigit) else { throw ServiceError.input("Give an instance ID such as i-0abc123.") }
                query["InstanceId.1"] = id
            } else if let ip = input.ip {
                let ip = try ServiceInput.ip(ip)
                let isPrivate = ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0))
                query["Filter.1.Name"] = isPrivate ? "private-ip-address" : "ip-address"
                query["Filter.1.Value.1"] = ip
            } else { throw ServiceError.input("Give an instance ID or an IP address.") }
            let answer = try await AWS.client("ec2", region: input.region, account: input.account, on: service).xml([], query: query)
            struct Instance: Encodable { let id: String?, name: String?, type: String?, state: String?, privateIP: String?, publicIP: String?, launched: String?, securityGroups: [String] }
            struct Found: Encodable { let instances: [Instance] }
            let instances = answer.all("instancesSet").flatMap { $0.children }.map { item in
                Instance(id: item.value("instanceId"), name: item.child("tagSet")?.children.first { $0.value("key") == "Name" }?.value("value"),
                         type: item.value("instanceType"), state: item.value("instanceState", "name"), privateIP: item.value("privateIpAddress"),
                         publicIP: item.value("ipAddress"), launched: item.value("launchTime"),
                         securityGroups: item.child("groupSet")?.children.compactMap { $0.value("groupId") } ?? [])
            }
            let text = instances.isEmpty ? "No instance matches." : instances.map { instance in
                "\(instance.id ?? "?")\(instance.name.map { " (\($0))" } ?? ""): \(instance.state ?? "?"), \(instance.type ?? "?"), \([instance.privateIP, instance.publicIP].compactMap { $0 }.joined(separator: " / ")), groups \(instance.securityGroups.joined(separator: ", ")), launched \(instance.launched ?? "?")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Found(instances: instances))
        }
    }

    struct OpenSecurityGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let region: String?, account: String? }
        static let name = "open-security-groups"
        static let summary = "Security groups that let anyone on the internet in, with the ports they open."
        static let input = JSONSchema.object(["region": AWS.regionInput, "account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let answer = try await AWS.client("ec2", region: input.region, account: input.account, on: service).xml([], query: [
                "Action": "DescribeSecurityGroups", "Version": "2016-11-15", "Filter.1.Name": "ip-permission.cidr", "Filter.1.Value.1": "0.0.0.0/0",
            ])
            struct Rule: Encodable { let protocolName: String, ports: String, from: String }
            struct Group: Encodable { let id: String?, name: String?, vpc: String?, open: [Rule] }
            struct Found: Encodable { let groups: [Group] }
            let groups = (answer.child("securityGroupInfo")?.children ?? []).map { item in
                Group(id: item.value("groupId"), name: item.value("groupName"), vpc: item.value("vpcId"),
                      open: (item.child("ipPermissions")?.children ?? []).flatMap { permission in
                          (permission.child("ipRanges")?.children ?? []).compactMap { $0.value("cidrIp") }.filter { $0 == "0.0.0.0/0" }.map { cidr in
                              let from = permission.value("fromPort") ?? "all", to = permission.value("toPort") ?? from
                              let name = permission.value("ipProtocol") ?? "?"
                              return Rule(protocolName: name == "-1" ? "all" : name, ports: from == to ? from : "\(from)-\(to)", from: cidr)
                          }
                      })
            }
            let text = groups.isEmpty ? "No security group lets the whole internet in." : groups.map { group in
                "\(group.id ?? "?") (\(group.name ?? "?")): " + group.open.map { "\($0.protocolName) \($0.ports) from \($0.from)" }.joined(separator: ", ")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Found(groups: groups))
        }
    }

    struct LogsInsights: ServiceOperation {
        struct Input: Decodable, Sendable { let logGroups: [String], query: String, since: String?, until: String?, region: String?, account: String? }
        static let name = "logs-insights"
        static let summary = "Run a CloudWatch Logs Insights query over log groups, such as VPC Flow Logs or CloudTrail delivered to CloudWatch. Read-only."
        static let input = JSONSchema.object([
            "logGroups": .array(.string("A log group name."), "Up to 10 log groups."),
            "query": .string("The Logs Insights query, ending with limit."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601. Now when left out."), "region": AWS.regionInput, "account": AWS.accountInput,
        ], required: ["logGroups", "query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let groups = try ServiceInput.list(input.logGroups, limit: 10) { try ServiceInput.quoted($0, "the log group") }
            let client = try await AWS.client("logs", region: input.region, account: input.account, on: service)
            struct Start: Encodable { let logGroupNames: [String], queryString: String, startTime: Int, endTime: Int, limit: Int }
            struct Started: Decodable { let queryId: String }
            let started = try await client.post([], body: Start(
                logGroupNames: groups, queryString: try ServiceInput.query(input.query),
                startTime: try AWS.seconds(input.since ?? ServiceInput.daysAgo(1)),
                endTime: try input.until.map(AWS.seconds) ?? Int(Date().timeIntervalSince1970), limit: 100),
                headers: ["X-Amz-Target": "Logs_20140328.StartQuery"], contentType: "application/x-amz-json-1.1", as: Started.self)
            struct Field: Decodable { let field: String; let value: String? }
            struct Results: Decodable { let status: String?; let results: [[Field]]? }
            struct Get: Encodable { let queryId: String }
            // Queries run on AWS; their results are read until they finish, for up to half a minute.
            for _ in 0..<30 {
                let results = try await client.post([], body: Get(queryId: started.queryId), headers: ["X-Amz-Target": "Logs_20140328.GetQueryResults"],
                                                    contentType: "application/x-amz-json-1.1", as: Results.self)
                switch results.status {
                case "Complete":
                    let rows = results.results ?? []
                    var columns: [String] = []
                    for field in rows.flatMap({ $0 }).map(\.field) where !field.hasPrefix("@ptr") && !columns.contains(field) { columns.append(field) }
                    return try ServiceTable(columns: columns, rows: rows.map { row in
                        columns.map { column in row.first { $0.field == column }?.value.map(CellValue.text) ?? .none }
                    }).result()
                case "Failed", "Cancelled", "Timeout": throw ServiceError.refused("the query \(results.status!.lowercased())")
                default: try await Task.sleep(for: .seconds(1))
                }
            }
            throw ServiceError.refused("the query is still running; narrow it with a shorter time range or a limit")
        }
    }
}
