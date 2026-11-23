import CryptoKit
import Foundation
import NoodleCore
import NoodleToolConnections

/// AWS, as a defender reads it: who did what in CloudTrail, what GuardDuty, Security Hub and Access Analyzer found,
/// who an access key belongs to, every user's credentials, what instances and open security groups exist, and
/// CloudWatch Logs Insights queries. One connection covers a whole organisation: it signs in through the organisation's
/// IAM Identity Center and takes one read-only role in whichever of its accounts a lookup names. AWS Audit only reads;
/// AWS Containment, a tool of its own with a permission set of its own, acts.
public enum AWS {
    static let regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "sa-east-1", "eu-west-1", "eu-west-2",
                          "eu-west-3", "eu-central-1", "eu-north-1", "eu-south-1", "ap-south-1", "ap-southeast-1", "ap-southeast-2",
                          "ap-northeast-1", "ap-northeast-2", "me-south-1", "af-south-1"]

    public static let preset = ToolDefinition(
        id: "c2b701c3-9057-41aa-8bda-9b7635180fce", name: "AWS Audit",
        summary: "CloudTrail, GuardDuty, Security Hub, IAM and Identity Center, Access Analyzer, AWS Config, S3, EC2, Inspector, Macie and CloudWatch Logs across an organisation, read-only, with an alert watch.",
        defaultInstructions: """
        Use AWS Audit to investigate an organisation's accounts: cloudtrail-events looks up CloudTrail events by user, \
        event name, source, resource or access key, with who acted (root, an IAM user or an assumed role and its \
        issuer), from where, whether MFA was used and any error; guardduty-findings, securityhub-findings and \
        access-analyzer-findings list what those services found, each finding with its own account and region; \
        access-key traces a key to its account, owner and last use; credential-report lists every user's password, \
        keys and MFA, and credential-hygiene picks out root's, users without MFA and stale keys and passwords; \
        iam-access says who holds which permissions, full administrators first, who could make themselves one and \
        which roles anyone, outside accounts or any GitHub repository could assume; identity-center-assignments says \
        who holds which permission set in which account, read from the management account; config-history shows how \
        a resource's configuration changed and who changed it; s3-exposure says which buckets are public or shared \
        and why; ec2-instances and open-security-groups find instances and groups open to the internet over IPv4 or \
        IPv6; inspector-findings and macie-findings list vulnerabilities and sensitive data found; logs-insights \
        queries CloudWatch Logs, such as VPC Flow Logs; regions lists the regions an account has turned on. It covers every \
        account the sign-in may use: list them with accounts, and name the account in each lookup, by ID or name, \
        unless there is only one. Most services are regional and each lookup reads one region, the connection's own \
        unless named: name another when activity may be there. IAM, STS, Organizations and console sign-ins are logged \
        in us-east-1, which cloudtrail-events also reads unless a region is named. The alert watch checks every five \
        minutes and wakes you with a note naming security-events, which reads what it reads for the note's window: \
        high and critical GuardDuty and Security Hub findings that are not archived, suppressed or resolved, and \
        CloudTrail changes that open the way in or hide what follows: root activity, console sign-ins without MFA, \
        users, passwords and access keys made, administrator policies granted, role trust opened, MFA removed, logging \
        or detection turned off, buckets, snapshots and security groups opened to the internet, KMS keys disabled and \
        commands run on instances. A note may name a feed the watch could not read or a service that is off, such as \
        GuardDuty with no detector; security-events says which and why, so tell the champion what to change and treat \
        that feed's silence as unknown. When a tool is refused or something you need seems missing, run check-access \
        and tell the champion exactly what it says to change. Silence is not proof: every result names the account and \
        region it read, and says when it stopped before reading everything or matched more than it kept; report those \
        gaps with what you found. Record each finding as evidence, citing the account, region and time window. These \
        tools only read: recommend changes to the champion, or use AWS Containment.
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
        "In the **IAM Identity Center** console, open **Permission sets** and create one from the AWS managed policy **SecurityAudit**, AWS's read-only policy for security reviews, named such as `SecurityAudit`. Set its session duration to an hour or so.",
        "On that permission set, add this inline policy, for reads SecurityAudit may leave out: Logs Insights queries, IAM's policy simulator, so iam-access and check-access can tell what a role could do, AWS Config's history, S3's bucket settings, IAM Identity Center's assignments, and Inspector's and Macie's findings. It allows no change: `\(compact(auditPolicy))`",
        "Under **AWS accounts**, assign the permission set to whoever signs in to Pion, in every account to investigate; select them all to cover the organisation. The alert watch reads up to \(watchAccounts) of them, the lowest account IDs first, so put your security tooling and log archive accounts among them.",
        "For the watch, turn on **GuardDuty** and **Security Hub** in the default region of every account, ideally with a delegated administrator and Security Hub's cross-region aggregation in that region, and keep a CloudTrail trail logging. check-access says what is off.",
        "Enter the **AWS access portal URL** from the Identity Center dashboard, and the permission set's name as the role. For the default region, choose the one most activity is in; agents can name any other, and any account.",
        "Choose **Add & Connect**. Your organisation's sign-in page opens with a code: check it matches the one Pion shows, and approve it. Pion stays signed in for as long as your organisation lets a session last, then asks again. Then ask an agent to run check-access.",
    ]

    /// The audit permission set's inline policy: reads that SecurityAudit may not hold, and nothing that changes anything.
    static let auditPolicy = """
    {"Version":"2012-10-17","Statement":[{"Sid":"PionAuditReads","Effect":"Allow","Resource":"*","Action":[
     "logs:StartQuery","logs:GetQueryResults","iam:SimulatePrincipalPolicy","iam:GetAccountAuthorizationDetails","iam:GenerateCredentialReport",
     "iam:GetCredentialReport","config:GetResourceConfigHistory","config:DescribeConfigurationRecorders","config:DescribeConfigurationRecorderStatus",
     "s3:ListAllMyBuckets","s3:GetBucketPolicyStatus","s3:GetBucketPolicy","s3:GetBucketAcl","s3:GetBucketOwnershipControls",
     "s3:GetBucketPublicAccessBlock","s3:GetAccountPublicAccessBlock","access-analyzer:ListAnalyzers","access-analyzer:ListFindings",
     "sso:ListInstances","sso:ListPermissionSets","sso:DescribePermissionSet","sso:ListManagedPoliciesInPermissionSet",
     "sso:GetInlinePolicyForPermissionSet","sso:ListAccountsForProvisionedPermissionSet","sso:ListAccountAssignments",
     "identitystore:DescribeUser","identitystore:DescribeGroup","identitystore:GetUserId","identitystore:GetGroupId",
     "identitystore:ListGroupMembershipsForMember","inspector2:ListFindings","macie2:ListFindings","macie2:GetFindings"]}]}
    """

    public static let adapter = OperationAdapter(operations: [
        Accounts(), Regions(), CloudTrailEvents(), GuardDutyFindings(), SecurityHubFindings(), AccessKey(), CredentialReport(), IAMAccess(),
        AccessAnalyzerFindings(), Instances(), OpenSecurityGroups(), LogsInsights(), ConfigHistory(), S3Exposure(), IdentityCenterAssignments(),
        CredentialHygiene(), InspectorFindings(), MacieFindings(), SecurityEvents(), CheckAccess(),
    ], trigger: NewSecurityEvents())

    typealias JSON = GoogleCloud.JSON

    // MARK: Limits

    /// The most pages one lookup reads, each up to AWS's own page size.
    static let maximumPages = 10
    /// The most accounts check-access tries when none is named.
    static let checkAccounts = 5
    /// CloudTrail keeps 90 days of management events in its event history.
    static let cloudTrailDays = 90.0

    // MARK: Services, accounts and regions

    /// The AWS services Pion reaches, each at a host built from its name and a checked region: nothing an agent or a
    /// service gives ever picks a host, and a bucket's name only ever goes in a path.
    enum Service: String, Sendable {
        case cloudtrail, guardduty, securityhub, iam, sts, ec2, logs, config, organizations, s3, sso, identitystore, inspector2, macie2
        case accessAnalyzer = "access-analyzer", s3Control = "s3-control"
    }

    /// The host for `service` in `region`, as `account`: IAM and STS are global, Organizations answers in us-east-1,
    /// and S3 Control at the account's own name.
    static func host(_ service: Service, region: String, account: String) -> String {
        switch service {
        case .iam, .sts: "\(service.rawValue).amazonaws.com"
        case .organizations: "organizations.us-east-1.amazonaws.com"
        case .s3Control: "\(account).s3-control.\(region).amazonaws.com"
        default: "\(service.rawValue).\(region).amazonaws.com"
        }
    }

    /// One service in one region of one account, signed as the connection's role there, with how to name what it read.
    struct Target: Sendable {
        let client: ServiceClient
        let account: AWSAccount
        let region: String
        let service: Service

        /// The account, as results name it.
        var named: String { "account \(account.name) (\(account.id))" }
        /// The account and region, as results name what they read.
        var place: String { [.iam, .sts, .organizations].contains(service) ? named : "\(named) in \(region)" }

        func at(_ service: Service, region: String? = nil) throws -> Target {
            let region = region ?? self.region
            return Target(client: try client.at(host: AWS.host(service, region: region, account: account.id)), account: account, region: region, service: service)
        }
    }

    /// `service` in the region asked for, or the connection's own, as the connection's role in the account named.
    static func target(_ service: Service, region: String?, account: String?, on client: ServiceClient) async throws -> Target {
        let region = try region.map(checkedRegion) ?? client.setting("region")
        let (chosen, signed) = try await Self.account(account, on: client)
        return try Target(client: signed, account: chosen, region: region, service: service).at(service)
    }

    /// The account `wanted` names, by its ID or name, or the only one when the sign-in covers just one, with a client
    /// signing as the connection's role there.
    static func account(_ wanted: String?, on service: ServiceClient) async throws -> (AWSAccount, ServiceClient) {
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
        return (chosen, try await signed(chosen, on: service))
    }

    /// A client signing as the connection's role in `account`, one the sign-in covers.
    static func signed(_ account: AWSAccount, on service: ServiceClient) async throws -> ServiceClient {
        // AWS says why it turns a request down, such as Security Hub not being enabled or the role lacking a permission.
        ServiceClient(base: service.base, access: try await service.access.access(asAWSAccount: account.id), settings: service.settings,
                      explainsRefusals: true, account: service.account)
    }

    static func listing(_ accounts: [AWSAccount]) -> String {
        accounts.prefix(20).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
            + (accounts.count > 20 ? ", and \(accounts.count - 20) more" : "")
    }

    static func checkedRegion(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard (1...32).contains(value.count), value.range(of: #"^[a-z]{2}(-[a-z]+)+-[0-9]{1,2}$"#, options: .regularExpression) != nil else {
            throw ServiceError.input("Give a region such as eu-west-1.")
        }
        return value
    }

    /// A 12-digit account ID.
    static func isAccountID(_ value: String) -> Bool { value.count == 12 && value.allSatisfy { $0.isASCII && $0.isNumber } }

    // MARK: Times

    static func date(_ time: String) throws -> Date {
        let plain = ISO8601DateFormatter(), precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let checked = try ServiceInput.time(time)
        guard let date = plain.date(from: checked) ?? precise.date(from: checked) else { throw ServiceError.input("Give times in ISO 8601.") }
        return date
    }

    /// Seconds since 1970, as AWS's JSON APIs take times.
    static func seconds(_ time: String) throws -> Int { Int(try date(time).timeIntervalSince1970) }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// A window, checked: since before until, `days` back when since is left out, and within the `keeps` days the
    /// service keeps when it keeps only so many.
    static func window(_ since: String?, _ until: String?, days: Double, keeps: Double? = nil) throws -> (since: Date, until: Date) {
        let now = Date()
        let from = try since.map(date) ?? now.addingTimeInterval(-days * 86_400)
        let to = try until.map(date) ?? now
        guard from <= to else { throw ServiceError.input("Give since before until.") }
        if let keeps, from < now.addingTimeInterval(-keeps * 86_400 - 60) {
            throw ServiceError.input("This service keeps \(Int(keeps)) days: give since within them.")
        }
        return (from, to)
    }

    static func limit(_ value: Int?, default fallback: Int, maximum: Int) throws -> Int {
        let limit = value ?? fallback
        guard (1...maximum).contains(limit) else { throw ServiceError.input("Ask for between 1 and \(maximum).") }
        return limit
    }

    // MARK: Requests

    /// A JSON request to one of AWS's JSON APIs: by its operation in X-Amz-Target for the older ones, such as
    /// CloudTrail's, or by its path for the REST ones, such as GuardDuty's. The answer is read as JSON.
    static func call(_ target: Target, _ path: [String] = [], operation: String? = nil, method: String = "POST", body: [String: Any]? = [:],
                     query: [String: String?] = [:]) async throws -> JSON {
        let data = try await send(target, path, operation: operation, method: method, body: body, query: query)
        guard !data.isEmpty else { return .object([:]) }
        do { return try JSONDecoder().decode(JSON.self, from: data) } catch { throw ServiceError.unreadable }
    }

    static func send(_ target: Target, _ path: [String] = [], operation: String? = nil, method: String = "POST", body: [String: Any]? = [:],
                     query: [String: String?] = [:]) async throws -> Data {
        try await target.client.data(path, query: query, method: method,
                                     body: try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) },
                                     contentType: operation == nil ? "application/json" : "application/x-amz-json-1.1",
                                     headers: operation.map { ["X-Amz-Target": $0] } ?? [:])
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ServiceError.unreadable }
    }

    static let lookupEvents = "com.amazonaws.cloudtrail.v20131101.CloudTrail_20131101.LookupEvents"

    static func items(_ value: JSON?) -> [JSON] { if case .array(let items)? = value { return items }; return [] }
    static func number(_ value: JSON?) -> Double? {
        switch value {
        case .number(let number)?: number
        case .string(let text)?: Double(text)
        default: nil
        }
    }
    static func flag(_ value: JSON?) -> Bool? {
        switch value {
        case .bool(let flag)?: flag
        case .string(let text)?: ["true": true, "false": false][text.lowercased()]
        default: nil
        }
    }
    /// A value as text, a number written plainly.
    static func text(_ value: JSON?) -> String? {
        switch value {
        case .string(let text)?: text
        case .number(let number)?: number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag)?: flag ? "true" : "false"
        default: nil
        }
    }
    /// JSON that AWS gives as a string holding JSON, such as a CloudTrail event's detail or an IAM policy in a request.
    static func embedded(_ value: JSON?) -> JSON? {
        switch value {
        case .string(let text)?:
            let decoded = text.hasPrefix("%7B") || text.hasPrefix("%7b") ? text.removingPercentEncoding ?? text : text
            return try? JSONDecoder().decode(JSON.self, from: Data(decoded.utf8))
        case .object?: return value
        default: return nil
        }
    }

    /// An ID a wake can carry: a fixed prefix naming its feed, and a digest of the service's own ID, so nothing a
    /// service wrote, however plain it looks, reaches the note that wakes an agent.
    static func safeID(_ prefix: String, _ value: String) -> String {
        prefix + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Refusals

    /// Whether AWS refused because a service is not turned on in the account and region, as Security Hub says when it
    /// is not enabled, rather than for a missing permission.
    static func isOff(_ error: Error) -> Bool {
        guard case ServiceError.refused(let reason) = error else { return false }
        let lower = reason.lowercased()
        return lower.contains("not subscribed") || lower.contains("invalidaccessexception") || lower.contains("not enabled")
            || lower.contains("organizationsnotinuse") || lower.contains("subscriptionrequired")
    }

    /// Whether AWS refused for a missing permission.
    static func isDenied(_ error: Error) -> Bool {
        switch error {
        case ServiceError.forbidden, ServiceError.rejected: return true
        case ServiceError.refused(let reason):
            let lower = reason.lowercased()
            return lower.contains("accessdenied") || lower.contains("not authorized") || lower.contains("unauthorizedoperation")
                || lower.contains("unrecognizedclient") || lower.contains("security token")
        default: return false
        }
    }

    /// What to change when AWS refused something, for a permission set, or nil for any other failure.
    static func fix(for error: Error, needs actions: [String], permissionSet: String = "the permission set") -> String? {
        if isDenied(error) {
            return "the role may not do this: add \(actions.joined(separator: ", ")) to \(permissionSet) in IAM Identity Center, then re-provision it to the account."
        }
        if case ServiceError.rateLimited = error { return "AWS throttled the requests: wait a minute and try again, with a narrower lookup." }
        return nil
    }

    /// A request, with AWS's refusal of a permission said with what to change, so an agent can tell the champion; any
    /// other failure, such as throttling, which passes, or a service that is off, which some say as a denial, is left
    /// as it is.
    static func read<Value>(_ what: String, needs actions: [String], _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard isDenied(error), !isOff(error), let fix = fix(for: error, needs: actions) else { throw error }
            throw ServiceError.input("AWS refused \(what) (\(error.localizedDescription)): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }
}

extension AWS {
    struct Accounts: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "accounts"
        static let summary = "Every AWS account the sign-in covers, with its ID, name and email. Other lookups name one of them. Only accounts the person is assigned in IAM Identity Center are listed; check-access compares them with the organisation's own list."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let accounts = try await service.access.awsAccounts()
            struct Account: Encodable { let id: String, name: String, email: String? }
            struct Listed: Encodable { let accounts: [Account] }
            let text = accounts.isEmpty ? "The sign-in covers no AWS accounts." : "\(accounts.count) accounts:\n" + accounts.map { account in
                "\(account.name) (\(account.id))" + (account.email.map { " — \($0)" } ?? "")
            }.joined(separator: "\n") + "\nThese are the accounts the sign-in is assigned in IAM Identity Center; others in the organisation are not reached."
            return try ServiceResult(text: text, structured: Listed(accounts: accounts.map { Account(id: $0.id, name: $0.name, email: $0.email) }))
        }
    }

    struct Regions: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String? }
        static let name = "regions"
        static let summary = "The regions an account has turned on, which lookups can name, and those it has not."
        static let input = JSONSchema.object(["account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ec2 = try await AWS.target(.ec2, region: nil, account: input.account, on: service)
            let answer = try await AWS.read("listing regions", needs: ["ec2:DescribeRegions"]) {
                try await ec2.client.xml([], query: ["Action": "DescribeRegions", "Version": "2016-11-15", "AllRegions": "true"])
            }
            let all = (answer.child("regionInfo")?.children ?? []).compactMap { item -> (String, String)? in
                item.value("regionName").map { ($0, item.value("optInStatus") ?? "opt-in-not-required") }
            }.sorted { $0.0 < $1.0 }
            let on = all.filter { $0.1 != "not-opted-in" }.map(\.0), off = all.filter { $0.1 == "not-opted-in" }.map(\.0)
            guard !all.isEmpty else { throw ServiceError.unreadable }
            return try ServiceResult(text: "\(ec2.named) has \(on.count) regions turned on: \(on.joined(separator: ", ")).\(off.isEmpty ? "" : " Not turned on: \(off.joined(separator: ", ")).")",
                                     structured: ["account": ec2.account.id, "enabled": on.joined(separator: ","), "notEnabled": off.joined(separator: ",")])
        }
    }

    /// CloudTrail's event history, looked up by one attribute at a time, as LookupEvents takes it, page after page.
    struct CloudTrailEvents: ServiceOperation {
        struct Input: Decodable, Sendable {
            let user: String?, eventName: String?, eventSource: String?, resource: String?, accessKeyId: String?
            let since: String?, until: String?, limit: Int?, region: String?, account: String?
        }
        static let name = "cloudtrail-events"
        static let summary = "CloudTrail management events, newest first, by one of user, event name, event source, resource or access key, with who acted (root, an IAM user or an assumed role and the role behind it, and from which account), source IP, agent, whether MFA was used and any error; reading the default region and us-east-1, where IAM, STS, Organizations and console sign-ins are logged, unless a region is named, and saying when more matched than were read."
        static let input = JSONSchema.object([
            "user": .string("The IAM user or role session name."), "eventName": .string("An API call, such as ConsoleLogin or CreateAccessKey."),
            "eventSource": .string("A service, such as iam.amazonaws.com."), "resource": .string("A resource's name or ARN."),
            "accessKeyId": .string("The access key used."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out; CloudTrail keeps 90."),
            "until": .string("The latest time, in ISO 8601. Now when left out."), "limit": .integer("How many events, at most. 50 when left out.", minimum: 1, maximum: 200),
            "region": .string("Only this region, such as eu-west-1. The connection's default region and us-east-1 when left out."), "account": AWS.accountInput,
        ])

        struct Resource: Codable { let ResourceType: String?; let ResourceName: String? }
        struct Event: Decodable { let EventId: String?, EventName: String?, EventTime: Double?, EventSource: String?, Username: String?, Resources: [Resource]?, CloudTrailEvent: String? }
        struct Answer: Decodable { let Events: [Event]?; let NextToken: String? }
        struct Kept: Encodable {
            let id: String?, time: String?, name: String?, source: String?, user: String?
            /// Who acted, as CloudTrail records it: Root, IAMUser, AssumedRole, FederatedUser, AWSService and so on.
            let identityType: String?, identityArn: String?, identityAccount: String?
            /// For an assumed role: the role behind the session.
            let sessionIssuer: String?
            /// Yes or No for a console sign-in; for a role session, whether it was made with MFA.
            let mfaUsed: String?
            let readOnly: Bool?, ip: String?, userAgent: String?, region: String?, recipientAccount: String?
            let error: String?, errorMessage: String?, resources: [Resource]
            var date: Date { time.flatMap { ServiceAlert.time($0) } ?? .distantPast }
        }

        static func kept(_ event: Event, region: String) -> Kept {
            let detail = AWS.embedded(event.CloudTrailEvent.map(JSON.string))
            let identity = detail?["userIdentity"]
            let context = identity?["sessionContext"]
            let mfa = AWS.text(detail?["additionalEventData"]?["MFAUsed"])
                ?? AWS.text(context?["attributes"]?["mfaAuthenticated"]).map { $0 == "true" ? "Yes" : "No" }
            return Kept(id: event.EventId, time: event.EventTime.map { AWS.iso(Date(timeIntervalSince1970: $0)) }, name: event.EventName,
                        source: event.EventSource, user: event.Username, identityType: AWS.text(identity?["type"]), identityArn: AWS.text(identity?["arn"]),
                        identityAccount: AWS.text(identity?["accountId"]), sessionIssuer: AWS.text(context?["sessionIssuer"]?["arn"]), mfaUsed: mfa,
                        readOnly: AWS.flag(detail?["readOnly"]), ip: AWS.text(detail?["sourceIPAddress"]), userAgent: AWS.text(detail?["userAgent"]),
                        region: AWS.text(detail?["awsRegion"]) ?? region, recipientAccount: AWS.text(detail?["recipientAccountId"]),
                        error: AWS.text(detail?["errorCode"]), errorMessage: AWS.text(detail?["errorMessage"]), resources: event.Resources ?? [])
        }

        static func line(_ event: Kept, account: String) -> String {
            var line = "\(event.time ?? "?") \(event.name ?? "?")"
            switch event.identityType {
            case "Root"?: line += " by root"
            case "AssumedRole"?: line += " by \(event.user ?? "?") as \(event.sessionIssuer ?? event.identityArn ?? "a role")"
            case let type?: line += " by \(event.user ?? event.identityArn ?? "?") (\(type))"
            case nil: if let user = event.user { line += " by \(user)" }
            }
            if let other = event.identityAccount, other != account { line += " from account \(other)" }
            if let ip = event.ip { line += " from \(ip)" }
            if let mfa = event.mfaUsed { line += ", MFA \(mfa)" }
            if let error = event.error { line += " — \(error)" }
            let names = event.resources.compactMap(\.ResourceName)
            if !names.isEmpty { line += " on \(names.prefix(3).joined(separator: ", "))" }
            if let region = event.region { line += " [\(region)]" }
            return line
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let attributes = [("Username", input.user), ("EventName", input.eventName), ("EventSource", input.eventSource),
                              ("ResourceName", input.resource), ("AccessKeyId", input.accessKeyId)]
                .compactMap { key, value in value.map { (key, $0) } }
            guard attributes.count <= 1 else { throw ServiceError.input("CloudTrail looks events up by one of user, event name, source, resource or access key at a time.") }
            let lookup = try attributes.map { ["AttributeKey": $0.0, "AttributeValue": try ServiceInput.quoted($0.1, "the value")] }
            let window = try AWS.window(input.since, input.until, days: 7, keeps: AWS.cloudTrailDays)
            let limit = try AWS.limit(input.limit, default: 50, maximum: 200)
            let first = try await AWS.target(.cloudtrail, region: input.region, account: input.account, on: service)
            // IAM, STS, Organizations and console sign-ins are logged in us-east-1 whatever region they are used from.
            var regions = [first.region]
            if input.region == nil, first.region != "us-east-1" { regions.append("us-east-1") }
            var events: [Kept] = [], more: [String] = [], pages = 0
            for region in regions {
                let target = try first.at(.cloudtrail, region: region)
                var token: String?, read = 0
                repeat {
                    var body: [String: Any] = ["StartTime": Int(window.since.timeIntervalSince1970), "EndTime": Int(window.until.timeIntervalSince1970), "MaxResults": 50]
                    if !lookup.isEmpty { body["LookupAttributes"] = lookup }
                    if let token { body["NextToken"] = token }
                    let answer = try await AWS.read("CloudTrail's event history", needs: ["cloudtrail:LookupEvents"]) {
                        try AWS.decode(Answer.self, try await AWS.send(target, operation: AWS.lookupEvents, body: body))
                    }
                    pages += 1
                    let page = (answer.Events ?? []).map { Self.kept($0, region: region) }
                    events += page
                    read += page.count
                    token = answer.NextToken.flatMap { $0.isEmpty ? nil : $0 }
                } while token != nil && read < limit && pages < AWS.maximumPages * regions.count
                if token != nil { more.append(region) }
            }
            var seen = Set<String>()
            let sorted = events.filter { $0.id.map { seen.insert($0).inserted } ?? true }.sorted { $0.date > $1.date }
            let kept = Array(sorted.prefix(limit))
            let place = "\(first.named) in \(GoogleCloud.listed(regions))"
            var lines = kept.isEmpty ? ["No CloudTrail events match in \(place), from \(AWS.iso(window.since)) to \(AWS.iso(window.until))."]
                : kept.prefix(50).map { Self.line($0, account: first.account.id) }
            if kept.count > 50 { lines.append("\(kept.count - 50) more in the structured result.") }
            if sorted.count > kept.count { lines.append("\(sorted.count) matched in what was read; the newest \(kept.count) are kept.") }
            if !more.isEmpty {
                lines.append("More events matched in \(GoogleCloud.listed(more)) than were read: narrow since and until, or the lookup, to see the rest.")
            }
            if input.region != nil, regions == [first.region], first.region != "us-east-1" {
                lines.append("Only \(first.region) was read; IAM, STS, Organizations and console sign-in events are logged in us-east-1.")
            }
            if !kept.isEmpty { lines.append("Read \(place).") }
            struct Events: Encodable { let events: [Kept]; let account: String; let regions: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Events(events: kept, account: first.account.id, regions: regions, complete: more.isEmpty))
        }
    }

    /// GuardDuty's label for a severity: 9 and above is critical, as attack sequences are.
    static func severityLabel(_ severity: Double?) -> String {
        guard let severity else { return "?" }
        switch severity {
        case 9...: return "Critical"
        case 7..<9: return "High"
        case 4..<7: return "Medium"
        default: return "Low"
        }
    }

    struct GuardDutyFinding: Encodable {
        let id: String, arn: String?, account: String?, region: String?, type: String?, severity: Double?, severityLabel: String
        let title: String?, createdAt: String?, updatedAt: String?, archived: Bool?, count: Int?
        let resourceType: String?, user: String?, accessKeyId: String?, instanceId: String?

        init?(_ json: JSON) {
            guard let id = AWS.text(json["id"]) else { return nil }
            self.id = id; arn = AWS.text(json["arn"]); account = AWS.text(json["accountId"]); region = AWS.text(json["region"])
            type = AWS.text(json["type"]); severity = AWS.number(json["severity"]); severityLabel = AWS.severityLabel(severity)
            title = AWS.text(json["title"]); createdAt = AWS.text(json["createdAt"]); updatedAt = AWS.text(json["updatedAt"])
            archived = AWS.flag(json["service"]?["archived"]); count = AWS.number(json["service"]?["count"]).map { Int($0) }
            resourceType = AWS.text(json["resource"]?["resourceType"]); user = AWS.text(json["resource"]?["accessKeyDetails"]?["userName"])
            accessKeyId = AWS.text(json["resource"]?["accessKeyDetails"]?["accessKeyId"]); instanceId = AWS.text(json["resource"]?["instanceDetails"]?["instanceId"])
        }

        func line(account own: String) -> String {
            var line = "\(updatedAt ?? "?") \(severityLabel) \(severity.map { String(format: "%.1f", $0) } ?? "?") \(type ?? "?"): \(title ?? id)"
            if let user { line += " — \(user)\(accessKeyId.map { " (\($0))" } ?? "")" }
            if let instanceId { line += " — \(instanceId)" }
            if let account, account != own { line += " in member account \(account)" }
            if let region { line += " [\(region)]" }
            return line + " [\(id)]"
        }
    }

    /// The region's GuardDuty detector, or nil when GuardDuty is not turned on there.
    static func detector(_ target: Target) async throws -> String? {
        let listed = try await read("GuardDuty's detectors", needs: ["guardduty:ListDetectors"]) { try await call(target, ["detector"], method: "GET", body: nil) }
        return items(listed["detectorIds"]).compactMap(\.text).first
    }

    /// Findings by ID, read in AWS's batches of 50.
    static func guardDutyFindings(_ target: Target, detector: String, ids: [String]) async throws -> [GuardDutyFinding] {
        var found: [GuardDutyFinding] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let answer = try await read("GuardDuty's findings", needs: ["guardduty:GetFindings"]) {
                try await call(target, ["detector", detector, "findings", "get"], body: ["findingIds": batch])
            }
            found += items(answer["findings"]).compactMap(GuardDutyFinding.init)
        }
        return found
    }

    struct GuardDutyFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let minimumSeverity: Double?, includeArchived: Bool?, limit: Int?, region: String?, account: String? }
        static let name = "guardduty-findings"
        static let summary = "GuardDuty findings that are not archived, most recently updated first, from a minimum severity, with the resource and identity each concerns and the account and region it is in, saying when more matched than were read."
        static let input = JSONSchema.object([
            "minimumSeverity": .integer("The lowest severity, from 1 to 10: 9 and above is critical, such as attack sequences, 7 and above high. 4 when left out.", minimum: 1, maximum: 10),
            "includeArchived": .boolean("Include archived and suppressed findings too."),
            "limit": .integer("How many findings, at most. 25 when left out.", minimum: 1, maximum: 100), "region": AWS.regionInput, "account": AWS.accountInput,
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let severity = input.minimumSeverity ?? 4
            guard (1...10).contains(severity) else { throw ServiceError.input("Give a severity from 1 to 10.") }
            let limit = try AWS.limit(input.limit, default: 25, maximum: 100)
            let target = try await AWS.target(.guardduty, region: input.region, account: input.account, on: service)
            guard let detector = try await AWS.detector(target) else {
                return try ServiceResult(text: "GuardDuty is not turned on in \(target.place): it has no detector there, so it finds nothing there. Other regions were not read.",
                                         structured: AWS.fields(["findings": [String](), "account": target.account.id, "region": target.region]))
            }
            var criterion: [String: Any] = ["severity": ["gte": severity]]
            if input.includeArchived != true { criterion["service.archived"] = ["eq": ["false"]] }
            var ids: [String] = [], token: String?, pages = 0
            repeat {
                var body: [String: Any] = ["findingCriteria": ["criterion": criterion], "maxResults": 50,
                                           "sortCriteria": ["attributeName": "updatedAt", "orderBy": "DESC"]]
                if let token { body["nextToken"] = token }
                let answer = try await AWS.read("GuardDuty's findings", needs: ["guardduty:ListFindings"]) {
                    try await AWS.call(target, ["detector", detector, "findings"], body: body)
                }
                pages += 1
                ids += AWS.items(answer["findingIds"]).compactMap(\.text)
                token = AWS.text(answer["nextToken"]).flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && ids.count < limit && pages < AWS.maximumPages
            let kept = Array(ids.prefix(limit))
            let findings = try await AWS.guardDutyFindings(target, detector: detector, ids: kept)
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            let archived = input.includeArchived == true ? "" : " that are not archived"
            var lines = findings.isEmpty ? ["No GuardDuty findings\(archived) at severity \(Int(severity)) or above in \(target.place). Other regions were not read."]
                : findings.map { $0.line(account: target.account.id) }
            if ids.count > kept.count || token != nil {
                lines.append("More findings matched than the \(kept.count) kept: raise minimumSeverity or the limit to see the rest.")
            }
            if !findings.isEmpty { lines.append("Read \(target.place).") }
            struct Found: Encodable { let findings: [GuardDutyFinding]; let account: String; let region: String; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Found(findings: findings, account: target.account.id, region: target.region, complete: token == nil && ids.count <= kept.count))
        }
    }

    struct SecurityHubFinding: Encodable {
        let id: String, account: String?, region: String?, title: String?, severity: String?, product: String?, createdAt: String?, updatedAt: String?
        let workflow: String?, recordState: String?, resources: [String]

        init?(_ json: JSON) {
            guard let id = AWS.text(json["Id"]) else { return nil }
            self.id = id; account = AWS.text(json["AwsAccountId"]); region = AWS.text(json["Region"]); title = AWS.text(json["Title"])
            severity = AWS.text(json["Severity"]?["Label"]); product = AWS.text(json["ProductName"]); createdAt = AWS.text(json["CreatedAt"])
            updatedAt = AWS.text(json["UpdatedAt"])
            workflow = AWS.text(json["Workflow"]?["Status"]) ?? AWS.text(json["WorkflowState"]); recordState = AWS.text(json["RecordState"])
            resources = AWS.items(json["Resources"]).compactMap { AWS.text($0["Id"]) }
        }

        func line(account own: String) -> String {
            var line = "\(updatedAt ?? "?") \(severity ?? "?") \(title ?? id)\(product.map { " (\($0))" } ?? "")"
            if let first = resources.first { line += " — \(first)" }
            if let workflow { line += ", \(workflow)" }
            if let account, account != own { line += " in member account \(account)" }
            if let region { line += " [\(region)]" }
            return line
        }
    }

    static let openWorkflow = ["NEW", "NOTIFIED"]

    struct SecurityHubFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let severities: [String]?, workflowStatuses: [String]?, limit: Int?, region: String?, account: String? }
        static let name = "securityhub-findings"
        static let summary = "Active Security Hub findings, most recently updated first, by severity and workflow status, NEW and NOTIFIED unless asked, with the product, resources, and the account and region each is in, which differ in an aggregating account; saying when more matched than were read."
        static let input = JSONSchema.object([
            "severities": .array(.string("A severity.", oneOf: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"]), "Severities. Critical and high when left out."),
            "workflowStatuses": .array(.string("A workflow status.", oneOf: ["NEW", "NOTIFIED", "SUPPRESSED", "RESOLVED"]), "Workflow statuses. NEW and NOTIFIED when left out, so suppressed and resolved findings are not shown."),
            "limit": .integer("How many findings, at most. 25 when left out.", minimum: 1, maximum: 100), "region": AWS.regionInput, "account": AWS.accountInput,
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let severities = try (input.severities ?? ["CRITICAL", "HIGH"]).map { try ServiceInput.oneOf($0, ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"], "severity") }
            let workflow = try (input.workflowStatuses ?? AWS.openWorkflow).map { try ServiceInput.oneOf($0, ["NEW", "NOTIFIED", "SUPPRESSED", "RESOLVED"], "workflow status") }
            let limit = try AWS.limit(input.limit, default: 25, maximum: 100)
            let target = try await AWS.target(.securityhub, region: input.region, account: input.account, on: service)
            let equals = { (values: [String]) in values.map { ["Value": $0, "Comparison": "EQUALS"] } }
            var findings: [SecurityHubFinding] = [], token: String?, pages = 0
            do {
                repeat {
                    var body: [String: Any] = ["Filters": ["RecordState": equals(["ACTIVE"]), "SeverityLabel": equals(severities), "WorkflowStatus": equals(workflow)],
                                               "MaxResults": min(100, limit), "SortCriteria": [["Field": "UpdatedAt", "SortOrder": "desc"]]]
                    if let token { body["NextToken"] = token }
                    let answer = try await AWS.read("Security Hub's findings", needs: ["securityhub:GetFindings"]) { try await AWS.call(target, ["findings"], body: body) }
                    pages += 1
                    findings += AWS.items(answer["Findings"]).compactMap(SecurityHubFinding.init)
                    token = AWS.text(answer["NextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                } while token != nil && findings.count < limit && pages < AWS.maximumPages
            } catch let error where AWS.isOff(error) {
                return try ServiceResult(text: "Security Hub is not turned on in \(target.place), so it holds no findings there (AWS said: \(error.localizedDescription)). Other regions were not read.",
                                         structured: AWS.fields(["findings": [String](), "account": target.account.id, "region": target.region]))
            }
            let kept = Array(findings.prefix(limit))
            var lines = kept.isEmpty ? ["No active Security Hub findings that are \(GoogleCloud.listed(workflow)) and \(GoogleCloud.listed(severities)) in \(target.place). Without cross-region aggregation, other regions were not read."]
                : kept.map { $0.line(account: target.account.id) }
            if findings.count > kept.count || token != nil { lines.append("More findings matched than the \(kept.count) kept: narrow severities or raise the limit to see the rest.") }
            if !kept.isEmpty { lines.append("Read \(target.place).") }
            struct Found: Encodable { let findings: [SecurityHubFinding]; let account: String; let region: String; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Found(findings: kept, account: target.account.id, region: target.region, complete: token == nil && findings.count <= kept.count))
        }
    }

    struct AccessKey: ServiceOperation {
        struct Input: Decodable, Sendable { let accessKeyId: String, account: String? }
        static let name = "access-key"
        static let summary = "Which account an access key belongs to and, for a long-term key, which user and when, where and with which service it was last used. A temporary key, ASIA…, is traced to its account; its use is in cloudtrail-events by accessKeyId."
        static let input = JSONSchema.object(["accessKeyId": .string("The access key ID, such as AKIA… or ASIA…."),
                                              "account": .string("The account to ask AWS from, by ID or name. Any covered account when left out; the key's own account is found from the key.")],
                                             required: ["accessKeyId"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let key = input.accessKeyId.trimmingCharacters(in: .whitespaces)
            guard (16...128).contains(key.count), key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }), key.hasPrefix("A") else {
                throw ServiceError.input("Give an access key ID such as AKIAIOSFODNN7EXAMPLE.")
            }
            // A key's account is found from the key itself, which STS answers for anyone, so a key from anywhere is
            // traced to its own account rather than looked up in the wrong one.
            let accounts = try await service.access.awsAccounts()
            let asking = try await AWS.account(input.account?.isEmpty == false ? input.account : accounts.first?.id, on: service)
            let sts = try Target(client: asking.1, account: asking.0, region: "us-east-1", service: .sts).at(.sts)
            let info = try await AWS.read("tracing the key", needs: ["sts:GetAccessKeyInfo"]) {
                try await sts.client.xml([], query: ["Action": "GetAccessKeyInfo", "Version": "2011-06-15", "AccessKeyId": key])
            }
            guard let owner = info.value("GetAccessKeyInfoResult", "Account"), AWS.isAccountID(owner) else { throw ServiceError.unreadable }
            guard let account = accounts.first(where: { $0.id == owner }) else {
                return try ServiceResult(text: "\(key) belongs to account \(owner), which the sign-in does not cover.",
                                         structured: ["accessKeyId": key, "account": owner])
            }
            if key.hasPrefix("ASIA") {
                return try ServiceResult(text: "\(key) is a temporary key from a role session or federation in account \(account.name) (\(owner)). It has no owner or last use in IAM: look it up with cloudtrail-events, accessKeyId \(key) and account \(owner), to see who it was issued to and what it did.",
                                         structured: ["accessKeyId": key, "account": owner, "temporary": "true"])
            }
            let iam = try Target(client: try await AWS.signed(account, on: service), account: account, region: "us-east-1", service: .iam).at(.iam)
            let answer = try await AWS.read("the key's last use", needs: ["iam:GetAccessKeyLastUsed"]) {
                try await iam.client.xml([], query: ["Action": "GetAccessKeyLastUsed", "Version": "2010-05-08", "AccessKeyId": key])
            }
            // Only a result naming the key's user is believed: anything less is no answer, never "never used".
            guard let result = answer.child("GetAccessKeyLastUsedResult"), let user = result.value("UserName") else { throw ServiceError.unreadable }
            struct Use: Encodable { let accessKeyId: String, account: String, user: String, lastUsed: String?, service: String?, region: String? }
            let used = result.value("AccessKeyLastUsed", "LastUsedDate")
            let use = Use(accessKeyId: key, account: owner, user: user, lastUsed: used, service: result.value("AccessKeyLastUsed", "ServiceName"),
                          region: result.value("AccessKeyLastUsed", "Region"))
            var text = "\(key) belongs to \(user) in account \(account.name) (\(owner))"
            if let used { text += ", last used \(used) with \(use.service ?? "?") in \(use.region ?? "?")." } else { text += ", never used, as IAM records it." }
            return try ServiceResult(text: text, structured: use)
        }
    }

    struct CredentialReport: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String? }
        static let name = "credential-report"
        static let summary = "Every IAM user's password and access key use, key ages and whether MFA is on, from the account's credential report, saying when it was made: AWS reuses one up to four hours old."
        static let input = JSONSchema.object(["account": AWS.accountInput])

        /// CSV as RFC 4180 has it: fields in double quotes may hold commas, line breaks and doubled quotes.
        static func rows(_ csv: String) -> [[String]] {
            var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, index = csv.startIndex
            while index < csv.endIndex {
                let character = csv[index]
                index = csv.index(after: index)
                if quoted {
                    if character == "\"" {
                        if index < csv.endIndex, csv[index] == "\"" { field.append("\""); index = csv.index(after: index) } else { quoted = false }
                    } else { field.append(character) }
                } else if character == "\"" && field.isEmpty {
                    quoted = true
                } else if character == "," {
                    row.append(field); field = ""
                } else if character.isNewline {
                    row.append(field); field = ""
                    if row != [""] { rows.append(row) }
                    row = []
                } else { field.append(character) }
            }
            if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
            return rows
        }

        /// An account's credential report: its columns, the rows that split into them, how many did not, and when it was made.
        struct Report { let columns: [String]; let rows: [[String]]; let broken: Int; let made: String? }

        /// The credential report, made first if none is recent: the report is made on request, usually in seconds.
        static func report(_ iam: Target) async throws -> Report {
            for attempt in 0..<6 {
                let state = try await AWS.read("making the credential report", needs: ["iam:GenerateCredentialReport"]) {
                    try await iam.client.xml([], query: ["Action": "GenerateCredentialReport", "Version": "2010-05-08"])
                }
                if state.value("GenerateCredentialReportResult", "State") == "COMPLETE" { break }
                if attempt == 5 { throw ServiceError.refused("the credential report is still being made; try again shortly") }
                try await Task.sleep(for: .seconds(2))
            }
            let report = try await AWS.read("the credential report", needs: ["iam:GetCredentialReport"]) {
                try await iam.client.xml([], query: ["Action": "GetCredentialReport", "Version": "2010-05-08"])
            }
            guard let content = report.value("GetCredentialReportResult", "Content"), let data = Data(base64Encoded: content),
                  let csv = String(data: data, encoding: .utf8) else { throw ServiceError.unreadable }
            let lines = Self.rows(csv)
            guard let columns = lines.first, !columns.isEmpty else { throw ServiceError.unreadable }
            let whole = lines.dropFirst().filter { $0.count == columns.count }
            return Report(columns: columns, rows: Array(whole), broken: lines.count - 1 - whole.count, made: report.value("GetCredentialReportResult", "GeneratedTime"))
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (account, signed) = try await AWS.account(input.account, on: service)
            let iam = try Target(client: signed, account: account, region: "us-east-1", service: .iam).at(.iam)
            let report = try await Self.report(iam)
            var notice = "\nFrom \(iam.named)'s credential report made \(report.made ?? "at an unknown time"); AWS reuses a report up to four hours old, so users and keys made since may be missing."
            let broken = report.broken
            if broken > 0 { notice += " \(broken) row\(broken == 1 ? "" : "s") could not be split into the report's columns and \(broken == 1 ? "is" : "are") left out." }
            return try ServiceTable(columns: report.columns, rows: report.rows.map { $0.map { CellValue.text($0) } }).result().adding(notice)
        }
    }

    struct AccessAnalyzerFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let limit: Int?, region: String?, account: String? }
        static let name = "access-analyzer-findings"
        static let summary = "Active IAM Access Analyzer findings of the region's external access analyzer, the organisation's or the account's: resources shared outside, and whether publicly; saying when more matched than were read."
        static let input = JSONSchema.object(["limit": .integer("How many findings, at most. 50 when left out.", minimum: 1, maximum: 100), "region": AWS.regionInput, "account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = try AWS.limit(input.limit, default: 50, maximum: 100)
            let target = try await AWS.target(.accessAnalyzer, region: input.region, account: input.account, on: service)
            let listed = try await AWS.read("Access Analyzer's analyzers", needs: ["access-analyzer:ListAnalyzers"]) {
                try await AWS.call(target, ["analyzer"], method: "GET", body: nil)
            }
            // External access is what an ORGANIZATION or ACCOUNT analyzer finds; unused-access analyzers find something else.
            let analyzers = AWS.items(listed["analyzers"]).filter { AWS.text($0["status"]) == "ACTIVE" }
            guard let analyzer = analyzers.first(where: { AWS.text($0["type"]) == "ORGANIZATION" }) ?? analyzers.first(where: { AWS.text($0["type"]) == "ACCOUNT" }),
                  let arn = AWS.text(analyzer["arn"]) else {
                return try ServiceResult(text: "No active external access analyzer exists in \(target.place), so nothing is found shared outside there. Other regions were not read.",
                                         structured: AWS.fields(["findings": [String](), "account": target.account.id, "region": target.region]))
            }
            struct Finding: Encodable { let id: String, resource: String?, resourceType: String?, owner: String?, isPublic: Bool?, actions: [String], updatedAt: String? }
            var findings: [Finding] = [], token: String?, pages = 0
            repeat {
                var body: [String: Any] = ["analyzerArn": arn, "filter": ["status": ["eq": ["ACTIVE"]]], "maxResults": 100]
                if let token { body["nextToken"] = token }
                let answer = try await AWS.read("Access Analyzer's findings", needs: ["access-analyzer:ListFindings"]) { try await AWS.call(target, ["finding"], body: body) }
                pages += 1
                findings += AWS.items(answer["findings"]).compactMap { json in
                    AWS.text(json["id"]).map {
                        Finding(id: $0, resource: AWS.text(json["resource"]), resourceType: AWS.text(json["resourceType"]), owner: AWS.text(json["resourceOwnerAccount"]),
                                isPublic: AWS.flag(json["isPublic"]), actions: AWS.items(json["action"]).compactMap(\.text), updatedAt: AWS.text(json["updatedAt"]))
                    }
                }
                token = AWS.text(answer["nextToken"]).flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && findings.count < limit && pages < AWS.maximumPages
            let kept = Array(findings.prefix(limit))
            let kind = AWS.text(analyzer["type"]) == "ORGANIZATION" ? "the organisation" : "the account"
            var lines = kept.isEmpty ? ["Access Analyzer finds nothing shared outside \(kind) in \(target.place)."] : kept.map { finding in
                "\(finding.resource ?? finding.id) is \(finding.isPublic == true ? "public" : "shared outside \(kind)")\(finding.actions.isEmpty ? "" : " for \(finding.actions.prefix(4).joined(separator: ", "))")"
                    + (finding.owner.map { $0 != target.account.id ? " (in account \($0))" : "" } ?? "")
            }
            if findings.count > kept.count || token != nil { lines.append("More findings matched than the \(kept.count) kept: raise the limit to see the rest.") }
            if !kept.isEmpty { lines.append("Read \(target.place)'s \(kind == "the organisation" ? "organisation" : "account") analyzer.") }
            struct Found: Encodable { let findings: [Finding]; let analyzer: String; let account: String; let region: String; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Found(findings: kept, analyzer: arn, account: target.account.id, region: target.region,
                                                                                           complete: token == nil && findings.count <= kept.count))
        }
    }

    struct Instances: ServiceOperation {
        struct Input: Decodable, Sendable { let instanceId: String?, ip: String?, region: String?, account: String? }
        static let name = "ec2-instances"
        static let summary = "EC2 instances by instance ID or public or private IP address, with their state, addresses, security groups, instance profile and Name tag."
        static let input = JSONSchema.object(["instanceId": .string("The instance ID, such as i-0abc…."),
                                              "ip": .string("A public or private IPv4 address."), "region": AWS.regionInput, "account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["Action": "DescribeInstances", "Version": "2016-11-15"]
            if let id = input.instanceId {
                query["InstanceId.1"] = try AWS.instanceID(id)
            } else if let ip = input.ip {
                let ip = try ServiceInput.ip(ip)
                let isPrivate = ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0))
                query["Filter.1.Name"] = isPrivate ? "private-ip-address" : "ip-address"
                query["Filter.1.Value.1"] = ip
            } else { throw ServiceError.input("Give an instance ID or an IP address.") }
            let target = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            let answer = try await AWS.read("EC2's instances", needs: ["ec2:DescribeInstances"]) { try await target.client.xml([], query: query) }
            struct Instance: Encodable { let id: String?, name: String?, type: String?, state: String?, privateIP: String?, publicIP: String?, launched: String?, securityGroups: [String], instanceProfile: String?, vpc: String? }
            struct Found: Encodable { let instances: [Instance]; let account: String; let region: String }
            let instances = answer.all("instancesSet").flatMap { $0.children }.map { item in
                Instance(id: item.value("instanceId"), name: item.child("tagSet")?.children.first { $0.value("key") == "Name" }?.value("value"),
                         type: item.value("instanceType"), state: item.value("instanceState", "name"), privateIP: item.value("privateIpAddress"),
                         publicIP: item.value("ipAddress"), launched: item.value("launchTime"),
                         securityGroups: item.child("groupSet")?.children.compactMap { $0.value("groupId") } ?? [],
                         instanceProfile: item.value("iamInstanceProfile", "arn"), vpc: item.value("vpcId"))
            }
            let text = instances.isEmpty ? "No instance matches in \(target.place)." : instances.map { instance in
                "\(instance.id ?? "?")\(instance.name.map { " (\($0))" } ?? ""): \(instance.state ?? "?"), \(instance.type ?? "?"), \([instance.privateIP, instance.publicIP].compactMap { $0 }.joined(separator: " / ")), groups \(instance.securityGroups.joined(separator: ", "))\(instance.instanceProfile.map { ", profile \($0)" } ?? ""), launched \(instance.launched ?? "?")"
            }.joined(separator: "\n") + "\nRead \(target.place)."
            return try ServiceResult(text: text, structured: Found(instances: instances, account: target.account.id, region: target.region))
        }
    }

    /// An EC2 instance ID: i- and 8 or 17 hex digits.
    static func instanceID(_ value: String) throws -> String {
        let id = value.trimmingCharacters(in: .whitespaces)
        guard id.hasPrefix("i-"), [10, 19].contains(id.count), id.dropFirst(2).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ServiceError.input("Give an instance ID such as i-0abc1234def567890.")
        }
        return id
    }

    struct OpenSecurityGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let region: String?, account: String? }
        static let name = "open-security-groups"
        static let summary = "Security groups that let anyone on the internet in, over IPv4 (0.0.0.0/0) or IPv6 (::/0), with the ports they open."
        static let input = JSONSchema.object(["region": AWS.regionInput, "account": AWS.accountInput])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            struct Rule: Encodable { let protocolName: String, ports: String, from: String }
            struct Group: Encodable { let id: String?, name: String?, vpc: String?, open: [Rule] }
            var groups: [String: Group] = [:], more = false
            // EC2 ANDs filters of different names, so IPv4 and IPv6 are asked for apart.
            for (filter, cidr) in [("ip-permission.cidr", "0.0.0.0/0"), ("ip-permission.ipv6-cidr", "::/0")] {
                var token: String?, pages = 0
                repeat {
                    var query: [String: String?] = ["Action": "DescribeSecurityGroups", "Version": "2016-11-15", "Filter.1.Name": filter, "Filter.1.Value.1": cidr, "MaxResults": "1000"]
                    if let token { query["NextToken"] = token }
                    let answer = try await AWS.read("EC2's security groups", needs: ["ec2:DescribeSecurityGroups"]) { try await target.client.xml([], query: query) }
                    pages += 1
                    for item in answer.child("securityGroupInfo")?.children ?? [] {
                        let rules = (item.child("ipPermissions")?.children ?? []).flatMap { permission in
                            let open = (permission.child("ipRanges")?.children ?? []).compactMap { $0.value("cidrIp") }.filter { $0 == "0.0.0.0/0" }
                                + (permission.child("ipv6Ranges")?.children ?? []).compactMap { $0.value("cidrIpv6") }.filter { $0 == "::/0" }
                            return open.map { from in
                                let low = permission.value("fromPort") ?? "all", high = permission.value("toPort") ?? low
                                let name = permission.value("ipProtocol") ?? "?"
                                return Rule(protocolName: name == "-1" ? "all" : name, ports: name == "-1" ? "all" : low == high ? low : "\(low)-\(high)", from: from)
                            }
                        }
                        guard let id = item.value("groupId") else { continue }
                        var known = rules
                        for rule in groups[id]?.open ?? [] where !known.contains(where: { $0.from == rule.from && $0.ports == rule.ports && $0.protocolName == rule.protocolName }) { known.append(rule) }
                        groups[id] = Group(id: id, name: item.value("groupName"), vpc: item.value("vpcId"), open: known)
                    }
                    token = answer.value("nextToken")
                } while token != nil && pages < AWS.maximumPages
                if token != nil { more = true }
            }
            let sorted = groups.values.sorted { ($0.id ?? "") < ($1.id ?? "") }
            var text = sorted.isEmpty ? "No security group in \(target.place) lets the whole internet in over IPv4 or IPv6." : sorted.map { group in
                "\(group.id ?? "?") (\(group.name ?? "?")): " + group.open.map { "\($0.protocolName) \($0.ports) from \($0.from)" }.joined(separator: ", ")
            }.joined(separator: "\n") + "\nRead \(target.place)."
            if more { text += "\nStopped after \(AWS.maximumPages) pages with more groups remaining, so some may be missing." }
            text += "\nNot checked: rules that let in a prefix list or another security group, and network ACLs."
            struct Found: Encodable { let groups: [Group]; let account: String; let region: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Found(groups: sorted, account: target.account.id, region: target.region, complete: !more))
        }
    }

    struct LogsInsights: ServiceOperation {
        struct Input: Decodable, Sendable { let logGroups: [String], query: String, since: String?, until: String?, limit: Int?, region: String?, account: String? }
        static let name = "logs-insights"
        static let summary = "Run a CloudWatch Logs Insights query over log groups, such as VPC Flow Logs or CloudTrail delivered to CloudWatch, saying how many records matched when more did than were returned. Read-only."
        static let input = JSONSchema.object([
            "logGroups": .array(.string("A log group name."), "Up to 10 log groups."),
            "query": .string("The Logs Insights query, ending with limit."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many rows, at most. 100 when left out.", minimum: 1, maximum: 1000),
            "region": AWS.regionInput, "account": AWS.accountInput,
        ], required: ["logGroups", "query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let groups = try ServiceInput.list(input.logGroups, limit: 10) { try ServiceInput.quoted($0, "the log group") }
            let window = try AWS.window(input.since, input.until, days: 1)
            let limit = try AWS.limit(input.limit, default: 100, maximum: 1000)
            let target = try await AWS.target(.logs, region: input.region, account: input.account, on: service)
            let started = try await AWS.read("starting the query", needs: ["logs:StartQuery"]) {
                try await AWS.call(target, operation: "Logs_20140328.StartQuery", body: [
                    "logGroupNames": groups, "queryString": try ServiceInput.query(input.query),
                    "startTime": Int(window.since.timeIntervalSince1970), "endTime": Int(window.until.timeIntervalSince1970), "limit": limit])
            }
            guard let id = AWS.text(started["queryId"]) else { throw ServiceError.unreadable }
            // Queries run on AWS; their results are read until they finish, for up to half a minute.
            for _ in 0..<30 {
                let results = try await AWS.read("the query's results", needs: ["logs:GetQueryResults"]) {
                    try await AWS.call(target, operation: "Logs_20140328.GetQueryResults", body: ["queryId": id])
                }
                switch AWS.text(results["status"]) {
                case "Complete":
                    let rows = AWS.items(results["results"]).map { AWS.items($0) }
                    var columns: [String] = []
                    for field in rows.flatMap({ $0 }).compactMap({ AWS.text($0["field"]) }) where !field.hasPrefix("@ptr") && !columns.contains(field) { columns.append(field) }
                    let table = try ServiceTable(columns: columns, rows: rows.map { row in
                        columns.map { column in row.first { AWS.text($0["field"]) == column }.flatMap { AWS.text($0["value"]) }.map(CellValue.text) ?? .none }
                    }).result()
                    let matched = AWS.number(results["statistics"]?["recordsMatched"]).map { Int($0) } ?? rows.count
                    var notice = "\nRan over \(GoogleCloud.listed(groups)) in \(target.place), from \(AWS.iso(window.since)) to \(AWS.iso(window.until))."
                    if matched > rows.count { notice += " \(matched) records matched; \(rows.count) rows were returned: summarize with stats, or narrow the query or time, to see the rest." }
                    return table.adding(notice)
                case let status? where ["Failed", "Cancelled", "Timeout"].contains(status): throw ServiceError.refused("the query \(status.lowercased())")
                default: try await Task.sleep(for: .seconds(1))
                }
            }
            throw ServiceError.refused("the query is still running; narrow it with a shorter time range or a limit")
        }
    }

    /// The region a regional operation may name.
    static let regionInput = JSONSchema.string("The region, when not the connection's default, such as us-east-1.")
    /// The account every operation may name.
    static let accountInput = JSONSchema.string("The account, by its 12-digit ID or its name, as accounts lists them. Needed unless the sign-in covers only one.")
}

extension AWS {
    /// A CloudTrail trail as the account sees it, its own or its organisation's, and whether it is logging.
    struct Trail: Encodable {
        let name: String, arn: String, homeRegion: String?, multiRegion: Bool, organization: Bool, logGroup: String?
        var logging: Bool?
    }

    static let trailService = "com.amazonaws.cloudtrail.v20131101.CloudTrail_20131101."

    /// The trails the account's CloudTrail lists in the target's region, those of other regions and of the organisation
    /// included, each with whether it is logging, reading at most `statuses` of them.
    static func trails(_ target: Target, statuses: Int = 5) async throws -> [Trail] {
        let listed = try await call(target, operation: trailService + "DescribeTrails", body: ["includeShadowTrails": true])
        var trails = items(listed["trailList"]).compactMap { json -> Trail? in
            guard let arn = text(json["TrailARN"]) else { return nil }
            return Trail(name: text(json["Name"]) ?? arn, arn: arn, homeRegion: text(json["HomeRegion"]), multiRegion: flag(json["IsMultiRegionTrail"]) ?? false,
                         organization: flag(json["IsOrganizationTrail"]) ?? false, logGroup: text(json["CloudWatchLogsLogGroupArn"]))
        }
        for index in trails.indices.prefix(statuses) {
            let status = try? await call(target, operation: trailService + "GetTrailStatus", body: ["Name": trails[index].arn])
            trails[index].logging = status.flatMap { flag($0["IsLogging"]) }
        }
        return trails
    }

    /// Tries each thing AWS Audit reads once in an account, and says what works, what to change for what does not,
    /// which of the services the watch relies on are on, and whether the role could change anything.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String? }
        static let name = "check-access"
        static let summary = "Tries each thing this tool reads once, in one account or the first five covered, IAM Identity Center, AWS Config's history, S3's bucket settings, Inspector and Macie included, and says what works and, for what does not, exactly which permission to add; whether GuardDuty, Security Hub (with its administrator and cross-region aggregation), AWS Config and an external access analyzer are on and CloudTrail trails are logging, as the watch relies on them; which regions are on; whether the role could change anything; and which of the organisation's accounts the sign-in does not cover. It changes nothing."
        static let input = JSONSchema.object(["account": .string("Only this account, by its ID or name. The first \(AWS.checkAccounts) the sign-in covers when left out.")])

        /// Changes the role should never be able to make, simulated against its own policies.
        static let changes = ["iam:CreateUser", "iam:CreateAccessKey", "iam:AttachRolePolicy", "iam:PutRolePolicy", "ec2:AuthorizeSecurityGroupIngress",
                              "ec2:TerminateInstances", "s3:PutBucketPolicy", "cloudtrail:StopLogging", "guardduty:DeleteDetector", "kms:ScheduleKeyDeletion"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let accounts = try await service.access.awsAccounts()
            let region = try service.setting("region")
            let chosen = input.account?.isEmpty == false ? [try await AWS.account(input.account, on: service).0] : Array(accounts.prefix(AWS.checkAccounts))
            guard !chosen.isEmpty else { throw ServiceError.input("The sign-in covers no AWS accounts: assign the permission set to accounts in IAM Identity Center.") }
            var lines: [String] = []
            if input.account?.isEmpty != false, accounts.count > chosen.count {
                lines.append("· Checked \(chosen.count) of the \(accounts.count) accounts the sign-in covers; name an account to check another.")
            }
            for account in chosen {
                lines.append("\(account.name) (\(account.id)), in \(region):")
                lines += await Self.check(account, region: region, on: service).map { "  " + $0 }
            }
            lines.append(await Self.organisation(chosen, covered: accounts, on: service))
            lines.append("· Logs Insights is not tried, as that would run a query: the permission set needs logs:StartQuery and logs:GetQueryResults for it.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }

        static func check(_ account: AWSAccount, region: String, on service: ServiceClient) async -> [String] {
            let base: Target
            do {
                base = Target(client: try await AWS.signed(account, on: service), account: account, region: region, service: .sts)
            } catch {
                return ["✗ Signing in as the role: \(error.localizedDescription) Assign the permission set to this account in IAM Identity Center."]
            }
            func probe(_ title: String, _ actions: [String], _ body: () async throws -> Void) async -> String {
                do { try await body(); return "✓ \(title)" }
                catch { return "✗ \(title): " + (AWS.fix(for: error, needs: actions) ?? error.localizedDescription) }
            }
            var lines: [String] = [], role: String?
            do {
                let me = try await base.at(.sts).client.xml([], query: ["Action": "GetCallerIdentity", "Version": "2011-06-15"])
                let arn = me.value("GetCallerIdentityResult", "Arn") ?? "?"
                lines.append("✓ Signed in as \(arn)")
                let parts = arn.split(separator: "/")
                if arn.contains(":assumed-role/"), parts.count >= 2 { role = String(parts[1]) }
            } catch {
                lines.append("✗ Who the role is: \(error.localizedDescription)")
            }
            lines.append(await probe("CloudTrail event history", ["cloudtrail:LookupEvents"]) {
                _ = try await AWS.send(try base.at(.cloudtrail), operation: AWS.lookupEvents, body: ["MaxResults": 1])
            })
            do {
                let trails = try await AWS.trails(try base.at(.cloudtrail))
                let logging = trails.filter { $0.logging == true }
                if trails.isEmpty {
                    lines.append("⚠ No CloudTrail trail: event history keeps 90 days of management events, but nothing is kept longer or sent elsewhere. Create an organisation trail for every region.")
                } else if logging.isEmpty {
                    lines.append("⚠ No CloudTrail trail is logging (\(trails.map(\.name).joined(separator: ", "))): start one, as nothing is kept past event history's 90 days.")
                } else {
                    lines.append("✓ CloudTrail trails logging: " + logging.map { trail in
                        let traits = [trail.multiRegion ? "every region" : "one region", trail.organization ? "the organisation's" : nil,
                                      trail.logGroup.map { _ in "to CloudWatch Logs" }].compactMap { $0 }
                        return trail.name + " (\(traits.joined(separator: ", ")))"
                    }.joined(separator: "; ") + ".")
                    if !logging.contains(where: \.multiRegion) { lines.append("⚠ No logging trail covers every region, so activity in other regions is kept only 90 days.") }
                }
            } catch {
                lines.append("✗ CloudTrail trails: " + (AWS.fix(for: error, needs: ["cloudtrail:DescribeTrails", "cloudtrail:GetTrailStatus"]) ?? error.localizedDescription))
            }
            do {
                let guardduty = try base.at(.guardduty)
                if let detector = try await AWS.detector(guardduty) {
                    let state = try await AWS.call(guardduty, ["detector", detector], method: "GET", body: nil)
                    let administrator = try? await AWS.call(guardduty, ["detector", detector, "administrator"], method: "GET", body: nil)
                    let admin = AWS.text(administrator?["administrator"]?["accountId"])
                    if AWS.text(state["status"]) == "ENABLED" {
                        lines.append("✓ GuardDuty is on" + (admin.map { ", with administrator account \($0)" } ?? "") + ".")
                    } else {
                        lines.append("⚠ GuardDuty's detector is suspended, so it finds nothing: turn it back on in the GuardDuty console.")
                    }
                } else {
                    lines.append("⚠ GuardDuty is off in \(region), so it finds nothing there and the watch has nothing of it to read: turn it on, ideally for the organisation from a delegated administrator.")
                }
            } catch {
                lines.append("✗ GuardDuty: " + (AWS.fix(for: error, needs: ["guardduty:ListDetectors", "guardduty:GetDetector", "guardduty:GetAdministratorAccount"]) ?? error.localizedDescription))
            }
            do {
                let hub = try base.at(.securityhub)
                _ = try await AWS.call(hub, ["accounts"], method: "GET", body: nil)
                let aggregators = try? await AWS.call(hub, ["findingAggregator", "list"], method: "GET", body: nil)
                let aggregated = AWS.items(aggregators?["FindingAggregators"]).compactMap { AWS.text($0["FindingAggregatorArn"]) }
                    .compactMap { $0.split(separator: ":", omittingEmptySubsequences: false).dropFirst(3).first.map(String.init) }
                let administrator = try? await AWS.call(hub, ["administrator"], method: "GET", body: nil)
                let admin = AWS.text(administrator?["Administrator"]?["AccountId"])
                lines.append("✓ Security Hub is on" + (admin.map { ", with administrator account \($0)" } ?? "")
                             + (aggregated.isEmpty ? "; it aggregates no other region, so its findings here are this region's alone." : "; it aggregates findings from other regions into \(aggregated.joined(separator: ", "))."))
            } catch let error where AWS.isOff(error) {
                lines.append("⚠ Security Hub is off in \(region), so the watch has none of its findings to read: turn it on, ideally for the organisation with cross-region aggregation.")
            } catch {
                lines.append("✗ Security Hub: " + (AWS.fix(for: error, needs: ["securityhub:DescribeHub", "securityhub:GetFindings"]) ?? error.localizedDescription))
            }
            do {
                let config = try await AWS.call(try base.at(.config), operation: "StarlingDoveService.DescribeConfigurationRecorderStatus", body: [:])
                let recorders = AWS.items(config["ConfigurationRecordersStatus"])
                lines.append(recorders.contains { AWS.flag($0["recording"]) == true }
                             ? "✓ AWS Config is recording." : "⚠ AWS Config is not recording in \(region), so resources' past configurations are not kept.")
            } catch {
                lines.append("✗ AWS Config: " + (AWS.fix(for: error, needs: ["config:DescribeConfigurationRecorderStatus"]) ?? error.localizedDescription))
            }
            do {
                let analyzers = AWS.items(try await AWS.call(try base.at(.accessAnalyzer), ["analyzer"], method: "GET", body: nil)["analyzers"])
                    .filter { AWS.text($0["status"]) == "ACTIVE" }.compactMap { AWS.text($0["type"]) }
                lines.append(analyzers.contains("ORGANIZATION") || analyzers.contains("ACCOUNT")
                             ? "✓ IAM Access Analyzer: \(analyzers.joined(separator: ", ")) analyzers active."
                             : "⚠ No external access analyzer in \(region), so access-analyzer-findings finds nothing there: create one in IAM Access Analyzer.")
            } catch {
                lines.append("✗ IAM Access Analyzer: " + (AWS.fix(for: error, needs: ["access-analyzer:ListAnalyzers"]) ?? error.localizedDescription))
            }
            lines.append(await probe("IAM", ["iam:GetAccountSummary", "iam:GetAccountAuthorizationDetails"]) {
                _ = try await base.at(.iam).client.xml([], query: ["Action": "GetAccountSummary", "Version": "2010-05-08"])
            })
            lines.append(await probe("EC2", ["ec2:DescribeRegions", "ec2:DescribeInstances", "ec2:DescribeSecurityGroups"]) {
                _ = try await base.at(.ec2).client.xml([], query: ["Action": "DescribeRegions", "Version": "2016-11-15"])
            })
            lines.append(await probe("CloudWatch Logs", ["logs:DescribeLogGroups"]) {
                _ = try await AWS.send(try base.at(.logs), operation: "Logs_20140328.DescribeLogGroups", body: ["limit": 1])
            })
            lines += await Self.investigation(base)
            lines.append(await Self.writes(base, role: role))
            return lines
        }

        /// The reads the deeper lookups take: IAM's authorization details and credential report, AWS Config's history,
        /// S3's bucket settings, Identity Center's assignments, and Inspector's and Macie's findings, each tried once.
        static func investigation(_ base: Target) async -> [String] {
            func probe(_ title: String, _ actions: [String], _ body: () async throws -> Void) async -> String {
                do { try await body(); return "✓ \(title)" }
                catch { return "✗ \(title): " + (AWS.fix(for: error, needs: actions) ?? error.localizedDescription) }
            }
            var lines: [String] = []
            lines.append(await probe("IAM's authorization details, for iam-access", ["iam:GetAccountAuthorizationDetails"]) {
                _ = try await base.at(.iam).client.xml([], query: ["Action": "GetAccountAuthorizationDetails", "Version": "2010-05-08", "MaxItems": "1", "Filter.member.1": "Role"])
            })
            lines.append(await probe("The credential report, for credential-report and credential-hygiene", ["iam:GenerateCredentialReport", "iam:GetCredentialReport"]) {
                do { _ = try await base.at(.iam).client.xml([], query: ["Action": "GetCredentialReport", "Version": "2010-05-08"]) }
                // No report made lately is no refusal: the lookups make one.
                catch ServiceError.status(_, let reason?) where reason.contains("ReportNotPresent") || reason.contains("ReportExpired") || reason.contains("ReportInProgress") {}
                catch ServiceError.refused(let reason) where reason.contains("ReportNotPresent") || reason.contains("ReportExpired") || reason.contains("ReportInProgress") {}
            })
            lines.append(await probe("AWS Config's recorders and history, for config-history", ["config:DescribeConfigurationRecorders", "config:GetResourceConfigHistory"]) {
                _ = try await AWS.call(try base.at(.config), operation: "StarlingDoveService.DescribeConfigurationRecorders", body: [:])
            })
            lines.append(await probe("S3's buckets and Block Public Access, for s3-exposure", ["s3:ListAllMyBuckets", "s3:GetAccountPublicAccessBlock", "s3:GetBucketPolicyStatus",
                                                                                              "s3:GetBucketPolicy", "s3:GetBucketAcl", "s3:GetBucketOwnershipControls", "s3:GetBucketPublicAccessBlock"]) {
                _ = try await base.at(.s3).client.xml([], query: ["max-buckets": "1"])
                let control = try base.at(.s3Control)
                let answer = try await control.client.exchange(["v20180820", "configuration", "publicAccessBlock"], headers: ["x-amz-account-id": base.account.id], returning: [404])
                if answer.response.statusCode == 404, !(ServiceClient.reason(answer.data) ?? "").contains("NoSuchPublicAccessBlockConfiguration") { throw ServiceError.notFound }
            })
            do {
                let instances = AWS.items(try await AWS.call(try base.at(.sso), operation: "SWBExternalService.ListInstances", body: [:])["Instances"])
                lines.append(instances.isEmpty ? "· IAM Identity Center: no instance answers in \(base.region) from this account; identity-center-assignments needs Identity Center's region, read from the management account or its delegated administrator."
                                               : "✓ IAM Identity Center's assignments, for identity-center-assignments.")
            } catch {
                lines.append(AWS.isDenied(error)
                             ? "· IAM Identity Center's assignments: refused here. Only the organisation's management account or Identity Center's delegated administrator may read them; in that account, the permission set needs sso:List*, sso:Describe*, sso:GetInlinePolicyForPermissionSet and identitystore:Describe*, GetUserId, GetGroupId and ListGroupMembershipsForMember."
                             : "✗ IAM Identity Center's assignments: \(error.localizedDescription)")
            }
            for (title, service, path, actions, body) in [("Amazon Inspector", Service.inspector2, ["findings", "list"], ["inspector2:ListFindings"], ["maxResults": 1] as [String: Any]),
                                                          ("Amazon Macie", Service.macie2, ["findings"], ["macie2:ListFindings", "macie2:GetFindings"], ["maxResults": 1] as [String: Any])] {
                do {
                    _ = try await AWS.call(try base.at(service), path, body: body)
                    lines.append("✓ \(title)'s findings.")
                } catch let error where AWS.isOff(error) {
                    lines.append("· \(title) is off in \(base.region), so it finds nothing there.")
                } catch {
                    lines.append("✗ \(title)'s findings: " + (AWS.fix(for: error, needs: actions) ?? error.localizedDescription))
                }
            }
            return lines
        }

        /// Whether the role could change anything, simulated against its own policies; SCPs and permission boundaries
        /// are not part of it, so it can only say more is allowed than may be.
        static func writes(_ base: Target, role: String?) async -> String {
            guard let role else { return "· Whether the role could change anything: not checked, as its role is not known." }
            do {
                let iam = try base.at(.iam)
                let read = try await iam.client.xml([], query: ["Action": "GetRole", "Version": "2010-05-08", "RoleName": role])
                guard let arn = read.value("GetRoleResult", "Role", "Arn") else { throw ServiceError.unreadable }
                var query: [String: String?] = ["Action": "SimulatePrincipalPolicy", "Version": "2010-05-08", "PolicySourceArn": arn]
                for (index, action) in changes.enumerated() { query["ActionNames.member.\(index + 1)"] = action }
                let simulated = try await iam.client.xml([], query: query)
                let allowed = simulated.all("member").filter { $0.value("EvalDecision") == "allowed" }.compactMap { $0.value("EvalActionName") }
                return allowed.isEmpty
                    ? "✓ The role cannot make changes such as \(changes.prefix(3).joined(separator: ", ")), by its own policies."
                    : "⚠ The role can change the account: its policies allow \(allowed.joined(separator: ", ")). AWS Audit only reads, so give its permission set only SecurityAudit and the inline policy from Setup Steps; AWS Containment has a permission set of its own."
            } catch {
                return "· Whether the role could change anything: not checked (\(AWS.fix(for: error, needs: ["iam:GetRole", "iam:SimulatePrincipalPolicy"]) ?? error.localizedDescription))"
            }
        }

        /// The organisation's accounts the sign-in does not cover, read from the first account that may list them.
        static func organisation(_ chosen: [AWSAccount], covered: [AWSAccount], on service: ServiceClient) async -> String {
            var said: String?
            for account in chosen {
                do {
                    let organizations = try Target(client: try await AWS.signed(account, on: service), account: account, region: "us-east-1", service: .organizations).at(.organizations)
                    var listed: [(String, String)] = [], token: String?, pages = 0
                    repeat {
                        var body: [String: Any] = [:]
                        if let token { body["NextToken"] = token }
                        let answer = try await AWS.call(organizations, operation: "AWSOrganizationsV20161128.ListAccounts", body: body)
                        pages += 1
                        listed += AWS.items(answer["Accounts"]).compactMap { json in
                            AWS.text(json["Id"]).map { ($0, AWS.text(json["Name"]) ?? $0) }
                        }
                        token = AWS.text(answer["NextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                    } while token != nil && pages < AWS.maximumPages
                    let known = Set(covered.map(\.id))
                    let missing = listed.filter { !known.contains($0.0) }
                    let more = token != nil ? " It stopped after \(pages) pages with more accounts remaining." : ""
                    return missing.isEmpty
                        ? "✓ The sign-in covers every account of the organisation's \(listed.count).\(more)"
                        : "⚠ The sign-in does not cover \(missing.count) of the organisation's \(listed.count) accounts, so nothing in them is read or watched: \(missing.prefix(10).map { "\($0.1) (\($0.0))" }.joined(separator: ", "))\(missing.count > 10 ? " and more" : ""). Assign the permission set to them in IAM Identity Center.\(more)"
                } catch let error where AWS.isOff(error) {
                    return "· The accounts are not in an AWS organisation, so there is no wider list to compare with."
                } catch {
                    said = error.localizedDescription
                }
            }
            return "· Whether the sign-in covers every account of the organisation: not checked, as only the management account or a delegated administrator may list them\(said.map { " (AWS said: \($0))" } ?? "")."
        }
    }
}
