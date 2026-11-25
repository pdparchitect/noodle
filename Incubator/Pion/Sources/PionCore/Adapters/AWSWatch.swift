import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// AWS Detection's alert watch, and security-events, which reads back what woke the agents, the same way for both: high
/// and critical GuardDuty and Security Hub findings that are not archived, suppressed or resolved, and the CloudTrail
/// changes that open the way in or hide what follows, in each watched account's default region and, for CloudTrail,
/// in us-east-1 too, where IAM, STS, Organizations and console sign-ins are logged.
extension AWS {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Limits

    /// The most accounts the watch reads, the lowest account IDs first; security-events reads any one named.
    static let watchAccounts = 10
    /// The most pages of each feed one check of the watch reads, and one call of security-events: CloudTrail's event
    /// history answers two requests a second for an account and region, so the watch leaves most for investigations.
    static let watchPages = 4, eventsPages = 10

    // MARK: Feeds

    enum FeedKind: String, Sendable, CaseIterable {
        case securityhub, guardduty, cloudtrail

        var service: Service {
            switch self {
            case .securityhub: .securityhub
            case .guardduty: .guardduty
            case .cloudtrail: .cloudtrail
            }
        }

        var title: String {
            switch self {
            case .securityhub: "Security Hub's findings"
            case .guardduty: "GuardDuty's findings"
            case .cloudtrail: "CloudTrail's event history"
            }
        }
    }

    /// One feed the watch reads: one service in one region of one account.
    struct Feed: Hashable, Sendable {
        let kind: FeedKind, account: AWSAccount, region: String

        /// How the watch's state and notices name it: its kind, a digest of its account and its region, nothing AWS wrote.
        var label: String { "\(kind.rawValue)/\(AWS.accountTag(account.id))/\(region)" }
        var title: String { "\(kind.title) of \(account.name) (\(account.id)) in \(region)" }

        static func == (first: Feed, second: Feed) -> Bool { first.label == second.label }
        func hash(into hasher: inout Hasher) { hasher.combine(label) }
    }

    static func accountTag(_ id: String) -> String { String(safeID("", id).prefix(12)) }

    /// An account's feeds: Security Hub, GuardDuty and CloudTrail in the region, and CloudTrail in us-east-1 too.
    static func feeds(_ account: AWSAccount, region: String) -> [Feed] {
        [Feed(kind: .securityhub, account: account, region: region), Feed(kind: .guardduty, account: account, region: region),
         Feed(kind: .cloudtrail, account: account, region: region)]
            + (region == "us-east-1" ? [] : [Feed(kind: .cloudtrail, account: account, region: "us-east-1")])
    }

    /// What one read of one feed found, and how far it got.
    struct FeedRead {
        var events: [WatchedEvent] = []
        /// Read whole: every page, nothing refused.
        var complete = false
        /// More remained than the pages it may read.
        var cut = false
        /// Why it could not be read.
        var error: Error? = nil
        /// Why the service has nothing to read here, such as GuardDuty with no detector, said as what to change.
        var off: String? = nil
        /// For Security Hub cut short: how to go on with the same query from where it stopped.
        var next: Continuation? = nil
        /// The query this read went on with, when it was one a check before had cut short.
        var resumed: Continuation? = nil
    }

    /// A Security Hub query cut short, to go on with: AWS's token for its next page, and the window it was asked for, as a
    /// token is good only with the query it came from. Findings made at the same moment have no order between them, so
    /// only the token, never a time, says where the query stopped.
    struct Continuation: Sendable, Equatable {
        let token: String, since: Date, until: Date
        /// The oldest of what its pages found but the checks had no room to return.
        var owed: Date? = nil
    }

    /// The ID a finding wakes with: Security Hub lists GuardDuty's findings by GuardDuty's own ARN, so one finding read
    /// from both is one.
    static func findingID(_ id: String) -> String { safeID("finding/", id) }

    // MARK: Security Hub

    /// Security Hub's open critical and high findings made from `since` to `until`, oldest first, from the start or, for
    /// a query a check before cut short, from its token.
    static func readSecurityHub(_ target: Target, since: Date, until: Date, pages: Int, from continuation: Continuation? = nil) async -> FeedRead {
        var read = FeedRead(resumed: continuation), token = continuation?.token, count = 0
        let (since, until) = continuation.map { ($0.since, $0.until) } ?? (since, until)
        let equals = { (values: [String]) in values.map { ["Value": $0, "Comparison": "EQUALS"] } }
        do {
            repeat {
                // By when each was made, as products update theirs every day, which is no news; oldest first, so a query
                // cut short has returned the oldest.
                var body: [String: Any] = ["Filters": ["RecordState": equals(["ACTIVE"]), "WorkflowStatus": equals(openWorkflow),
                                                       "SeverityLabel": equals(["CRITICAL", "HIGH"]),
                                                       "CreatedAt": [["Start": iso(since), "End": iso(until)]]],
                                           "SortCriteria": [["Field": "CreatedAt", "SortOrder": "asc"]], "MaxResults": 100]
                if let token { body["NextToken"] = token }
                let answer = try await call(target, ["findings"], body: body)
                count += 1
                for finding in items(answer["Findings"]).compactMap(SecurityHubFinding.init) {
                    guard finding.recordState ?? "ACTIVE" == "ACTIVE", openWorkflow.contains(finding.workflow ?? "NEW"),
                          let severity = finding.severity, ["CRITICAL", "HIGH"].contains(severity),
                          let time = ServiceAlert.time(finding.createdAt), time >= since, time <= until else { continue }
                    read.events.append(WatchedEvent(id: findingID(finding.id), time: iso(time), tier: severity == "CRITICAL" ? 0 : 1,
                                                    kind: "Security Hub \(severity.lowercased()) finding", feed: "",
                                                    line: "\(iso(time)) Security Hub \(severity.lowercased()) finding in \(target.place): \(finding.line(account: target.account.id))"))
                }
                token = text(answer["NextToken"]).flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && count < pages
            read.cut = token != nil
            read.complete = !read.cut
            read.next = token.map { Continuation(token: $0, since: since, until: until, owed: continuation?.owed) }
        } catch {
            if isOff(error) {
                read.off = "Security Hub is off in \(target.place), so its findings, and those of GuardDuty, Inspector, Macie and Config it gathers, are not watched there: turn it on, ideally for the organisation with cross-region aggregation into \(target.region)."
                read.complete = true
            } else {
                read.error = error
            }
        }
        return read
    }

    // MARK: GuardDuty

    static func readGuardDuty(_ target: Target, since: Date, until: Date, pages: Int) async -> FeedRead {
        var read = FeedRead()
        do {
            guard let detector = try await detector(target) else {
                read.off = "GuardDuty is off in \(target.place): it has no detector there, so it finds nothing there to wake for. Turn it on, ideally for the organisation from a delegated administrator."
                read.complete = true
                return read
            }
            let state = try await call(target, ["detector", detector], method: "GET", body: nil)
            if let status = text(state["status"]), status != "ENABLED" {
                read.off = "GuardDuty's detector in \(target.place) is suspended, so it finds nothing there: turn it back on in the GuardDuty console."
                read.complete = true
                return read
            }
            let criterion: [String: Any] = ["severity": ["gte": 7], "service.archived": ["eq": ["false"]],
                                            "updatedAt": ["gte": Int(since.timeIntervalSince1970 * 1_000), "lte": Int(until.timeIntervalSince1970 * 1_000)]]
            var ids: [String] = [], token: String?, count = 0
            repeat {
                var body: [String: Any] = ["findingCriteria": ["criterion": criterion], "maxResults": 50,
                                           "sortCriteria": ["attributeName": "updatedAt", "orderBy": "ASC"]]
                if let token { body["nextToken"] = token }
                let answer = try await call(target, ["detector", detector, "findings"], body: body)
                count += 1
                ids += items(answer["findingIds"]).compactMap(\.text)
                token = text(answer["nextToken"]).flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && count < pages
            for finding in try await guardDutyFindings(target, detector: detector, ids: ids) {
                guard finding.archived != true, (finding.severity ?? 0) >= 7, let time = ServiceAlert.time(finding.updatedAt), time >= since, time <= until else { continue }
                read.events.append(WatchedEvent(id: findingID(finding.arn ?? finding.id), time: iso(time), tier: (finding.severity ?? 0) >= 9 ? 0 : 1,
                                                kind: "GuardDuty \(finding.severityLabel.lowercased()) finding", feed: "",
                                                line: "\(iso(time)) GuardDuty finding in \(target.place): \(finding.line(account: target.account.id))"))
            }
            read.cut = token != nil
            read.complete = !read.cut
        } catch {
            read.error = error
        }
        return read
    }

    // MARK: CloudTrail

    /// Changes to an account's AWS that the watch wakes for, the most pressing first: tier 0 takes over or hides,
    /// tier 1 opens or loosens, tier 2 may have done either, but the event does not show what.
    static func judge(_ detail: JSON, covered: Set<String>) -> (tier: Int, kind: String, what: String)? {
        guard text(detail["errorCode"]) == nil else { return nil }
        let name = text(detail["eventName"]) ?? "", source = text(detail["eventSource"]) ?? ""
        let identity = detail["userIdentity"], request = detail["requestParameters"]
        let own = text(detail["recipientAccountId"]) ?? text(identity?["accountId"])
        if text(identity?["type"]) == "Root", identity?["invokedBy"] == nil,
           name != "ConsoleLogin" || text(detail["responseElements"]?["ConsoleLogin"]) == "Success" {
            return (0, "root activity", name == "ConsoleLogin" ? "root signed in to the console" : "root called \(name)")
        }
        func any(_ names: String...) -> Bool { names.contains(name) }
        switch source {
        case "signin.amazonaws.com":
            guard name == "ConsoleLogin", text(detail["responseElements"]?["ConsoleLogin"]) == "Success", text(identity?["type"]) == "IAMUser",
                  text(detail["additionalEventData"]?["MFAUsed"]) == "No" else { return nil }
            return (0, "console sign-in without MFA", "IAM user signed in to the console without MFA")
        case "iam.amazonaws.com":
            switch name {
            case "CreateUser": return (1, "IAM user made", "IAM user made")
            case "CreateLoginProfile", "UpdateLoginProfile": return (0, "console password set", "console password set for an IAM user")
            case "CreateAccessKey": return (0, "access key made", "access key made")
            case "AttachUserPolicy", "AttachGroupPolicy", "AttachRolePolicy":
                let arn = text(request?["policyArn"]) ?? ""
                return ["AdministratorAccess", "IAMFullAccess", "PowerUserAccess"].first { arn.hasSuffix(":policy/\($0)") }
                    .map { (0, "administrator policy granted", "\($0) attached") }
            case "PutUserPolicy", "PutGroupPolicy", "PutRolePolicy":
                guard let document = embedded(request?["policyDocument"]) else { return (2, "policy changed", "inline policy put; the event does not show it") }
                return allowsAdministration(document) ? (0, "administrator policy granted", "inline policy allowing every action or all of IAM put") : nil
            case "CreatePolicyVersion":
                guard flag(request?["setAsDefault"]) == true else { return nil }
                return (1, "policy changed", "managed policy's default version replaced"
                        + (embedded(request?["policyDocument"]).map(allowsAdministration) == true ? " with one allowing every action or all of IAM" : ""))
            case "SetDefaultPolicyVersion": return (1, "policy changed", "managed policy's default version changed")
            case "UpdateAssumeRolePolicy", "CreateRole":
                let document = embedded(request?["policyDocument"]) ?? embedded(request?["assumeRolePolicyDocument"])
                guard let document else { return name == "UpdateAssumeRolePolicy" ? (2, "role trust changed", "role trust policy changed; the event does not show it") : nil }
                return opened(document, own: own, covered: covered).map { (0, "role trust opened", "role made assumable by \($0)") }
            case "DeactivateMFADevice", "DeleteVirtualMFADevice": return (0, "MFA removed", "MFA device removed")
            default: return nil
            }
        case "sso.amazonaws.com":
            guard any("CreatePermissionSet", "AttachManagedPolicyToPermissionSet", "PutInlinePolicyToPermissionSet", "CreateAccountAssignment",
                      "AttachCustomerManagedPolicyReferenceToPermissionSet") else { return nil }
            return (1, "Identity Center access changed", "IAM Identity Center \(name)")
        case "cloudtrail.amazonaws.com":
            if any("StopLogging", "DeleteTrail", "DeleteEventDataStore", "StopEventDataStoreIngestion") { return (0, "logging turned off", "CloudTrail \(name)") }
            if any("UpdateTrail", "PutEventSelectors", "UpdateEventDataStore") { return (1, "logging changed", "CloudTrail \(name)") }
            return nil
        case "ec2.amazonaws.com":
            switch name {
            case "DeleteFlowLogs": return (0, "logging turned off", "VPC flow logs deleted")
            case "AuthorizeSecurityGroupIngress":
                return anyText(request) { $0 == "0.0.0.0/0" || $0 == "::/0" } ? (1, "network opened to the internet", "security group opened to the internet") : nil
            case "ModifySnapshotAttribute":
                return anyText(request?["createVolumePermission"]?["add"]) { $0 == "all" } ? (1, "snapshot made public", "EBS snapshot made public") : nil
            case "ModifyImageAttribute":
                return anyText(request?["launchPermission"]?["add"]) { $0 == "all" } ? (1, "image made public", "machine image made public") : nil
            default: return nil
            }
        case "logs.amazonaws.com":
            return name == "DeleteLogGroup" ? (1, "logging turned off", "CloudWatch log group deleted") : nil
        case "guardduty.amazonaws.com":
            switch name {
            case "DeleteDetector": return (0, "detection turned off", "GuardDuty detector deleted")
            case "UpdateDetector": return flag(request?["enable"]) == false ? (0, "detection turned off", "GuardDuty detector suspended") : nil
            case "DisassociateFromMasterAccount", "DisassociateFromAdministratorAccount", "DisassociateMembers", "DeleteMembers":
                return (1, "detection turned off", "GuardDuty \(name)")
            case "CreateFilter", "UpdateFilter":
                return text(request?["action"])?.uppercased() == "ARCHIVE" ? (0, "findings hidden", "GuardDuty filter that archives findings made") : nil
            default: return nil
            }
        case "securityhub.amazonaws.com":
            if name == "DisableSecurityHub" { return (0, "detection turned off", "Security Hub turned off") }
            if any("BatchDisableStandards", "DisassociateFromAdministratorAccount", "DisassociateFromMasterAccount") { return (1, "detection turned off", "Security Hub \(name)") }
            return nil
        case "config.amazonaws.com":
            return any("StopConfigurationRecorder", "DeleteConfigurationRecorder", "DeleteDeliveryChannel") ? (0, "detection turned off", "AWS Config \(name)") : nil
        case "access-analyzer.amazonaws.com":
            return name == "DeleteAnalyzer" ? (1, "detection turned off", "IAM Access Analyzer analyzer deleted") : nil
        case "s3.amazonaws.com":
            switch name {
            case "PutBucketPolicy":
                guard let policy = embedded(request?["bucketPolicy"]) else { return (2, "bucket policy changed", "bucket policy changed; the event does not show it") }
                return opened(policy, own: own, covered: covered).map { _ in (1, "bucket opened", "bucket policy lets anyone in, unless a condition limits it") }
            case "PutBucketAcl":
                let canned = text(request?["x-amz-acl"]) ?? ""
                return ["public-read", "public-read-write", "authenticated-read"].contains(canned)
                    || anyText(request) { $0.hasSuffix("/groups/global/AllUsers") || $0.hasSuffix("/groups/global/AuthenticatedUsers") }
                    ? (1, "bucket opened", "bucket ACL grants everyone access") : nil
            case "DeleteBucketPublicAccessBlock", "DeleteAccountPublicAccessBlock", "DeletePublicAccessBlock":
                return (1, "bucket opened", "S3 Block Public Access removed")
            case "PutBucketPublicAccessBlock", "PutAccountPublicAccessBlock", "PutPublicAccessBlock":
                return anyFalse(request?["PublicAccessBlockConfiguration"] ?? request) ? (1, "bucket opened", "S3 Block Public Access loosened") : nil
            default: return nil
            }
        case "rds.amazonaws.com":
            guard any("ModifyDBSnapshotAttribute", "ModifyDBClusterSnapshotAttribute"), text(request?["attributeName"]) == "restore",
                  items(request?["valuesToAdd"]).contains(where: { $0.text == "all" }) else { return nil }
            return (1, "snapshot made public", "database snapshot made public")
        case "kms.amazonaws.com":
            switch name {
            case "DisableKey": return (0, "KMS key disabled", "KMS key disabled")
            case "ScheduleKeyDeletion": return (0, "KMS key disabled", "KMS key scheduled for deletion")
            case "PutKeyPolicy": return (1, "KMS key policy changed", "KMS key policy replaced")
            default: return nil
            }
        case "organizations.amazonaws.com":
            if any("LeaveOrganization", "DeleteOrganization") { return (0, "organisation changed", "Organizations \(name)") }
            if any("DetachPolicy", "DeletePolicy", "DisablePolicyType") { return (1, "guardrail removed", "service control policy: \(name)") }
            return nil
        case "ssm.amazonaws.com":
            return any("SendCommand", "StartSession") ? (1, "command run on an instance", "Systems Manager \(name); the event does not show the command") : nil
        default:
            return nil
        }
    }

    /// Whether any text anywhere in `json` matches.
    static func anyText(_ json: JSON?, _ match: (String) -> Bool) -> Bool {
        switch json {
        case .string(let text)?: return match(text)
        case .array(let values)?: return values.contains { anyText($0, match) }
        case .object(let values)?: return values.values.contains { anyText($0, match) }
        default: return false
        }
    }

    /// Whether any Block Public Access setting is turned off.
    static func anyFalse(_ json: JSON?) -> Bool {
        ["BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"].contains { flag(json?[$0]) == false }
    }

    static func statements(_ document: JSON) -> [JSON] {
        if case .array(let list)? = document["Statement"] { return list }
        return document["Statement"].map { [$0] } ?? []
    }

    static func strings(_ value: JSON?) -> [String] {
        switch value {
        case .string(let text)?: [text]
        case .array(let list)?: list.compactMap(\.text)
        default: []
        }
    }

    /// Whether a policy allows every action, or all of IAM, on every resource, or everything but a few with NotAction.
    static func allowsAdministration(_ document: JSON) -> Bool {
        statements(document).contains { statement in
            text(statement["Effect"]) == "Allow" && strings(statement["Resource"]).contains("*")
                && (strings(statement["Action"]).contains { ["*", "*:*", "iam:*"].contains($0) } || statement["NotAction"] != nil)
        }
    }

    /// Who a resource or trust policy lets in from outside the covered accounts: anyone, another account, or an identity
    /// provider whose tokens are not limited to a subject; nil when none.
    static func opened(_ document: JSON, own: String?, covered: Set<String>) -> String? {
        var who: [String] = []
        for statement in statements(document) where text(statement["Effect"]) == "Allow" {
            let principal = statement["Principal"]
            if principal?.text == "*" { who.append("anyone"); continue }
            for arn in strings(principal?["AWS"]) {
                if arn == "*" { who.append("anyone"); continue }
                let account = AWS.IAMAccess.account(arn)
                if account != own, !covered.contains(account) { who.append("account \(account)") }
            }
            if !strings(principal?["Federated"]).isEmpty {
                var conditions: [String] = []
                if case .object(let operators)? = statement["Condition"] {
                    for case .object(let keys) in operators.values { conditions += keys.keys }
                }
                if !conditions.contains(where: { $0.lowercased().hasSuffix(":sub") }) && !strings(principal?["Federated"]).contains(where: { $0.contains("saml-provider") }) {
                    who.append("an identity provider's tokens for any subject")
                }
            }
        }
        let unique = Array(NSOrderedSet(array: who)) as? [String] ?? who
        return unique.isEmpty ? nil : GoogleCloud.listed(unique)
    }

    static func readCloudTrail(_ target: Target, since: Date, until: Date, pages: Int, covered: Set<String>) async -> FeedRead {
        var read = FeedRead(), token: String?, count = 0
        do {
            repeat {
                // Only changes: CloudTrail takes one attribute at a time, and ReadOnly false leaves out the reads,
                // which are most of it. Each change is judged here and only what it did is kept.
                var body: [String: Any] = ["LookupAttributes": [["AttributeKey": "ReadOnly", "AttributeValue": "false"]],
                                           "StartTime": Int(since.timeIntervalSince1970), "EndTime": Int(until.timeIntervalSince1970.rounded(.up)), "MaxResults": 50]
                if let token { body["NextToken"] = token }
                let answer = try decode(CloudTrailEvents.Answer.self, try await send(target, operation: lookupEvents, body: body))
                count += 1
                for event in answer.Events ?? [] {
                    guard let id = event.EventId, let seconds = event.EventTime, let detail = embedded(event.CloudTrailEvent.map(JSON.string)),
                          let judged = judge(detail, covered: covered) else { continue }
                    let time = Date(timeIntervalSince1970: seconds)
                    guard time >= since.addingTimeInterval(-1), time <= until.addingTimeInterval(1) else { continue }
                    let kept = CloudTrailEvents.kept(event, region: target.region)
                    read.events.append(WatchedEvent(id: safeID("cloudtrail/", id), time: iso(time), tier: judged.tier, kind: judged.kind, feed: "",
                                                    line: "\(iso(time)) \(judged.what) in \(target.named): \(CloudTrailEvents.line(kept, account: target.account.id)) [\(id)]"))
                }
                token = answer.NextToken.flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && count < pages
            read.cut = token != nil
            read.complete = !read.cut
        } catch {
            read.error = error
        }
        return read
    }

    // MARK: Every feed

    /// What one read of every feed found, and what it could not read.
    struct WatchRead {
        var reads: [(feed: Feed, read: FeedRead)] = []
        /// By account, why its trails say nothing is being kept, or nil when one is logging; only those read.
        var trails: [String: String?] = [:]
        var trailErrors: [String: Error] = [:]
        /// Every event once, with the feed it was first read from.
        var events: [WatchedEvent] {
            var seen = Set<String>()
            return reads.flatMap { feed, read in read.events.compactMap { event in
                seen.insert(event.id).inserted ? WatchedEvent(id: event.id, time: event.time, tier: event.tier, kind: event.kind, feed: feed.label, line: event.line) : nil
            } }
        }
        var nothingRead: Bool { !reads.contains { $0.read.error == nil } }
    }

    /// Every feed of `accounts`, each from its own `start` to `until`, within `pages` each, and the trails of
    /// `trailAccounts`; each is kept when another cannot be read, the same for the watch and security-events, so what
    /// woke the agents reads back the same.
    static func watchRead(_ service: ServiceClient, accounts: [AWSAccount], covered: [AWSAccount], region: String, until: Date, pages: Int,
                          trailAccounts: Set<String>, continuations: [String: Continuation] = [:], start: (Feed) -> Date) async -> WatchRead {
        var read = WatchRead()
        let known = Set(covered.map(\.id))
        for account in accounts {
            let signed: ServiceClient
            do {
                signed = try await AWS.signed(account, on: service)
            } catch {
                for feed in feeds(account, region: region) { read.reads.append((feed, FeedRead(error: error))) }
                continue
            }
            let base = Target(client: signed, account: account, region: region, service: .sts)
            for feed in feeds(account, region: region) {
                let from = start(feed)
                let result: FeedRead
                do {
                    let target = try base.at(feed.kind.service, region: feed.region)
                    switch feed.kind {
                    case .securityhub: result = await readSecurityHub(target, since: from, until: until, pages: pages, from: continuations[feed.label])
                    case .guardduty: result = await readGuardDuty(target, since: from, until: until, pages: pages)
                    case .cloudtrail: result = await readCloudTrail(target, since: from, until: until, pages: pages, covered: known)
                    }
                } catch {
                    result = FeedRead(error: error)
                }
                read.reads.append((feed, result))
            }
            if trailAccounts.contains(account.id) {
                do {
                    let trails = try await AWS.trails(try base.at(.cloudtrail))
                    let said: String? = trails.contains { $0.logging == true } ? nil
                        : "no CloudTrail trail is logging in \(base.named), so nothing is kept past event history's 90 days or sent elsewhere: start an organisation trail for every region."
                    read.trails.updateValue(said, forKey: account.id)
                } catch {
                    read.trailErrors[account.id] = error
                }
            }
        }
        return read
    }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: regions other than the connection's default region, except CloudTrail in us-east-1 (Security Hub's cross-region aggregation into the default region brings its findings from the rest); medium and low findings; CloudTrail data events, such as objects read from S3, and reads, including root's; failed calls; STS role sessions, such as roles assumed from outside the organisation, which cloudtrail-events finds with eventName AssumeRole; and accounts the sign-in does not cover. Within an account, CloudTrail is read from its event history, which keeps 90 days."

    static func uncovered(_ accounts: [AWSAccount]) -> String {
        "Not watched: \(accounts.count) more account\(accounts.count == 1 ? "" : "s") the sign-in covers, past the first \(watchAccounts) by ID: \(listing(accounts)); read one with security-events and its account."
    }

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String?, account: String? }
        static let name = "security-events"
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: high and critical GuardDuty and Security Hub findings that are not archived, suppressed or resolved, and CloudTrail changes that open the way in or hide what follows: root activity, console sign-ins without MFA, IAM users, passwords and access keys made, administrator policies granted, role trust opened outside the organisation, MFA removed, Identity Center access changed, logging and detection turned off or findings auto-archived, buckets, snapshots, images and security groups opened, KMS keys disabled, guardrails removed and commands run on instances; saying, for each account and region, what it searched, what is off, what it could not read and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
            "account": .string("Only this account, by its ID or name; any the sign-in covers. The accounts the watch reads when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let window = try AWS.window(input.since, input.until, days: 1, keeps: AWS.cloudTrailDays)
            let covered = try await service.access.awsAccounts().sorted { $0.id < $1.id }
            let region = try service.setting("region")
            let accounts = input.account?.isEmpty == false ? [try await AWS.account(input.account, on: service).0] : Array(covered.prefix(AWS.watchAccounts))
            guard !accounts.isEmpty else { throw ServiceError.input("The sign-in covers no AWS accounts.") }
            let read = await AWS.watchRead(service, accounts: accounts, covered: covered, region: region, until: window.until, pages: AWS.eventsPages,
                                           trailAccounts: Set(accounts.map(\.id))) { _ in window.since }
            if read.nothingRead {
                let reasons = Array(Set(read.reads.compactMap { $0.read.error?.localizedDescription })).sorted()
                throw ServiceError.input("Nothing could be read: " + reasons.joined(separator: "; "))
            }
            let events = read.events
            let span = "from \(AWS.iso(window.since)) to \(AWS.iso(window.until))"
            let gaps = read.reads.contains { $0.read.error != nil || $0.read.cut || $0.read.off != nil }
            var lines: [String]
            if events.isEmpty {
                lines = [gaps ? "No watched events \(span) in what could be read; see below for what was not." : "No watched events \(span)."]
            } else {
                lines = GoogleCloud.inTurn(events, most: 80).map(\.line)
                if events.count > 80 { lines.append("\(events.count - 80) more in the structured result.") }
            }
            let searched = read.reads.filter { $0.read.error == nil && $0.read.off == nil }.map(\.feed)
            for kind in FeedKind.allCases {
                let places = searched.filter { $0.kind == kind }.map { "\($0.account.name) (\($0.account.id)) in \($0.region)" }
                guard !places.isEmpty else { continue }
                let what = switch kind {
                case .securityhub: "Security Hub's active critical and high findings, NEW or NOTIFIED, made"
                case .guardduty: "GuardDuty's high and critical findings that are not archived, updated"
                case .cloudtrail: "CloudTrail's changes, for the watched kinds,"
                }
                lines.append("Searched: \(what) \(span), of \(GoogleCloud.listed(places)).")
            }
            var unread: [String: String] = [:], off: [String: String] = [:], cut: [String] = []
            for (feed, result) in read.reads {
                if let error = result.error {
                    let fix = AWS.fix(for: error, needs: Self.needs(feed.kind)) ?? error.localizedDescription
                    lines.append("Could not read \(feed.title), so its silence is unknown: \(fix)")
                    unread[feed.title] = error.localizedDescription
                }
                if let reason = result.off { lines.append("Off: \(reason)"); off[feed.title] = reason }
                if result.cut {
                    lines.append("Cut short, with more not read: \(feed.title), past \(AWS.eventsPages) pages; narrow the window, or use \(feed.kind == .cloudtrail ? "cloudtrail-events" : feed.kind == .guardduty ? "guardduty-findings" : "securityhub-findings").")
                    cut.append(feed.title)
                }
            }
            for account in accounts {
                if let said = read.trails[account.id], let said { lines.append("Off: \(said)"); off["trails of \(account.id)"] = said }
                if let error = read.trailErrors[account.id] {
                    lines.append("Whether a CloudTrail trail is logging in \(account.name) (\(account.id)) could not be read: \(AWS.fix(for: error, needs: ["cloudtrail:DescribeTrails", "cloudtrail:GetTrailStatus"]) ?? error.localizedDescription)")
                }
            }
            if input.account?.isEmpty != false, covered.count > accounts.count { lines.append(AWS.uncovered(Array(covered.dropFirst(accounts.count)))) }
            lines.append(AWS.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let couldNotRead: [String: String]; let off: [String: String]; let cutShort: [String]; let accounts: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(events: events.sorted { $0.date > $1.date }, couldNotRead: unread, off: off,
                                                                                           cutShort: cut, accounts: accounts.map(\.id)))
        }

        static func needs(_ kind: FeedKind) -> [String] {
            switch kind {
            case .securityhub: ["securityhub:GetFindings"]
            case .guardduty: ["guardduty:ListDetectors", "guardduty:GetDetector", "guardduty:ListFindings", "guardduty:GetFindings"]
            case .cloudtrail: ["cloudtrail:LookupEvents"]
            }
        }
    }

    /// The watch: each check reads every feed of the watched accounts, each from six hours before the newest seen or
    /// before the last check that read it whole, whichever is later, as Security Hub and GuardDuty update a finding
    /// after its time and CloudTrail lists an event minutes after it. Findings are dated when last updated, so one
    /// updated late still falls in the window. What a check returned is remembered while Pion runs and left out of
    /// later checks, so what is read again is not news again; when a check finds more than it can return, it returns
    /// each kind in turn, tells once that more follow, and the checks after read again from the oldest left out until
    /// all of it is returned. Each feed keeps the oldest of what it owes until it is read whole: one refused, cut short
    /// or read only in part keeps it, however far the watch has moved on meanwhile. Nothing a check read is kept when
    /// it fails.
    ///
    /// A feed that cannot be read is never dropped unsaid: one refused, the role missing in an account, the sign-in
    /// failing, Security Hub or GuardDuty off, or no CloudTrail trail logging, is told as an alert of its own, which
    /// wakes the agents to read security-events, whose result names it and why. It is told once for each time it
    /// starts, and again after a relaunch, dated at the start of the window read so it never moves the watch past what
    /// was not yet read; one cut short is told the same way, and so are accounts past the most the watch reads. A
    /// failure that passes, such as AWS throttling, holds the watch back instead, a few checks at most, and is then told
    /// the same way.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 6 * 3_600 }
        static let holdChecks = 6
        /// How often each account's trails are read again.
        static let retrails: TimeInterval = 3_600
        /// The most IDs of what was returned that one connection keeps, the newest first.
        static let remembered = 20_000

        /// What the checks of one connection keep between them while Pion runs.
        struct Kept: Sendable {
            var inARow: [String: Int] = [:], told: [String: String] = [:]
            /// By feed, when it was last read whole, and all it found returned, up to.
            var readUntil: [String: Date] = [:]
            /// By account, when its trails were last read, and why they keep nothing, when none is logging.
            var trailsRead: [String: Date] = [:], trailNotice: [String: String] = [:]
            /// What the checks returned, by ID, with when it happened.
            var delivered: [String: Date] = [:]
            /// By feed, the oldest of what a check owes: found but not returned, or not read at all. It moves on, or
            /// goes, only with a whole read of its feed.
            var owedFrom: [String: Date] = [:]
            /// By feed, a Security Hub query cut short, which the next checks go on with until it ends.
            var continuations: [String: Continuation] = [:]
            /// By feed, where a query that ended reads on from: its end, less the overlap, however far the watch moved
            /// on while it was read. It goes once a whole read from there returns all it found.
            var catchUp: [String: Date] = [:]
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// Counts a check that failed for a reason that passes, keeping nothing else, and says whether to hold back.
        private func holding(_ labels: Set<String>, account: UUID?) -> [String] {
            var inARow: [String: Int] = [:]
            if let account {
                inARow = Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    watched.inARow = watched.inARow.filter { labels.contains($0.key) }
                    for label in labels { watched.inARow[label, default: 0] += 1 }
                    kept[account] = watched
                    return watched.inARow
                }
            }
            return labels.filter { (inARow[$0] ?? 1) <= Self.holdChecks }.sorted()
        }

        func alerts(since: Date, on service: ServiceClient, account: UUID?, now: Date = Date()) async throws -> [ServiceAlert] {
            let state = account.map { account in Self.kept.withLock { $0[account] ?? Kept() } } ?? Kept()
            let region = try service.setting("region")
            var notices: [(label: String, id: String)] = []
            let covered: [AWSAccount]
            do {
                covered = try await service.access.awsAccounts().sorted { $0.id < $1.id }
            } catch {
                // Without the accounts nothing can be read: a failure that passes holds the watch, any other is told.
                if GoogleWorkspace.isPassing(error), !holding(["accounts"], account: account).isEmpty {
                    throw ServiceError.input("Could not list the AWS accounts for now; the next check reads the same window again.")
                }
                notices = [("accounts", "unreadable/accounts")]
                return tell(notices, since: since, account: account)
            }
            let watched = Array(covered.prefix(AWS.watchAccounts))
            let lookBack = lookBack
            // Each feed reads from what it owes, everything before having been returned or read whole; otherwise from
            // six hours before its last whole read, or from where the watch is.
            let start = { (feed: Feed) -> Date in
                if let query = state.continuations[feed.label] { return query.since }
                var from = since
                if let owed = state.owedFrom[feed.label] { from = owed }
                else if let boundary = state.catchUp[feed.label] { from = boundary }
                else if let until = state.readUntil[feed.label] { from = max(since, until.addingTimeInterval(-lookBack)) }
                // CloudTrail's event history keeps 90 days and refuses a lookup reaching further.
                if feed.kind == .cloudtrail { from = max(from, now.addingTimeInterval(-89 * 86_400)) }
                return from
            }
            let due = Set(watched.map(\.id).filter { state.trailsRead[$0].map { now.timeIntervalSince($0) >= Self.retrails } ?? true })
            let read = await AWS.watchRead(service, accounts: watched, covered: covered, region: region, until: now, pages: AWS.watchPages,
                                           trailAccounts: due, continuations: state.continuations, start: start)
            let failed = read.reads.filter { $0.read.error != nil }
            let passing = Set(failed.filter { GoogleWorkspace.isPassing($0.read.error!) }.map(\.feed.label))
            // A feed that could not be read for now fails the whole check, so the watch reads the same window again,
            // and nothing else of it is kept but how many checks in a row it failed.
            let held = holding(passing, account: account)
            if !held.isEmpty {
                let titles = failed.filter { held.contains($0.feed.label) }.map(\.feed.title)
                throw ServiceError.input("Could not read \(GoogleCloud.listed(titles)) for now; the next check reads the same window again.")
            }
            let events = read.events
            let pending = events.filter { state.delivered[$0.id] == nil }
            var backlog = false
            for (feed, result) in read.reads {
                if result.error != nil { notices.append((feed.label, "unreadable/\(feed.label)")) }
                // A query a check before cut short that now fails is given up, and read again from its start: said.
                if result.error != nil, result.resumed != nil { notices.append(("again/\(feed.label)", "unchecked/\(feed.label)")) }
                if result.off != nil { notices.append(("off/\(feed.label)", "unreadable/\(feed.label)")) }
                // A query cut short that the next checks go on with leaves no gap; while it holds back what is new, more
                // follow. One only catching up through what was returned before tells nothing.
                if let next = result.next {
                    backlog = backlog || next.owed != nil || pending.contains { $0.feed == feed.label } || (result.resumed == nil && state.owedFrom[feed.label] != nil)
                }
                else if result.cut { notices.append(("more/\(feed.label)", "unchecked/\(feed.label)")) }
            }
            var trailNotice: [String: String?] = state.trailNotice.filter { id, _ in watched.contains { $0.id == id } }.mapValues { Optional($0) }
            for (id, said) in read.trails { trailNotice.updateValue(said, forKey: id) }
            for id in trailNotice.filter({ $0.value != nil }).keys.sorted() { notices.append(("off/trails/\(AWS.accountTag(id))", "unreadable/trails/\(AWS.accountTag(id))")) }
            if covered.count > watched.count { notices.append(("more/accounts", "unchecked/accounts")) }
            if backlog || pending.count > ServiceAlert.most - notices.count { notices.append(("more/backlog", "unchecked/backlog")) }
            let feeds = read.reads.map(\.feed)
            let complete = Dictionary(read.reads.map { ($0.feed.label, $0.read.complete && $0.read.error == nil) }, uniquingKeysWith: { $0 && $1 })
            let results = Dictionary(read.reads.map { ($0.feed.label, $0.read) }, uniquingKeysWith: { first, _ in first })
            let starts = Dictionary(feeds.map { ($0.label, start($0)) }, uniquingKeysWith: min)
            let current = Set(notices.map(\.label))
            let update = { (watched: inout Kept) -> (told: [ServiceAlert], chosen: [WatchedEvent]) in
                watched.told = watched.told.filter { current.contains($0.key) }
                let new = notices.filter { watched.told[$0.label] == nil }.map { ($0.label, "\($0.id)/\(UUID().uuidString)") }
                for (label, id) in new { watched.told[label] = id }
                // Dated at the window's start, which is never after the newest seen, so it moves nothing on.
                let told = new.map { ServiceAlert(id: $0.1, time: since) }
                // The rest of what is new, each kind in turn; what has no room waits for the next check.
                let chosen = GoogleCloud.inTurn(pending, most: ServiceAlert.most - told.count)
                let ids = Set(chosen.map(\.id))
                let leftover = Dictionary(grouping: pending.filter { !ids.contains($0.id) }, by: \.feed).compactMapValues { $0.map(\.date).min() }
                var owed: [String: Date] = [:], continuations: [String: Continuation] = [:], readTo: [String: Date] = [:], catchUp: [String: Date] = [:]
                for feed in Set(starts.keys) {
                    let result = results[feed]
                    if var next = result?.next {
                        // A query cut short goes on next time with its token. What it owes is kept with it, and its
                        // start stays owed until it ends, so should it fail, it is read again from there.
                        next.owed = [next.owed, leftover[feed]].compactMap { $0 }.min()
                        continuations[feed] = next
                        if let start = starts[feed] { owed[feed] = start }
                        if let boundary = watched.catchUp[feed] { catchUp[feed] = boundary }
                        continue
                    }
                    if let query = result?.resumed, complete[feed] == true {
                        // A query gone on with to its end accounts for its window and nothing after it, however far the
                        // watch moved on while it was read: the feed owes from its end, with the overlap for what is
                        // listed late, or from the oldest it found but had no room for, until a whole read from there.
                        let boundary = query.until.addingTimeInterval(-lookBack)
                        if let held = [query.owed, leftover[feed]].compactMap({ $0 }).min() { owed[feed] = min(held, boundary) } else { catchUp[feed] = boundary }
                        continue
                    }
                    // A whole read accounts for everything its feed was owed. Any other, refused, cut short newest first,
                    // a query given up, or read only in part, keeps the oldest owed, and owes what it was asked to read
                    // too.
                    let value: Date? = if complete[feed] == true { leftover[feed] }
                        else { [watched.owedFrom[feed], result?.resumed?.owed, leftover[feed], starts[feed]].compactMap { $0 }.min() }
                    if let value { owed[feed] = value } else if complete[feed] == true { readTo[feed] = now }
                }
                // A boundary to catch up from stays until a whole read from it, or what it owes takes its place.
                for (feed, boundary) in watched.catchUp where catchUp[feed] == nil && owed[feed] == nil && readTo[feed] == nil && starts[feed] != nil {
                    catchUp[feed] = boundary
                }
                watched.owedFrom = owed
                watched.continuations = continuations
                watched.catchUp = catchUp
                for event in chosen { watched.delivered[event.id] = event.date }
                let oldest = (Array(starts.values) + Array(owed.values) + Array(catchUp.values) + continuations.values.compactMap(\.owed)).min() ?? since
                watched.delivered = watched.delivered.filter { $0.value >= oldest.addingTimeInterval(-60) }
                if watched.delivered.count > Self.remembered {
                    watched.delivered = Dictionary(uniqueKeysWithValues: watched.delivered.sorted { $0.value > $1.value }.prefix(Self.remembered).map { ($0.key, $0.value) })
                }
                // A feed counts as read up to a time only once all it found has been returned.
                for (feed, time) in readTo { watched.readUntil[feed] = time }
                watched.readUntil = watched.readUntil.filter { starts[$0.key] != nil }
                for id in read.trails.keys { watched.trailsRead[id] = now }
                watched.trailNotice = Dictionary(uniqueKeysWithValues: trailNotice.compactMap { id, said in said.map { (id, $0) } })
                return (told, chosen)
            }
            var scratch = state
            let (told, chosen) = account.map { account in
                Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    let result = update(&watched)
                    kept[account] = watched
                    return result
                }
            } ?? update(&scratch)
            if read.nothingRead, told.isEmpty, let first = failed.first?.read.error { throw first }
            return told + chosen.compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
        }

        /// Notices alone, told once each while they last, for a check that could read nothing else.
        private func tell(_ notices: [(label: String, id: String)], since: Date, account: UUID?) -> [ServiceAlert] {
            let current = Set(notices.map(\.label))
            let update = { (watched: inout Kept) -> [ServiceAlert] in
                watched.told = watched.told.filter { current.contains($0.key) }
                let new = notices.filter { watched.told[$0.label] == nil }.map { ($0.label, "\($0.id)/\(UUID().uuidString)") }
                for (label, id) in new { watched.told[label] = id }
                return new.map { ServiceAlert(id: $0.1, time: since) }
            }
            var scratch = Kept()
            return account.map { account in
                Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    let told = update(&watched)
                    kept[account] = watched
                    return told
                }
            } ?? update(&scratch)
        }
    }
}
