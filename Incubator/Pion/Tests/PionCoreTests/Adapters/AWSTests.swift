import Foundation
import NoodleCore
import NoodleMCP
@testable import PionCore
import XCTest

final class AWSTests: XCTestCase {
    private let aws = try! AWS.preset.makeConnection(name: "AWS — Production", values: [
        "startURL": "https://example.awsapps.com/start/#/", "role": "SecurityAudit", "region": "eu-west-1"])

    private func json(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    func testAConnectionSignsInThroughIdentityCenterAndTakesOneRoleInEachAccount() {
        XCTAssertEqual(aws.endpoint.absoluteString, "https://amazonaws.com")
        XCTAssertEqual(aws.awsIdentityCenter?.startURL.absoluteString, "https://example.awsapps.com/start", "kept without the browser's #/")
        XCTAssertEqual(aws.awsIdentityCenter?.role, "SecurityAudit")
        XCTAssertEqual(aws.awsIdentityCenter?.region, "eu-west-1")
        XCTAssertTrue(aws.keepsSecret)
        XCTAssertEqual(aws.adapter, "aws")
        XCTAssertNotNil(PionAdapters.all["aws"])
        XCTAssertThrowsError(try AWS.preset.makeConnection(name: "AWS", values: [
            "startURL": "https://example.com/start", "role": "SecurityAudit", "region": "eu-west-1"]), "a start URL outside AWS was taken")
    }

    /// One connection covers the organisation: lookups name an account by ID or name, and an access key is traced to
    /// its own account first.
    func testLookupsNameTheAccountTheyAreForAcrossTheOrganisation() async throws {
        let service = FakeService()
        service.awsAccountList = [AWSAccount(id: "111111111111", name: "Production", email: "prod@example.com"),
                                  AWSAccount(id: "222222222222", name: "Staging", email: nil)]
        let accounts = try await callTool(AWS.adapter, "accounts", "{}", on: service, in: aws)
        XCTAssertEqual(accounts.text, "2 accounts:\nProduction (111111111111) — prod@example.com\nStaging (222222222222)")

        let unnamed = try await callTool(AWS.adapter, "open-security-groups", "{}", on: service, in: aws)
        XCTAssertTrue(unnamed.isError)
        XCTAssertTrue(unnamed.text.contains("Name the account: Production (111111111111), Staging (222222222222)"), unnamed.text)
        let unknown = try await callTool(AWS.adapter, "open-security-groups", #"{"account":"Sandbox"}"#, on: service, in: aws)
        XCTAssertTrue(unknown.text.contains("no account Sandbox"), unknown.text)

        service.answers["action:DescribeSecurityGroups"] = (200, "<DescribeSecurityGroupsResponse><securityGroupInfo/></DescribeSecurityGroupsResponse>")
        _ = try await callTool(AWS.adapter, "open-security-groups", #"{"account":"staging"}"#, on: service, in: aws)
        _ = try await callTool(AWS.adapter, "open-security-groups", #"{"account":"111111111111"}"#, on: service, in: aws)
        XCTAssertEqual(service.awsAccountsUsed, ["222222222222", "111111111111"], "an account by its name, then by its ID")

        service.awsAccountsUsed = []
        service.answers["action:GetAccessKeyInfo"] = (200, "<GetAccessKeyInfoResponse><GetAccessKeyInfoResult><Account>222222222222</Account></GetAccessKeyInfoResult></GetAccessKeyInfoResponse>")
        service.answers["action:GetAccessKeyLastUsed"] = (200, """
        <GetAccessKeyLastUsedResponse><GetAccessKeyLastUsedResult><UserName>mallory</UserName><AccessKeyLastUsed>
        <LastUsedDate>2026-11-14T09:01:00Z</LastUsedDate><ServiceName>s3</ServiceName><Region>eu-west-1</Region></AccessKeyLastUsed>
        </GetAccessKeyLastUsedResult></GetAccessKeyLastUsedResponse>
        """)
        let key = try await callTool(AWS.adapter, "access-key", #"{"accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#, on: service, in: aws)
        XCTAssertTrue(key.text.contains("belongs to mallory"), key.text)
        XCTAssertEqual(service.requests.suffix(2).map { $0.url?.host }, ["sts.amazonaws.com", "iam.amazonaws.com"])
        XCTAssertEqual(service.awsAccountsUsed.last, "222222222222", "the key was looked up outside its own account")

        service.answers["action:GetAccessKeyInfo"] = (200, "<GetAccessKeyInfoResponse><GetAccessKeyInfoResult><Account>999999999999</Account></GetAccessKeyInfoResult></GetAccessKeyInfoResponse>")
        let elsewhere = try await callTool(AWS.adapter, "access-key", #"{"accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#, on: service, in: aws)
        XCTAssertEqual(elsewhere.text, "AKIAIOSFODNN7EXAMPLE belongs to account 999999999999, which the sign-in does not cover.")
    }

    func testCloudTrailEventsAreLookedUpByOneAttribute() async throws {
        let service = FakeService()
        let event = #"{\"sourceIPAddress\":\"203.0.113.77\",\"userAgent\":\"aws-cli/2.15\",\"awsRegion\":\"eu-west-1\",\"errorCode\":\"AccessDenied\"}"#
        service.answers["com.amazonaws.cloudtrail.v20131101.CloudTrail_20131101.LookupEvents"] = (200,
            #"{"Events":[{"EventId":"e1","EventName":"CreateAccessKey","EventTime":1763110800,"EventSource":"iam.amazonaws.com","Username":"mallory","Resources":[{"ResourceType":"AWS::IAM::AccessKey","ResourceName":"AKIAEXAMPLE"}],"CloudTrailEvent":"\#(event)"}]}"#)
        let events = try await callTool(AWS.adapter, "cloudtrail-events", #"{"user":"mallory","since":"2025-11-13T00:00:00Z","limit":20}"#, on: service, in: aws)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("CreateAccessKey by mallory from 203.0.113.77"), events.text)
        XCTAssertTrue(events.text.contains("AccessDenied"), events.text)
        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.url?.host, "cloudtrail.eu-west-1.amazonaws.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-amz-json-1.1")
        let body = try json(request)
        XCTAssertEqual(body["LookupAttributes"] as? [[String: String]], [["AttributeKey": "Username", "AttributeValue": "mallory"]])
        XCTAssertEqual(body["MaxResults"] as? Int, 20)
        XCTAssertEqual(body["StartTime"] as? Int, 1762992000)

        _ = try await callTool(AWS.adapter, "cloudtrail-events", #"{"eventName":"ConsoleLogin","region":"us-east-1"}"#, on: service, in: aws)
        XCTAssertEqual(service.requests.last?.url?.host, "cloudtrail.us-east-1.amazonaws.com")
        let twice = try await callTool(AWS.adapter, "cloudtrail-events", #"{"user":"a","eventName":"b"}"#, on: service, in: aws)
        XCTAssertTrue(twice.isError, "CloudTrail looks up by one attribute at a time")
    }

    func testGuardDutyFindingsComeFromTheRegionsDetector() async throws {
        let service = FakeService()
        service.answers["/detector"] = (200, #"{"detectorIds":["d1"]}"#)
        service.answers["/detector/d1/findings"] = (200, #"{"findingIds":["f1"]}"#)
        service.answers["/detector/d1/findings/get"] = (200, #"{"findings":[{"id":"f1","type":"UnauthorizedAccess:IAMUser/MaliciousIPCaller","severity":8.0,"title":"API called from a known malicious IP.","updatedAt":"2026-11-14T09:00:00Z","resource":{"resourceType":"AccessKey","accessKeyDetails":{"userName":"mallory","accessKeyId":"AKIAEXAMPLE"}}}]}"#)
        let findings = try await callTool(AWS.adapter, "guardduty-findings", #"{"minimumSeverity":7}"#, on: service, in: aws)
        XCTAssertFalse(findings.isError, findings.text)
        XCTAssertTrue(findings.text.contains("MaliciousIPCaller"), findings.text)
        XCTAssertTrue(findings.text.contains("mallory"), findings.text)
        let query = try json(service.requests[1])
        let criterion = ((query["findingCriteria"] as? [String: Any])?["criterion"] as? [String: Any])
        XCTAssertEqual((criterion?["severity"] as? [String: Int])?["greaterThanOrEqual"], 7)
        XCTAssertEqual(service.requests[0].url?.host, "guardduty.eu-west-1.amazonaws.com")
    }

    func testSecurityHubFindingsBySeverity() async throws {
        let service = FakeService()
        service.answers["/findings"] = (200, #"{"Findings":[{"Id":"arn:x","Title":"S3 bucket allows public read","Severity":{"Label":"CRITICAL"},"ProductName":"Security Hub","UpdatedAt":"2026-11-14T08:00:00Z","Resources":[{"Type":"AwsS3Bucket","Id":"arn:aws:s3:::payroll-exports"}]}]}"#)
        let findings = try await callTool(AWS.adapter, "securityhub-findings", #"{"severities":["CRITICAL"]}"#, on: service, in: aws)
        XCTAssertTrue(findings.text.contains("payroll-exports"), findings.text)
        let filters = try json(service.requests.first)["Filters"] as? [String: [[String: String]]]
        XCTAssertEqual(filters?["SeverityLabel"], [["Value": "CRITICAL", "Comparison": "EQUALS"]])
        XCTAssertEqual(filters?["RecordState"], [["Value": "ACTIVE", "Comparison": "EQUALS"]])
    }

    func testAnAccessKeyIsTracedToItsOwnerAndLastUse() async throws {
        let service = FakeService()
        service.answers["action:GetAccessKeyLastUsed"] = (200, """
        <GetAccessKeyLastUsedResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/"><GetAccessKeyLastUsedResult>
        <UserName>mallory</UserName><AccessKeyLastUsed><LastUsedDate>2026-11-14T09:01:00Z</LastUsedDate><ServiceName>s3</ServiceName>
        <Region>eu-west-1</Region></AccessKeyLastUsed></GetAccessKeyLastUsedResult></GetAccessKeyLastUsedResponse>
        """)
        let key = try await callTool(AWS.adapter, "access-key", #"{"accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#, on: service, in: aws)
        XCTAssertFalse(key.isError, key.text)
        XCTAssertTrue(key.text.contains("belongs to mallory"), key.text)
        XCTAssertTrue(key.text.contains("s3 in eu-west-1"), key.text)
        XCTAssertEqual(service.requests.first?.url?.host, "iam.amazonaws.com")
        XCTAssertEqual(queryItems(service.requests.first)["AccessKeyId"], "AKIAIOSFODNN7EXAMPLE")
        let refused = try await callTool(AWS.adapter, "access-key", #"{"accessKeyId":"not a key"}"#, on: service, in: aws)
        XCTAssertTrue(refused.isError)
    }

    func testTheCredentialReportListsEveryUsersPasswordKeysAndMFA() async throws {
        let service = FakeService()
        service.answers["action:GenerateCredentialReport"] = (200, "<GenerateCredentialReportResponse><GenerateCredentialReportResult><State>COMPLETE</State></GenerateCredentialReportResult></GenerateCredentialReportResponse>")
        let csv = "user,arn,password_enabled,password_last_used,mfa_active,access_key_1_active,access_key_1_last_used_date\nmallory,arn:aws:iam::1:user/mallory,true,2026-11-14T09:00:00+00:00,false,true,2026-11-14T09:01:00+00:00\n"
        service.answers["action:GetCredentialReport"] = (200, "<GetCredentialReportResponse><GetCredentialReportResult><Content>\(Data(csv.utf8).base64EncodedString())</Content></GetCredentialReportResult></GetCredentialReportResponse>")
        let report = try await callTool(AWS.adapter, "credential-report", "{}", on: service, in: aws)
        XCTAssertFalse(report.isError, report.text)
        XCTAssertTrue(report.text.contains("mallory"), report.text)
        XCTAssertEqual(report.structured?["columns"] as? [String],
                       ["user", "arn", "password_enabled", "password_last_used", "mfa_active", "access_key_1_active", "access_key_1_last_used_date"])
    }

    func testInstancesAndSecurityGroupsOpenToTheInternet() async throws {
        let service = FakeService()
        service.answers["action:DescribeInstances"] = (200, """
        <DescribeInstancesResponse><reservationSet><item><instancesSet><item><instanceId>i-0abc</instanceId><instanceType>t3.micro</instanceType>
        <instanceState><name>running</name></instanceState><privateIpAddress>10.0.1.5</privateIpAddress><ipAddress>203.0.113.9</ipAddress>
        <launchTime>2026-11-01T00:00:00Z</launchTime><groupSet><item><groupId>sg-1</groupId><groupName>web</groupName></item></groupSet>
        <tagSet><item><key>Name</key><value>web-01</value></item></tagSet></item></instancesSet></item></reservationSet></DescribeInstancesResponse>
        """)
        service.answers["action:DescribeSecurityGroups"] = (200, """
        <DescribeSecurityGroupsResponse><securityGroupInfo><item><groupId>sg-1</groupId><groupName>web</groupName><vpcId>vpc-1</vpcId>
        <ipPermissions><item><ipProtocol>tcp</ipProtocol><fromPort>22</fromPort><toPort>22</toPort><ipRanges><item><cidrIp>0.0.0.0/0</cidrIp></item></ipRanges></item></ipPermissions>
        </item></securityGroupInfo></DescribeSecurityGroupsResponse>
        """)
        let instances = try await callTool(AWS.adapter, "ec2-instances", #"{"ip":"203.0.113.9"}"#, on: service, in: aws)
        XCTAssertFalse(instances.isError, instances.text)
        XCTAssertTrue(instances.text.contains("i-0abc (web-01)"), instances.text)
        XCTAssertTrue(instances.text.contains("running"), instances.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["Filter.1.Name"], "ip-address")
        XCTAssertEqual(sent["Filter.1.Value.1"], "203.0.113.9")
        XCTAssertEqual(service.requests.first?.url?.host, "ec2.eu-west-1.amazonaws.com")
        let open = try await callTool(AWS.adapter, "open-security-groups", "{}", on: service, in: aws)
        XCTAssertTrue(open.text.contains("tcp 22 from 0.0.0.0/0"), open.text)
    }

    func testLogsInsightsStartsAQueryAndReadsItsResults() async throws {
        let service = FakeService()
        service.answers["Logs_20140328.StartQuery"] = (200, #"{"queryId":"q1"}"#)
        service.answers["Logs_20140328.GetQueryResults"] = (200, #"{"status":"Complete","results":[[{"field":"@timestamp","value":"2026-11-14 09:00:00.000"},{"field":"srcAddr","value":"203.0.113.77"}]]}"#)
        let rows = try await callTool(AWS.adapter, "logs-insights",
            #"{"logGroups":["vpc-flow-logs"],"query":"fields @timestamp, srcAddr | filter srcAddr = '203.0.113.77' | limit 20","since":"2026-11-13T00:00:00Z"}"#,
            on: service, in: aws)
        XCTAssertFalse(rows.isError, rows.text)
        XCTAssertTrue(rows.text.contains("203.0.113.77"), rows.text)
        let start = try json(service.requests.first)
        XCTAssertEqual(start["logGroupNames"] as? [String], ["vpc-flow-logs"])
        XCTAssertEqual(start["startTime"] as? Int, 1794528000)
        XCTAssertEqual(try json(service.requests.last)["queryId"] as? String, "q1")
        XCTAssertEqual(service.requests.first?.url?.host, "logs.eu-west-1.amazonaws.com")
    }

    func testAccessAnalyzerFindingsShowWhatIsSharedOutside() async throws {
        let service = FakeService()
        service.answers["/analyzer"] = (200, #"{"analyzers":[{"arn":"arn:aws:access-analyzer:eu-west-1:1:analyzer/account","status":"ACTIVE"}]}"#)
        service.answers["/finding"] = (200, #"{"findings":[{"id":"a1","resource":"arn:aws:s3:::payroll-exports","resourceType":"AWS::S3::Bucket","isPublic":true,"status":"ACTIVE","action":["s3:GetObject"],"updatedAt":"2026-11-14T08:00:00Z"}]}"#)
        let findings = try await callTool(AWS.adapter, "access-analyzer-findings", "{}", on: service, in: aws)
        XCTAssertFalse(findings.isError, findings.text)
        XCTAssertTrue(findings.text.contains("payroll-exports is public"), findings.text)
        XCTAssertEqual(try json(service.requests.last)["analyzerArn"] as? String, "arn:aws:access-analyzer:eu-west-1:1:analyzer/account")
    }
}
