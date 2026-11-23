import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class AWSInvestigationTests: XCTestCase {
    private let aws = try! AWS.preset.makeConnection(name: "AWS — Production", values: [
        "startURL": "https://example.awsapps.com/start/#/", "role": "SecurityAudit", "region": "eu-west-1"])

    private func json(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    static func body(_ object: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
    static func encoded(_ json: String) -> String { json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }

    // MARK: iam-access

    static func details(users: String = "", groups: String = "", roles: String = "", policies: String = "") -> String {
        """
        <GetAccountAuthorizationDetailsResponse><GetAccountAuthorizationDetailsResult>
        <UserDetailList>\(users)</UserDetailList><GroupDetailList>\(groups)</GroupDetailList><RoleDetailList>\(roles)</RoleDetailList>
        <Policies>\(policies)</Policies><IsTruncated>false</IsTruncated>
        </GetAccountAuthorizationDetailsResult></GetAccountAuthorizationDetailsResponse>
        """
    }

    static func user(_ name: String, inline: String? = nil, attached: [(String, String)] = []) -> String {
        "<member><UserName>\(name)</UserName><Arn>arn:aws:iam::111111111111:user/\(name)</Arn><GroupList/><AttachedManagedPolicies>"
            + attached.map { "<member><PolicyName>\($0.0)</PolicyName><PolicyArn>\($0.1)</PolicyArn></member>" }.joined()
            + "</AttachedManagedPolicies><UserPolicyList>"
            + (inline.map { "<member><PolicyName>\(name)-inline</PolicyName><PolicyDocument>\(encoded($0))</PolicyDocument></member>" } ?? "")
            + "</UserPolicyList></member>"
    }

    static func role(_ name: String, trust: String, inline: String? = nil, attached: [(String, String)] = []) -> String {
        "<member><RoleName>\(name)</RoleName><Arn>arn:aws:iam::111111111111:role/\(name)</Arn><AssumeRolePolicyDocument>\(encoded(trust))</AssumeRolePolicyDocument><AttachedManagedPolicies>"
            + attached.map { "<member><PolicyName>\($0.0)</PolicyName><PolicyArn>\($0.1)</PolicyArn></member>" }.joined()
            + "</AttachedManagedPolicies><RolePolicyList>"
            + (inline.map { "<member><PolicyName>\(name)-inline</PolicyName><PolicyDocument>\(encoded($0))</PolicyDocument></member>" } ?? "")
            + "</RolePolicyList></member>"
    }

    /// Who could make themselves an administrator is found from every policy they hold, AWS managed ones and NotAction
    /// included, and confirmed with IAM's policy simulator, which counts boundaries and SCPs.
    func testIAMAccessFindsWhoCouldMakeThemselvesAdministratorsAndAsksTheSimulator() async throws {
        let service = FakeService()
        let passLambda = #"{"Statement":[{"Effect":"Allow","Action":["iam:PassRole","lambda:CreateFunction","lambda:InvokeFunction"],"Resource":"*"}]}"#
        let ownKeys = #"{"Statement":[{"Effect":"Allow","Action":"iam:CreateAccessKey","Resource":"arn:aws:iam::111111111111:user/${aws:username}"}]}"#
        let assume = #"{"Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"arn:aws:iam::111111111111:role/*"}]}"#
        let allButBilling = #"{"Statement":[{"Effect":"Allow","NotAction":["aws-portal:*"],"Resource":"*"}]}"#
        let iamFull = #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["iam:*"],"Resource":"*"}]}"#
        let trustAccount = #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::111111111111:root"},"Action":"sts:AssumeRole"}]}"#
        let trustLambda = #"{"Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}"#
        service.answers["action:GetAccountAuthorizationDetails"] = (200, Self.details(
            users: Self.user("bob", inline: passLambda) + Self.user("eve", inline: ownKeys) + Self.user("dave", inline: assume)
                + Self.user("carol", attached: [("IAMFullAccess", "arn:aws:iam::aws:policy/IAMFullAccess")]),
            roles: Self.role("admin", trust: trustAccount, attached: [("AdministratorAccess", "arn:aws:iam::aws:policy/AdministratorAccess")])
                + Self.role("ci", trust: trustLambda, inline: allButBilling),
            policies: "<member><PolicyName>IAMFullAccess</PolicyName><Arn>arn:aws:iam::aws:policy/IAMFullAccess</Arn><PolicyVersionList><member><Document>\(Self.encoded(iamFull))</Document><IsDefaultVersion>true</IsDefaultVersion></member></PolicyVersionList></member>"))
        func simulated(_ allowed: [String], denied: [String]) -> String {
            "<SimulatePrincipalPolicyResponse><SimulatePrincipalPolicyResult><EvaluationResults>"
                + allowed.map { "<member><EvalActionName>\($0)</EvalActionName><EvalResourceName>*</EvalResourceName><EvalDecision>allowed</EvalDecision><MatchedStatements><member><SourcePolicyId>x</SourcePolicyId></member></MatchedStatements><OrganizationsDecisionDetail><AllowedByOrganizations>true</AllowedByOrganizations></OrganizationsDecisionDetail></member>" }.joined()
                + denied.map { "<member><EvalActionName>\($0)</EvalActionName><EvalDecision>implicitDeny</EvalDecision></member>" }.joined()
                + "</EvaluationResults><IsTruncated>false</IsTruncated></SimulatePrincipalPolicyResult></SimulatePrincipalPolicyResponse>"
        }
        // Asked in the order the principals are listed: users bob, dave, carol, then role ci.
        service.sequences["action:SimulatePrincipalPolicy"] = [
            (200, simulated(["iam:PassRole", "lambda:CreateFunction", "lambda:InvokeFunction"], denied: [])),
            (200, simulated(["sts:AssumeRole"], denied: [])),
            (200, simulated([], denied: ["iam:AttachUserPolicy", "iam:CreatePolicyVersion"])),
            (200, simulated(["iam:AttachRolePolicy"], denied: [])),
        ]
        let access = try await callTool(AWS.adapter, "iam-access", "{}", on: service, in: aws)
        XCTAssertFalse(access.isError, access.text)
        let lines = access.text.split(separator: "\n").map(String.init)
        let details = try XCTUnwrap(service.requests.first { queryItems($0)["Action"] == "GetAccountAuthorizationDetails" })
        XCTAssertEqual(queryItems(details)["Filter.member.5"], "AWSManagedPolicy", "AWS managed policies are read, so IAMFullAccess is judged")
        XCTAssertTrue(lines.contains { $0.hasPrefix("- role admin") }, access.text)
        XCTAssertTrue(lines.contains { $0.contains("Could make themselves administrators (4)") }, access.text)
        let bob = try XCTUnwrap(lines.first { $0.hasPrefix("- user bob:") }, access.text)
        XCTAssertTrue(bob.contains("run code in Lambda as a more powerful role (iam:PassRole with lambda:CreateFunction with lambda:InvokeFunction), by its policies; the policy simulator, per action on resource *: iam:PassRole allowed (SCPs allow), lambda:CreateFunction allowed (SCPs allow), lambda:InvokeFunction allowed (SCPs allow)"), bob)
        XCTAssertFalse(access.text.contains("confirmed"), "the simulator judges actions, not paths:\n\(access.text)")
        let dave = try XCTUnwrap(lines.first { $0.hasPrefix("- user dave:") }, access.text)
        XCTAssertTrue(dave.contains("assume the administrator role admin") && dave.contains("sts:AssumeRole allowed"), dave)
        let carol = try XCTUnwrap(lines.first { $0.hasPrefix("- user carol:") }, access.text)
        XCTAssertTrue(carol.contains("attach any managed policy, AdministratorAccess included, to a user (iam:AttachUserPolicy), by its policies; the policy simulator, per action on resource *: iam:AttachUserPolicy implicitDeny"), carol)
        XCTAssertTrue(carol.contains("iam:CreateLoginProfile not answered"), carol)
        XCTAssertTrue(access.text.contains("What the simulator was asked: each action alone, for the principal on resource *") && access.text.contains("does not judge resource policies"), access.text)
        XCTAssertTrue(carol.contains("make access keys for other users"), carol)
        XCTAssertTrue(lines.contains { $0.hasPrefix("- role ci:") && $0.contains("attach any managed policy to a role") }, "NotAction allows the rest:\n\(access.text)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("- user eve:") && $0.contains("access keys") && $0.contains("Could") }, access.text)
        XCTAssertFalse(lines.contains { $0.hasPrefix("- user eve:") && $0.contains("make access keys for other users") }, "only their own keys:\n\(access.text)")
        let simulations = service.requests.filter { queryItems($0)["Action"] == "SimulatePrincipalPolicy" }
        XCTAssertEqual(simulations.count, 4)
        XCTAssertEqual(queryItems(simulations[0])["PolicySourceArn"], "arn:aws:iam::111111111111:user/bob")
        let principals = try XCTUnwrap(access.structured?["principals"] as? [[String: Any]])
        let paths = try XCTUnwrap(principals.first { $0["name"] as? String == "bob" }?["escalation"] as? [[String: Any]])
        let answers = try XCTUnwrap(paths.first?["simulations"] as? [[String: Any]])
        XCTAssertEqual(answers.map { $0["decision"] as? String }, ["allowed", "allowed", "allowed"])
        XCTAssertEqual(answers.first?["resources"] as? [String], ["*"])
        XCTAssertEqual(answers.first?["allowedByOrganizations"] as? Bool, true)
        XCTAssertNil(answers.first?["allowedByBoundary"] as? Bool, "the simulator did not say")
        XCTAssertEqual(access.structured?["complete"] as? Bool, true, "every policy held was read")

        // A simulator that may not be asked leaves the paths by the policies alone, and says why.
        service.sequences = [:]
        service.answers["action:SimulatePrincipalPolicy"] = (403, "<ErrorResponse><Error><Code>AccessDenied</Code><Message>not authorized to perform: iam:SimulatePrincipalPolicy</Message></Error></ErrorResponse>")
        let alone = try await callTool(AWS.adapter, "iam-access", "{}", on: service, in: aws)
        XCTAssertFalse(alone.isError, alone.text)
        XCTAssertTrue(alone.text.contains("IAM's policy simulator could not be asked") && alone.text.contains("add iam:SimulatePrincipalPolicy"), alone.text)
        XCTAssertTrue(alone.text.contains("(iam:PassRole with lambda:CreateFunction with lambda:InvokeFunction), by its policies"), alone.text)

        // A policy whose document was not read leaves the account not judged in full, and the principal says so.
        service.answers["action:GetAccountAuthorizationDetails"] = (200, Self.details(users: Self.user("frank", attached: [("Custom", "arn:aws:iam::111111111111:policy/Custom")])))
        let partial = try await callTool(AWS.adapter, "iam-access", "{}", on: service, in: aws)
        XCTAssertEqual(partial.structured?["complete"] as? Bool, false)
        XCTAssertEqual(partial.structured?["unreadPolicies"] as? [String], ["Custom"])
        XCTAssertTrue(partial.text.contains("user frank: Custom; 1 of its policies could not be read, so what it may do is not fully known"), partial.text)
        XCTAssertTrue(partial.text.contains("1 policies could not be read"), partial.text)
    }

    /// A role's trust is judged with its conditions: an identity provider's tokens must be kept to a subject, "*" to the
    /// organisation, and an account outside those covered is said with whether it needs an external ID.
    func testIAMAccessSaysWhichRolesOthersCouldAssume() async throws {
        let service = FakeService()
        service.awsAccountList = [AWSAccount(id: "111111111111", name: "Production", email: nil), AWSAccount(id: "222222222222", name: "Staging", email: nil)]
        let github = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
        let roles = [
            ("any-repo", #"{"Statement":[{"Effect":"Allow","Principal":{"Federated":"\#(github)"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"}}}]}"#),
            ("one-repo", #"{"Statement":[{"Effect":"Allow","Principal":{"Federated":"\#(github)"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringLike":{"token.actions.githubusercontent.com:sub":"repo:acme/app:ref:refs/heads/main"}}}]}"#),
            ("star-repo", #"{"Statement":[{"Effect":"Allow","Principal":{"Federated":"\#(github)"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringLike":{"token.actions.githubusercontent.com:sub":"repo:*"}}}]}"#),
            ("org-only", #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:PrincipalOrgID":"o-abc123"}}}]}"#),
            ("open", #"{"Statement":[{"Effect":"Allow","Principal":"*","Action":"sts:AssumeRole"}]}"#),
            ("vendor", #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::999999999999:root"},"Action":"sts:AssumeRole"}]}"#),
            ("vendor-id", #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"999999999999"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"sts:ExternalId":"x"}}}]}"#),
            ("staging", #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::222222222222:role/deploy"},"Action":"sts:AssumeRole"}]}"#),
            ("sso", #"{"Statement":[{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam::111111111111:saml-provider/AWSSSO_abc"},"Action":"sts:AssumeRoleWithSAML"}]}"#),
        ]
        service.answers["action:GetAccountAuthorizationDetails"] = (200, Self.details(roles: roles.map { Self.role($0.0, trust: $0.1) }.joined()))
        let access = try await callTool(AWS.adapter, "iam-access", #"{"account":"Production"}"#, on: service, in: aws)
        XCTAssertFalse(access.isError, access.text)
        let lines = access.text.split(separator: "\n").map(String.init)
        func risk(_ role: String) -> String? { lines.first { $0.hasPrefix("- role \(role): ") && !$0.contains("assumable by") } }
        XCTAssertTrue(access.text.contains("Roles others could assume (5):"), access.text)
        XCTAssertTrue(risk("any-repo")?.contains("any GitHub repository's workflows can assume it") == true, access.text)
        XCTAssertTrue(risk("star-repo")?.contains("lets any repository in: repo:*") == true, access.text)
        XCTAssertTrue(risk("open")?.contains("anyone with an AWS account can assume it") == true, access.text)
        XCTAssertTrue(risk("vendor")?.contains("account 999999999999, outside the accounts the sign-in covers, can assume it, with no external ID") == true, access.text)
        XCTAssertTrue(risk("vendor-id")?.contains("with an external ID") == true, access.text)
        for safe in ["one-repo", "org-only", "staging", "sso"] { XCTAssertNil(risk(safe), "\(safe):\n\(access.text)") }
        XCTAssertTrue(lines.contains { $0.contains("role one-repo") && $0.contains("assumable by token.actions.githubusercontent.com for repo:acme/app:ref:refs/heads/main") }, access.text)
        XCTAssertTrue(lines.contains { $0.contains("role org-only") && $0.contains("anyone, when aws:PrincipalOrgID StringEquals o-abc123") }, access.text)
        XCTAssertTrue(lines.contains { $0.contains("role staging") && $0.contains("another account 222222222222, which the sign-in covers") }, access.text)
        XCTAssertTrue(lines.contains { $0.contains("role sso") && $0.contains("SAML provider AWSSSO_abc") }, access.text)
    }

    func testPolicyWildcardsAndGrants() {
        XCTAssertTrue(AWS.wildcard("iam:*", "iam:PassRole"))
        XCTAssertTrue(AWS.wildcard("IAM:pass?ole", "iam:PassRole"))
        XCTAssertFalse(AWS.wildcard("iam:Get*", "iam:PassRole"))
        XCTAssertTrue(AWS.wildcard("arn:aws:iam::1:role/*", "arn:aws:iam::1:role/admin"))
        let documents = [AWS.policy(#"{"Statement":[{"Effect":"Allow","Action":"iam:*","Resource":"*"},{"Effect":"Deny","Action":"iam:PassRole","Resource":"*"}]}"#)!]
        let grants = AWS.grants(["iam:PassRole", "iam:AttachUserPolicy", "ec2:RunInstances"], in: documents)
        XCTAssertNil(grants["iam:PassRole"], "denied on every resource")
        XCTAssertEqual(grants["iam:AttachUserPolicy"], ["*"])
        XCTAssertNil(grants["ec2:RunInstances"])
        XCTAssertNil(AWS.policy("not json"))
    }

    // MARK: config-history

    static func configItem(_ time: Double, status: String = "OK", configuration: [String: Any], related: [String] = []) -> [String: Any] {
        ["configurationItemCaptureTime": time, "configurationItemStatus": status, "resourceId": "sg-0abc", "resourceName": "web",
         "arn": "arn:aws:ec2:eu-west-1:111111111111:security-group/sg-0abc", "relatedEvents": related,
         "configuration": body(configuration), "tags": ["Owner": "web-team"]]
    }

    static let configHistory = "StarlingDoveService.GetResourceConfigHistory"
    static let lookupEvents = "com.amazonaws.cloudtrail.v20131101.CloudTrail_20131101.LookupEvents"

    /// Each change is set against the configuration before it, and who made it is matched from CloudTrail between the
    /// two, saying plainly when nothing matched.
    func testConfigHistoryShowsWhatChangedAndWhoChangedIt() async throws {
        let service = FakeService()
        let now = Date().timeIntervalSince1970
        let open = ["groupName": "web", "description": "web servers", "ipPermissions": [["ipProtocol": "tcp", "fromPort": 22, "toPort": 22, "ipRanges": [["cidrIp": "0.0.0.0/0"]]]]] as [String: Any]
        let closed = ["groupName": "web", "description": "web servers", "ipPermissions": [] as [Any]] as [String: Any]
        let first = ["groupName": "web", "description": "web", "ipPermissions": [] as [Any]] as [String: Any]
        // Newest first, over two pages: three changes in the window, of which two are kept, and the one before them.
        service.sequences[Self.configHistory] = [
            (200, Self.body(["configurationItems": [Self.configItem(now - 3_600, configuration: open), Self.configItem(now - 86_400, configuration: closed)], "nextToken": "page-2"])),
            (200, Self.body(["configurationItems": [Self.configItem(now - 5 * 86_400, status: "ResourceDiscovered", configuration: first),
                                                    Self.configItem(now - 6 * 86_400, configuration: first)]])),
        ]
        service.answers["StarlingDoveService.DescribeConfigurationRecorders"] = (200, #"{"ConfigurationRecorders":[{"name":"default","recordingGroup":{"allSupported":true,"includeGlobalResourceTypes":false}}]}"#)
        service.answers["StarlingDoveService.DescribeConfigurationRecorderStatus"] = (200, #"{"ConfigurationRecordersStatus":[{"name":"default","recording":true}]}"#)
        let ingress = AWSTests.event("e1", "AuthorizeSecurityGroupIngress", time: now - 3_700, user: "mallory", detail: [
            "userIdentity": ["type": "IAMUser", "arn": "arn:aws:iam::111111111111:user/mallory", "accountId": "111111111111"],
            "sourceIPAddress": "203.0.113.9", "readOnly": false, "awsRegion": "eu-west-1"])
        let read = AWSTests.event("e2", "DescribeSecurityGroups", time: now - 3_650, user: "auditor", detail: ["readOnly": true])
        service.answers[Self.lookupEvents] = (200, Self.body(["Events": [read, ingress]]))
        let history = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc","limit":2}"#, on: service, in: aws)
        XCTAssertFalse(history.isError, history.text)
        let lines = history.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("AWS::EC2::SecurityGroup sg-0abc (web) in account Production (111111111111) in eu-west-1, from "), history.text)
        XCTAssertTrue(lines[0].contains("2 recorded, newest first"), history.text)
        XCTAssertTrue(history.text.contains("AWS Config is recording AWS::EC2::SecurityGroup in account Production (111111111111) in eu-west-1."), history.text)
        XCTAssertTrue(history.text.contains(#"ipPermissions: added {"fromPort":22,"ipProtocol":"tcp","ipRanges":[{"cidrIp":"0.0.0.0/0"}],"toPort":22}"#), history.text)
        XCTAssertTrue(history.text.contains("  Who is not known: Config records no CloudTrail event linked to this change. Candidates, writes to this resource between "), history.text)
        XCTAssertTrue(history.text.contains("  - ") && history.text.contains("AuthorizeSecurityGroupIngress by mallory (IAMUser) from 203.0.113.9"), history.text)
        XCTAssertFalse(history.text.contains("Who, from"), history.text)
        XCTAssertFalse(history.text.contains("DescribeSecurityGroups"), "reads are no change:\n\(history.text)")
        XCTAssertTrue(history.text.contains("description: web → web servers"), history.text)
        XCTAssertTrue(history.text.contains("Who is not known: Config records no CloudTrail event linked to this change. No CloudTrail event in eu-west-1 writes to this resource between"), history.text)
        XCTAssertTrue(history.text.contains("More changes were recorded in the window than the 2 kept"), history.text)
        XCTAssertTrue(history.text.contains("Config records what a resource looked like, not who changed it"), history.text)
        let pages = service.requests.filter { $0.value(forHTTPHeaderField: "X-Amz-Target") == Self.configHistory }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(try json(pages[1])["nextToken"] as? String, "page-2")
        XCTAssertEqual(try json(pages[0])["chronologicalOrder"] as? String, "Reverse")
        let lookups = service.requests.filter { $0.value(forHTTPHeaderField: "X-Amz-Target") == Self.lookupEvents }
        XCTAssertEqual(Set(try lookups.map { try XCTUnwrap((try json($0)["LookupAttributes"] as? [[String: String]])?.first?["AttributeValue"]) }),
                       ["sg-0abc", "web", "arn:aws:ec2:eu-west-1:111111111111:security-group/sg-0abc"])
        XCTAssertTrue(lookups.allSatisfy { $0.url?.host == "cloudtrail.eu-west-1.amazonaws.com" })
        XCTAssertEqual(history.structured?["complete"] as? Bool, false)
        let changes = try XCTUnwrap(history.structured?["changes"] as? [[String: Any]])
        let matched = try XCTUnwrap((changes[0]["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(matched["basis"] as? String, "time-and-resource")
        XCTAssertEqual((matched["event"] as? [String: Any])?["id"] as? String, "e1")
        XCTAssertEqual((changes[1]["events"] as? [[String: Any]])?.count, 0)
    }

    /// Who is said only from the CloudTrail event Config links to a change; writes nearby are candidates, every one of
    /// them, and none after the capture.
    func testConfigHistorySaysWhoOnlyFromLinkedEventsAndListsOthersAsCandidates() async throws {
        let service = FakeService()
        let now = Date().timeIntervalSince1970
        let one = ["groupName": "web", "description": "one"], two = ["groupName": "web", "description": "two"], three = ["groupName": "web", "description": "three"]
        service.answers[Self.configHistory] = (200, Self.body(["configurationItems": [Self.configItem(now - 600, configuration: three, related: ["linked-1"]),
                                                                                      Self.configItem(now - 7_200, configuration: two),
                                                                                      Self.configItem(now - 86_400, configuration: one)]]))
        service.answers["StarlingDoveService.DescribeConfigurationRecorders"] = (200, #"{"ConfigurationRecorders":[{"name":"default","recordingGroup":{"allSupported":true}}]}"#)
        service.answers["StarlingDoveService.DescribeConfigurationRecorderStatus"] = (200, #"{"ConfigurationRecordersStatus":[{"recording":true}]}"#)
        func write(_ id: String, _ user: String, _ time: Double) -> [String: Any] {
            AWSTests.event(id, "ModifySecurityGroupRules", time: time, user: user, detail: [
                "userIdentity": ["type": "IAMUser", "arn": "arn:aws:iam::111111111111:user/\(user)", "accountId": "111111111111"], "readOnly": false])
        }
        // Two people wrote the group between the oldest two configurations; one wrote it just after the newest capture.
        let resourceEvents = Self.body(["Events": [write("late", "mallory", now - 590), write("a", "avery", now - 10_000), write("b", "blake", now - 9_000)]])
        service.sequences[Self.lookupEvents] = [(200, resourceEvents), (200, resourceEvents), (200, resourceEvents),
                                                (200, Self.body(["Events": [write("linked-1", "casey", now - 700)]]))]
        let history = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc","limit":2}"#, on: service, in: aws)
        XCTAssertFalse(history.isError, history.text)
        let lines = history.text.split(separator: "\n").map(String.init)
        let newest = try XCTUnwrap(lines.firstIndex { $0.contains(": changed") }), older = try XCTUnwrap(lines.lastIndex { $0.contains(": changed") })
        XCTAssertTrue(lines[newest..<older].contains { $0.hasPrefix("  Who, from the CloudTrail event Config links to this change: ") && $0.contains("by casey") }, history.text)
        XCTAssertFalse(lines[newest..<older].contains { $0.contains("mallory") }, "an event after the capture is no candidate:\n\(history.text)")
        let tail = lines[older...]
        XCTAssertTrue(tail.contains { $0.hasPrefix("  Who is not known: Config records no CloudTrail event linked to this change. Candidates") }, history.text)
        XCTAssertTrue(tail.contains { $0.hasPrefix("  - ") && $0.contains("by avery") } && tail.contains { $0.hasPrefix("  - ") && $0.contains("by blake") }, history.text)
        XCTAssertFalse(tail.contains { $0.hasPrefix("  Who,") }, history.text)
        XCTAssertFalse(history.text.contains("mallory"), history.text)
        let byEventID = try XCTUnwrap(service.requests.last { $0.value(forHTTPHeaderField: "X-Amz-Target") == Self.lookupEvents })
        XCTAssertEqual((try json(byEventID)["LookupAttributes"] as? [[String: String]])?.first, ["AttributeKey": "EventId", "AttributeValue": "linked-1"])
        let changes = try XCTUnwrap(history.structured?["changes"] as? [[String: Any]])
        XCTAssertEqual((changes[0]["events"] as? [[String: Any]])?.compactMap { $0["basis"] as? String }, ["linked"])
        XCTAssertEqual((changes[1]["events"] as? [[String: Any]])?.compactMap { $0["basis"] as? String }, ["time-and-resource", "time-and-resource"])
        XCTAssertEqual(changes[1]["candidates"] as? Int, 2)
    }

    /// A resource Config never recorded is said with why, and a malformed or refused answer is an error, never "no changes".
    func testConfigHistorySaysWhenConfigDoesNotRecordAndFailsOnBadAnswers() async throws {
        let service = FakeService()
        service.answers["StarlingDoveService.DescribeConfigurationRecorders"] = (200, #"{"ConfigurationRecorders":[{"name":"default","recordingGroup":{"allSupported":false,"resourceTypes":["AWS::S3::Bucket"],"recordingStrategy":{"useOnly":"INCLUSION_BY_RESOURCE_TYPES"}}}]}"#)
        service.answers["StarlingDoveService.DescribeConfigurationRecorderStatus"] = (200, #"{"ConfigurationRecordersStatus":[{"name":"default","recording":true}]}"#)
        service.answers[Self.configHistory] = (400, #"{"__type":"ResourceNotDiscoveredException","message":"Resource sg-0abc of resourceType:AWS::EC2::SecurityGroup is unknown or has not been discovered"}"#)
        let unknown = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc"}"#, on: service, in: aws)
        XCTAssertFalse(unknown.isError, unknown.text)
        XCTAssertTrue(unknown.text.contains("AWS Config has no record of AWS::EC2::SecurityGroup sg-0abc in account Production (111111111111) in eu-west-1."), unknown.text)
        XCTAssertTrue(unknown.text.contains("is recording, but not AWS::EC2::SecurityGroup, so its changes are not kept."), unknown.text)

        service.answers["StarlingDoveService.DescribeConfigurationRecorders"] = (200, #"{"ConfigurationRecorders":[]}"#)
        service.answers[Self.configHistory] = (200, #"{"configurationItems":[]}"#)
        let none = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::IAM::Role","resourceId":"AROAEXAMPLE","region":"us-east-1"}"#, on: service, in: aws)
        XCTAssertTrue(none.text.contains("no configuration recorded") && none.text.contains("AWS Config has no configuration recorder in account Production (111111111111) in us-east-1"), none.text)

        service.answers[Self.configHistory] = (200, #"{"configurationItems":[{"configurationItemStatus":"OK"}]}"#)
        let malformed = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc"}"#, on: service, in: aws)
        XCTAssertTrue(malformed.isError, malformed.text)
        service.answers[Self.configHistory] = (200, #"{"configurationItems":"none"}"#)
        let shapeless = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc"}"#, on: service, in: aws)
        XCTAssertTrue(shapeless.isError, shapeless.text)

        service.answers[Self.configHistory] = (400, #"{"__type":"AccessDeniedException","message":"User is not authorized to perform: config:GetResourceConfigHistory"}"#)
        let refused = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc"}"#, on: service, in: aws)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("add config:GetResourceConfigHistory to the permission set"), refused.text)

        let before = service.requests.count
        for bad in [#"{"resourceType":"SecurityGroup","resourceId":"sg-1"}"#, #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg\"1"}"#,
                    #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-1","region":"eu-west-1.evil.example"}"#] {
            let refused = try await callTool(AWS.adapter, "config-history", bad, on: service, in: aws)
            XCTAssertTrue(refused.isError, bad)
        }
        XCTAssertEqual(service.requests.count, before, "bad input reached the network")
    }

    /// A CloudTrail event Config links but that cannot be read is said as such, with why, never as no link.
    func testConfigHistorySaysWhenALinkedEventCouldNotBeRead() async throws {
        let service = FakeService()
        let now = Date().timeIntervalSince1970
        let linked = (0...10).map { String(format: "linked-%02d", $0) }
        service.answers[Self.configHistory] = (200, Self.body(["configurationItems": [Self.configItem(now - 600, configuration: ["description": "two"], related: linked),
                                                                                      Self.configItem(now - 7_200, configuration: ["description": "one"])]]))
        service.answers["StarlingDoveService.DescribeConfigurationRecorders"] = (200, #"{"ConfigurationRecorders":[{"name":"default","recordingGroup":{"allSupported":true}}]}"#)
        service.answers["StarlingDoveService.DescribeConfigurationRecorderStatus"] = (200, #"{"ConfigurationRecordersStatus":[{"recording":true}]}"#)
        service.answers[Self.lookupEvents] = (200, #"{"Events":[]}"#)
        let history = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc","limit":1}"#, on: service, in: aws)
        XCTAssertFalse(history.isError, history.text)
        XCTAssertTrue(history.text.contains("  Who is not known: Config links CloudTrail event linked-00 to this change, but it could not be read: CloudTrail's event history in eu-west-1 does not hold it; it keeps 90 days."), history.text)
        XCTAssertTrue(history.text.contains("  Who is not known: Config links CloudTrail event linked-10 to this change, but it could not be read: the lookup limit of 10 linked events was reached."), history.text)
        XCTAssertFalse(history.text.contains("Config records no CloudTrail event linked"), history.text)
        XCTAssertTrue(history.text.contains("11 CloudTrail events Config links to these changes could not be read; at most 10 are looked up by ID"), history.text)
        let byID = service.requests.filter { (try? json($0)["LookupAttributes"] as? [[String: String]])??.first?["AttributeKey"] == "EventId" }
        XCTAssertEqual(byID.count, 10)
        XCTAssertEqual(history.structured?["linkedLookupLimit"] as? Int, 10)
        XCTAssertEqual(history.structured?["linkedUnread"] as? Int, 11)
        XCTAssertEqual(history.structured?["complete"] as? Bool, false)
        let change = try XCTUnwrap((history.structured?["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual((change["linkedUnread"] as? [[String: Any]])?.count, 11)

        // CloudTrail refusing says so for the linked event too.
        service.answers[Self.lookupEvents] = (400, #"{"__type":"AccessDeniedException","message":"not authorized to perform: cloudtrail:LookupEvents"}"#)
        let refused = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc","limit":1}"#, on: service, in: aws)
        XCTAssertTrue(refused.text.contains("Config links CloudTrail event linked-00 to this change, but it could not be read: CloudTrail refused or failed: the role may not do this: add cloudtrail:LookupEvents"), refused.text)
        XCTAssertFalse(refused.text.contains("Config records no CloudTrail event linked"), refused.text)

        // No link at all is said as that.
        service.answers[Self.configHistory] = (200, Self.body(["configurationItems": [Self.configItem(now - 600, configuration: ["description": "two"]),
                                                                                      Self.configItem(now - 7_200, configuration: ["description": "one"])]]))
        service.answers[Self.lookupEvents] = (200, #"{"Events":[]}"#)
        let none = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc","limit":1}"#, on: service, in: aws)
        XCTAssertTrue(none.text.contains("  Who is not known: Config records no CloudTrail event linked to this change. No CloudTrail event in eu-west-1 writes to this resource between"), none.text)
        XCTAssertEqual(none.structured?["linkedUnread"] as? Int, 0)
    }

    /// A change whose interval CloudTrail did not search in full says "none found in the events read" and why, and the
    /// result is incomplete; a linked event read and another not are both said.
    func testConfigHistorySaysHowMuchOfEachIntervalCloudTrailSearched() async throws {
        let service = FakeService()
        let now = Date().timeIntervalSince1970
        service.answers[Self.configHistory] = (200, Self.body(["configurationItems": [Self.configItem(now - 600, configuration: ["description": "two"]),
                                                                                      Self.configItem(now - 7_200, configuration: ["description": "one"])]]))
        service.answers["StarlingDoveService.DescribeConfigurationRecorders"] = (200, #"{"ConfigurationRecorders":[{"name":"default","recordingGroup":{"allSupported":true}}]}"#)
        service.answers["StarlingDoveService.DescribeConfigurationRecorderStatus"] = (200, #"{"ConfigurationRecordersStatus":[{"recording":true}]}"#)
        let request = #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc","limit":1}"#

        // The resource's lookup fails.
        service.answers[Self.lookupEvents] = (400, #"{"__type":"AccessDeniedException","message":"not authorized to perform: cloudtrail:LookupEvents"}"#)
        let failed = try await callTool(AWS.adapter, "config-history", request, on: service, in: aws)
        XCTAssertFalse(failed.isError, failed.text)
        XCTAssertTrue(failed.text.contains("  Who is not known: Config records no CloudTrail event linked to this change. None found in the events read, so whether one exists is not known: CloudTrail's event history in eu-west-1 could not be searched: the role may not do this: add cloudtrail:LookupEvents"), failed.text)
        XCTAssertFalse(failed.text.contains("No CloudTrail event in eu-west-1 writes"), failed.text)
        XCTAssertEqual(failed.structured?["complete"] as? Bool, false)
        XCTAssertEqual((failed.structured?["trailCoverage"] as? [String: Any])?["state"] as? String, "failed")
        XCTAssertEqual(((failed.structured?["changes"] as? [[String: Any]])?.first?["trailCoverage"] as? [String: Any])?["state"] as? String, "failed")

        // The lookup stops with pages remaining, having read back only to just before the capture.
        let read = AWSTests.event("r1", "DescribeSecurityGroups", time: now - 650, user: "auditor", detail: ["readOnly": true])
        service.answers[Self.lookupEvents] = (200, Self.body(["Events": [read], "NextToken": "more"]))
        let partial = try await callTool(AWS.adapter, "config-history", request, on: service, in: aws)
        XCTAssertTrue(partial.text.contains("  Who is not known: Config records no CloudTrail event linked to this change. None found in the events read, so whether one exists is not known: CloudTrail held more events on the resource than were read, so it was searched back only to "), partial.text)
        XCTAssertFalse(partial.text.contains("No CloudTrail event in eu-west-1 writes"), partial.text)
        XCTAssertEqual(partial.structured?["complete"] as? Bool, false)
        let coverage = try XCTUnwrap((partial.structured?["changes"] as? [[String: Any]])?.first?["trailCoverage"] as? [String: Any])
        XCTAssertEqual(coverage["state"] as? String, "partial")
        XCTAssertTrue((coverage["reason"] as? String)?.contains("searched back only to") == true)

        // Every interval searched: complete.
        service.answers[Self.lookupEvents] = (200, #"{"Events":[]}"#)
        let whole = try await callTool(AWS.adapter, "config-history", request, on: service, in: aws)
        XCTAssertTrue(whole.text.contains("No CloudTrail event in eu-west-1 writes to this resource between"), whole.text)
        XCTAssertEqual((whole.structured?["trailCoverage"] as? [String: Any])?["state"] as? String, "complete")
        XCTAssertEqual(whole.structured?["complete"] as? Bool, false, "an older change in the window was not kept")
        XCTAssertTrue(whole.text.contains("More changes were recorded in the window than the 1 kept"), whole.text)
        let all = try await callTool(AWS.adapter, "config-history", #"{"resourceType":"AWS::EC2::SecurityGroup","resourceId":"sg-0abc","limit":2}"#, on: service, in: aws)
        XCTAssertEqual(all.structured?["complete"] as? Bool, true, all.text)

        // One linked event read and one not: both are said.
        service.answers[Self.configHistory] = (200, Self.body(["configurationItems": [Self.configItem(now - 600, configuration: ["description": "two"], related: ["e-ok", "e-gone"]),
                                                                                      Self.configItem(now - 7_200, configuration: ["description": "one"])]]))
        let ok = AWSTests.event("e-ok", "ModifySecurityGroupRules", time: now - 700, user: "casey", detail: [
            "userIdentity": ["type": "IAMUser", "arn": "arn:aws:iam::111111111111:user/casey", "accountId": "111111111111"], "readOnly": false])
        service.answers[Self.lookupEvents] = (200, Self.body(["Events": [ok]]))
        let both = try await callTool(AWS.adapter, "config-history", request, on: service, in: aws)
        XCTAssertTrue(both.text.contains("  Who, from the CloudTrail event Config links to this change: ") && both.text.contains("by casey"), both.text)
        XCTAssertTrue(both.text.contains("  Config also links CloudTrail event e-gone to this change, but it could not be read: CloudTrail's event history in eu-west-1 does not hold it"), both.text)
        XCTAssertFalse(both.text.contains("Who is not known"), both.text)
        XCTAssertEqual(both.structured?["complete"] as? Bool, false)
    }

    // MARK: s3-exposure

    static let blockNone = "<PublicAccessBlockConfiguration><BlockPublicAcls>false</BlockPublicAcls><IgnorePublicAcls>false</IgnorePublicAcls><BlockPublicPolicy>false</BlockPublicPolicy><RestrictPublicBuckets>false</RestrictPublicBuckets></PublicAccessBlockConfiguration>"
    static let blockAll = "<PublicAccessBlockConfiguration><BlockPublicAcls>true</BlockPublicAcls><IgnorePublicAcls>true</IgnorePublicAcls><BlockPublicPolicy>true</BlockPublicPolicy><RestrictPublicBuckets>true</RestrictPublicBuckets></PublicAccessBlockConfiguration>"
    static func acl(_ grants: String) -> String {
        "<AccessControlPolicy><Owner><ID>ownerid</ID></Owner><AccessControlList><Grant><Grantee><ID>ownerid</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant>\(grants)</AccessControlList></AccessControlPolicy>"
    }

    /// Every bucket's settings add up to a verdict: public through its policy or ACL, shared with other accounts, or
    /// neither; and an account with more buckets than read says so.
    func testS3ExposureSaysWhichBucketsArePublicOrSharedAndWhy() async throws {
        let service = FakeService()
        service.answers["?max-buckets=3"] = (200, """
        <ListAllMyBucketsResult><Owner><ID>ownerid</ID></Owner><Buckets>
        <Bucket><Name>public-site</Name><BucketRegion>us-east-1</BucketRegion></Bucket>
        <Bucket><Name>partner-share</Name><BucketRegion>eu-west-1</BucketRegion></Bucket>
        <Bucket><Name>zz-private</Name><BucketRegion>eu-west-1</BucketRegion></Bucket>
        </Buckets><ContinuationToken>next</ContinuationToken></ListAllMyBucketsResult>
        """)
        service.answers["/v20180820/configuration/publicAccessBlock"] = (404, "<Error><Code>NoSuchPublicAccessBlockConfiguration</Code><Message>none</Message></Error>")
        service.answers["/public-site?publicAccessBlock="] = (200, Self.blockNone)
        service.answers["/public-site?policyStatus="] = (200, "<PolicyStatus><IsPublic>true</IsPublic></PolicyStatus>")
        service.answers["/public-site?policy="] = (200, #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::public-site/*"}]}"#)
        service.answers["/public-site?acl="] = (200, Self.acl(#"<Grant><Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group"><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant>"#))
        service.answers["/public-site?ownershipControls="] = (404, "<Error><Code>OwnershipControlsNotFoundError</Code><Message>none</Message></Error>")
        service.answers["/partner-share?publicAccessBlock="] = (200, Self.blockAll)
        service.answers["/partner-share?policyStatus="] = (200, "<PolicyStatus><IsPublic>false</IsPublic></PolicyStatus>")
        service.answers["/partner-share?policy="] = (200, #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":["arn:aws:iam::999999999999:root"]},"Action":["s3:GetObject","s3:ListBucket"],"Resource":"*","Condition":{"StringEquals":{"aws:PrincipalOrgID":"o-partner"}}}]}"#)
        service.answers["/partner-share?acl="] = (200, Self.acl(""))
        service.answers["/partner-share?ownershipControls="] = (200, "<OwnershipControls><Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule></OwnershipControls>")
        service.answers["/analyzer"] = (200, #"{"analyzers":[{"arn":"arn:aws:access-analyzer:eu-west-1:111111111111:analyzer/a","type":"ACCOUNT","status":"ACTIVE"}]}"#)
        service.answers["/finding"] = (200, #"{"findings":[{"resource":"arn:aws:s3:::public-site","isPublic":true},{"resource":"arn:aws:s3:::partner-share","isPublic":false,"principal":{"AWS":"999999999999"},"condition":{"aws:PrincipalOrgID":"o-partner"}}]}"#)
        let exposure = try await callTool(AWS.adapter, "s3-exposure", #"{"limit":2}"#, on: service, in: aws)
        XCTAssertFalse(exposure.isError, exposure.text)
        let lines = exposure.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "account Production (111111111111): 2 buckets; the account's Block Public Access: none set.")
        let site = try XCTUnwrap(lines.first { $0.hasPrefix("public-site [us-east-1]: PUBLIC — ") }, exposure.text)
        for said in ["public through its bucket policy", "public through its ACL: everyone: READ", "Access Analyzer reports it public", "Block Public Access none on", "public grants seen: its policy: Principal * may s3:GetObject, with no condition; its ACL: everyone: READ", "object ownership ObjectWriter (none set)"] {
            XCTAssertTrue(site.contains(said), "\(said): \(site)")
        }
        let share = try XCTUnwrap(lines.first { $0.hasPrefix("partner-share [eu-west-1]: shared with other accounts — ") }, exposure.text)
        XCTAssertTrue(share.contains("its policy: account 999999999999, outside the accounts the sign-in covers may s3:GetObject, s3:ListBucket, when aws:PrincipalOrgID StringEquals o-partner"), share)
        XCTAssertTrue(share.contains("Access Analyzer: shared with AWS 999999999999 under conditions") && share.contains("Block Public Access all four on"), share)
        XCTAssertFalse(exposure.text.contains("zz-private"), "past the limit")
        XCTAssertTrue(exposure.text.contains("The account has more buckets than the 2 read"), exposure.text)
        XCTAssertEqual(exposure.structured?["complete"] as? Bool, false)
        let siteRequests = service.requests.filter { $0.url?.path == "/public-site" }
        XCTAssertEqual(Set(siteRequests.map { $0.url?.host }), ["s3.us-east-1.amazonaws.com"], "each bucket is read in its own region")
        XCTAssertTrue(siteRequests.allSatisfy { $0.value(forHTTPHeaderField: "x-amz-expected-bucket-owner") == "111111111111" })
        XCTAssertEqual(service.requests.first { $0.url?.path.hasPrefix("/v20180820") == true }?.url?.host, "111111111111.s3-control.eu-west-1.amazonaws.com")
        XCTAssertEqual(service.requests.first { $0.url?.query == "max-buckets=3" }?.url?.host, "s3.eu-west-1.amazonaws.com")
    }

    /// A setting that cannot be read leaves a bucket unknown, never private; a bucket in another region is followed
    /// there; a bad name or an unreadable listing is an error.
    func testS3ExposureNeverCallsABucketPrivateWhenASettingWasNotRead() async throws {
        let service = FakeService()
        service.answers["/v20180820/configuration/publicAccessBlock"] = (200, Self.blockNone)
        service.sequences["/moved?publicAccessBlock="] = [(301, "<Error><Code>PermanentRedirect</Code></Error>"), (200, Self.blockNone)]
        service.sequenceHeaders["/moved?publicAccessBlock="] = [["x-amz-bucket-region": "ap-south-1"], [:]]
        service.answers["/moved?policyStatus="] = (200, "<NotPolicyStatus/>")
        service.answers["/moved?policy="] = (404, "<Error><Code>NoSuchBucketPolicy</Code><Message>none</Message></Error>")
        service.answers["/moved?acl="] = (403, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
        service.answers["/moved?ownershipControls="] = (200, "<OwnershipControls><Rule><ObjectOwnership>BucketOwnerPreferred</ObjectOwnership></Rule></OwnershipControls>")
        service.answers["/analyzer"] = (200, #"{"analyzers":[]}"#)
        let moved = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"moved"}"#, on: service, in: aws)
        XCTAssertFalse(moved.isError, moved.text)
        let line = try XCTUnwrap(moved.text.split(separator: "\n").map(String.init).first { $0.hasPrefix("moved [ap-south-1]: ") }, moved.text)
        XCTAssertTrue(line.contains("not known, as some of its settings could not be read"), line)
        XCTAssertTrue(line.contains("whether S3 judges its policy public (its answer could not be read)"), line)
        XCTAssertTrue(line.contains("its ACL (the role may not do this: add s3:GetBucketAcl"), line)
        XCTAssertFalse(moved.text.contains("not public or shared"), moved.text)
        XCTAssertTrue(moved.text.contains("No external access analyzer is active in ap-south-1"), moved.text)
        XCTAssertEqual(service.requests.filter { $0.url?.path == "/moved" }.map { $0.url?.host }.first, "s3.eu-west-1.amazonaws.com")
        XCTAssertTrue(service.requests.filter { $0.url?.path == "/moved" }.dropFirst().allSatisfy { $0.url?.host == "s3.ap-south-1.amazonaws.com" })

        service.answers["/gone?publicAccessBlock="] = (404, "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message></Error>")
        let gone = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"gone"}"#, on: service, in: aws)
        XCTAssertTrue(gone.isError && gone.text.contains("S3 has no bucket gone"), gone.text)

        service.answers["?max-buckets=26"] = (200, "<Something/>")
        let unreadable = try await callTool(AWS.adapter, "s3-exposure", "{}", on: service, in: aws)
        XCTAssertTrue(unreadable.isError, unreadable.text)
        service.answers["?max-buckets=26"] = (403, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
        let denied = try await callTool(AWS.adapter, "s3-exposure", "{}", on: service, in: aws)
        XCTAssertTrue(denied.isError && denied.text.contains("add s3:ListAllMyBuckets"), denied.text)

        let before = service.requests.count
        for bad in [#"{"bucket":"evil.example/x"}"#, #"{"bucket":"UPPER"}"#, #"{"bucket":"a"}"#, #"{"limit":500}"#] {
            let refused = try await callTool(AWS.adapter, "s3-exposure", bad, on: service, in: aws)
            XCTAssertTrue(refused.isError, bad)
        }
        XCTAssertEqual(service.requests.count, before, "bad input reached the network")
    }

    /// A public grant whose blocking control could not be read is seen, but not called public: "possibly public",
    /// with the control unknown; and an unread policy status is never said as S3 judging it not public.
    func testS3ExposureSeparatesGrantsSeenFromAccessInEffectWhenAControlIsUnread() async throws {
        let service = FakeService()
        service.answers["/v20180820/configuration/publicAccessBlock"] = (404, "<Error><Code>NoSuchPublicAccessBlockConfiguration</Code><Message>none</Message></Error>")
        service.answers["/analyzer"] = (200, #"{"analyzers":[]}"#)
        // The bucket's Block Public Access is refused, and its policy is public.
        service.answers["/site?publicAccessBlock="] = (403, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
        service.answers["/site?policyStatus="] = (200, "<PolicyStatus><IsPublic>true</IsPublic></PolicyStatus>")
        service.answers["/site?policy="] = (200, #"{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*"}]}"#)
        service.answers["/site?acl="] = (200, Self.acl(""))
        service.answers["/site?ownershipControls="] = (200, "<OwnershipControls><Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule></OwnershipControls>")
        let site = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"site"}"#, on: service, in: aws)
        XCTAssertFalse(site.isError, site.text)
        let line = try XCTUnwrap(site.text.split(separator: "\n").map(String.init).first { $0.hasPrefix("site [eu-west-1]: ") }, site.text)
        XCTAssertTrue(line.hasPrefix("site [eu-west-1]: possibly public, not settled from what could be read — "), line)
        XCTAssertTrue(line.contains("S3 judges its policy public; it is effectively public unless RestrictPublicBuckets is on, which could not be read"), line)
        XCTAssertTrue(line.contains("public grants seen: its policy: Principal * may s3:GetObject"), line)
        XCTAssertTrue(line.contains("unknown controls: BlockPublicAcls, BlockPublicPolicy, IgnorePublicAcls, RestrictPublicBuckets"), line)
        XCTAssertFalse(line.contains("PUBLIC") || line.contains("effectively public through"), line)
        let bucket = try XCTUnwrap((site.structured?["buckets"] as? [[String: Any]])?.first)
        XCTAssertEqual((bucket["controls"] as? [String: String])?["RestrictPublicBuckets"], "unknown")
        XCTAssertEqual((bucket["exposures"] as? [String])?.count, 0)
        XCTAssertEqual(site.structured?["complete"] as? Bool, false)

        // Its object ownership is refused, and its ACL grants everyone: Block Public Access is read as off, ACLs are not known.
        service.answers["/site?publicAccessBlock="] = (200, Self.blockNone)
        service.answers["/site?policyStatus="] = (404, "<Error><Code>NoSuchBucketPolicy</Code><Message>none</Message></Error>")
        service.answers["/site?policy="] = (404, "<Error><Code>NoSuchBucketPolicy</Code><Message>none</Message></Error>")
        service.answers["/site?acl="] = (200, Self.acl(#"<Grant><Grantee><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant>"#))
        service.answers["/site?ownershipControls="] = (403, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
        let acl = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"site"}"#, on: service, in: aws)
        let aclLine = try XCTUnwrap(acl.text.split(separator: "\n").map(String.init).first { $0.hasPrefix("site [eu-west-1]: ") }, acl.text)
        XCTAssertTrue(aclLine.hasPrefix("site [eu-west-1]: possibly public"), aclLine)
        XCTAssertTrue(aclLine.contains("its ACL grants everyone: READ; it is effectively public unless ACLs are off or IgnorePublicAcls is on, and its object ownership could not be read"), aclLine)
        XCTAssertTrue(aclLine.contains("unknown controls: ACLs disabled (BucketOwnerEnforced)"), aclLine)
        XCTAssertFalse(aclLine.contains("PUBLIC"), aclLine)

        // Whether S3 judges a policy naming Principal * public could not be read: it is not said to judge it not public.
        service.answers["/site?ownershipControls="] = (200, "<OwnershipControls><Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule></OwnershipControls>")
        service.answers["/site?policyStatus="] = (403, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
        service.answers["/site?policy="] = (200, #"{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*","Condition":{"IpAddress":{"aws:SourceIp":"203.0.113.0/24"}}}]}"#)
        let status = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"site"}"#, on: service, in: aws)
        XCTAssertTrue(status.text.contains("its policy names Principal *, and whether S3 judges that public could not be read"), status.text)
        XCTAssertFalse(status.text.contains("S3 judges it not public"), status.text)
        XCTAssertTrue(status.text.contains("site [eu-west-1]: possibly public"), status.text)

        // Every control read and off: the same grant is in effect.
        service.answers["/site?policyStatus="] = (200, "<PolicyStatus><IsPublic>true</IsPublic></PolicyStatus>")
        let open = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"site"}"#, on: service, in: aws)
        XCTAssertTrue(open.text.contains("site [eu-west-1]: PUBLIC — effectively public through its bucket policy: S3 judges it public and RestrictPublicBuckets is off at both levels"), open.text)
    }

    /// Grants to other accounts in a policy S3 judges public are blocked by RestrictPublicBuckets, possibly shared
    /// when it could not be read, and shared when the policy is not public, which RestrictPublicBuckets leaves alone.
    func testS3ExposureQualifiesSharingByAPublicPolicyWithRestrictPublicBuckets() async throws {
        let service = FakeService()
        service.answers["/v20180820/configuration/publicAccessBlock"] = (200, Self.blockAll)
        service.answers["/analyzer"] = (200, #"{"analyzers":[]}"#)
        service.answers["/site?publicAccessBlock="] = (200, Self.blockNone)
        service.answers["/site?policyStatus="] = (200, "<PolicyStatus><IsPublic>true</IsPublic></PolicyStatus>")
        service.answers["/site?policy="] = (200, #"{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*"},{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::999999999999:root"},"Action":"s3:PutObject","Resource":"*"}]}"#)
        service.answers["/site?acl="] = (200, Self.acl(""))
        service.answers["/site?ownershipControls="] = (200, "<OwnershipControls><Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule></OwnershipControls>")
        let blocked = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"site"}"#, on: service, in: aws)
        let line = try XCTUnwrap(blocked.text.split(separator: "\n").map(String.init).first { $0.hasPrefix("site [eu-west-1]: ") }, blocked.text)
        XCTAssertTrue(line.hasPrefix("site [eu-west-1]: not public or shared with other accounts, by its settings — "), line)
        XCTAssertTrue(line.contains("its policy grants other accounts (account 999999999999, outside the accounts the sign-in covers may s3:PutObject, with no condition), but as S3 judges the policy public and RestrictPublicBuckets is on, that access is blocked"), line)
        XCTAssertTrue(line.contains("public grants seen: its policy: Principal * may s3:GetObject"), line)
        XCTAssertEqual(((blocked.structured?["buckets"] as? [[String: Any]])?.first?["shared"] as? [String])?.count, 0)

        // RestrictPublicBuckets not read: possibly shared, never "shared" or "blocked".
        service.answers["/v20180820/configuration/publicAccessBlock"] = (403, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
        let unknown = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"site"}"#, on: service, in: aws)
        let unknownLine = try XCTUnwrap(unknown.text.split(separator: "\n").map(String.init).first { $0.hasPrefix("site [eu-west-1]: ") }, unknown.text)
        XCTAssertTrue(unknownLine.hasPrefix("site [eu-west-1]: possibly public, not settled from what could be read, and possibly shared with other accounts — "), unknownLine)
        XCTAssertTrue(unknownLine.contains("possibly shared: its policy: account 999999999999") && unknownLine.contains("RestrictPublicBuckets could not be read"), unknownLine)
        XCTAssertFalse(unknownLine.contains("that access is blocked"), unknownLine)

        // A policy S3 judges not public keeps its grants to other accounts, RestrictPublicBuckets on or not.
        service.answers["/v20180820/configuration/publicAccessBlock"] = (200, Self.blockAll)
        service.answers["/site?policyStatus="] = (200, "<PolicyStatus><IsPublic>false</IsPublic></PolicyStatus>")
        service.answers["/site?policy="] = (200, #"{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::999999999999:root"},"Action":"s3:PutObject","Resource":"*"}]}"#)
        let shared = try await callTool(AWS.adapter, "s3-exposure", #"{"bucket":"site"}"#, on: service, in: aws)
        XCTAssertTrue(shared.text.contains("site [eu-west-1]: shared with other accounts — its policy: account 999999999999"), shared.text)
    }

    // MARK: identity-center-assignments

    static func sso(_ operation: String) -> String { "SWBExternalService." + operation }
    static func store(_ operation: String) -> String { "AWSIdentityStore." + operation }
    static let instance = #"{"Instances":[{"InstanceArn":"arn:aws:sso:::instance/ssoins-0123456789abcdef","IdentityStoreId":"d-1234567890"}]}"#

    /// Who holds which permission set where, by name, with administrators flagged, page after page.
    func testIdentityCenterAssignmentsSayWhoHoldsWhichPermissionSetWhere() async throws {
        let service = FakeService()
        service.answers[Self.sso("ListInstances")] = (200, Self.instance)
        service.sequences[Self.sso("ListPermissionSets")] = [(200, #"{"PermissionSets":["arn:aws:sso:::permissionSet/ssoins-0123456789abcdef/ps-aaaaaaaaaaaaaaaa"],"NextToken":"t"}"#),
                                                             (200, #"{"PermissionSets":["arn:aws:sso:::permissionSet/ssoins-0123456789abcdef/ps-bbbbbbbbbbbbbbbb"]}"#)]
        service.sequences[Self.sso("DescribePermissionSet")] = [(200, #"{"PermissionSet":{"Name":"Admin"}}"#), (200, #"{"PermissionSet":{"Name":"Breakglass"}}"#)]
        service.sequences[Self.sso("ListAccountsForProvisionedPermissionSet")] = [(200, #"{"AccountIds":["111111111111","333333333333"]}"#), (200, #"{"AccountIds":["111111111111"]}"#)]
        service.sequences[Self.sso("ListAccountAssignments")] = [
            (200, #"{"AccountAssignments":[{"AccountId":"111111111111","PrincipalType":"GROUP","PrincipalId":"g-admins"}],"NextToken":"more"}"#),
            (200, #"{"AccountAssignments":[{"AccountId":"111111111111","PrincipalType":"USER","PrincipalId":"u-alice"}]}"#),
            (200, #"{"AccountAssignments":[{"AccountId":"333333333333","PrincipalType":"USER","PrincipalId":"u-alice"}]}"#),
            (200, #"{"AccountAssignments":[{"AccountId":"111111111111","PrincipalType":"GROUP","PrincipalId":"g-oncall"}]}"#),
        ]
        service.sequences[Self.sso("ListManagedPoliciesInPermissionSet")] = [(200, #"{"AttachedManagedPolicies":[{"Name":"AdministratorAccess","Arn":"arn:aws:iam::aws:policy/AdministratorAccess"}]}"#),
                                                                              (200, #"{"AttachedManagedPolicies":[]}"#)]
        service.sequences[Self.sso("GetInlinePolicyForPermissionSet")] = [(200, #"{"InlinePolicy":""}"#),
                                                                           (200, Self.body(["InlinePolicy": #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*:*","Resource":"*"}]}"#]))]
        service.sequences[Self.store("DescribeGroup")] = [(200, #"{"DisplayName":"Admins"}"#), (200, #"{"DisplayName":"On-call"}"#)]
        service.answers[Self.store("DescribeUser")] = (200, #"{"UserName":"alice@example.com"}"#)
        let held = try await callTool(AWS.adapter, "identity-center-assignments", "{}", on: service, in: aws)
        XCTAssertFalse(held.isError, held.text)
        let lines = held.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "IAM Identity Center ssoins-0123456789abcdef, read from account Production (111111111111) in eu-west-1: 4 assignments of 2 permission sets in 2 accounts.")
        XCTAssertTrue(held.text.contains("Full administrator permission sets: Admin (AdministratorAccess); Breakglass (an inline policy allowing everything)."), held.text)
        XCTAssertTrue(lines.contains("Account Production (111111111111):"), held.text)
        XCTAssertTrue(lines.contains("- Admin [full administrator]: group Admins, user alice@example.com"), held.text)
        XCTAssertTrue(lines.contains("- Breakglass [full administrator]: group On-call"), held.text)
        XCTAssertTrue(lines.contains("Account 333333333333:"), held.text)
        XCTAssertFalse(held.text.contains("Stopped after"), held.text)
        let assignments = service.requests.filter { $0.value(forHTTPHeaderField: "X-Amz-Target") == Self.sso("ListAccountAssignments") }
        XCTAssertEqual(try json(assignments[1])["NextToken"] as? String, "more")
        XCTAssertEqual(try json(assignments[0])["AccountId"] as? String, "111111111111")
        XCTAssertEqual(Set(service.requests.compactMap { $0.url?.host }), ["sso.eu-west-1.amazonaws.com", "identitystore.eu-west-1.amazonaws.com"])
        XCTAssertEqual(held.structured?["complete"] as? Bool, true)
    }

    /// A user stands for themselves and their groups; what cannot be found, refused or read is said, never "no one".
    func testIdentityCenterAssignmentsFilterByUserAndSayWhatCouldNotBeRead() async throws {
        let service = FakeService()
        service.answers[Self.sso("ListInstances")] = (200, Self.instance)
        service.answers[Self.store("GetUserId")] = (200, #"{"UserId":"u-alice","IdentityStoreId":"d-1234567890"}"#)
        service.answers[Self.store("ListGroupMembershipsForMember")] = (200, #"{"GroupMemberships":[{"GroupId":"g-admins"}]}"#)
        service.answers[Self.sso("DescribePermissionSet")] = (200, #"{"PermissionSet":{"Name":"Admin"}}"#)
        service.answers[Self.sso("ListAccountAssignments")] = (200, #"{"AccountAssignments":[{"AccountId":"111111111111","PrincipalType":"GROUP","PrincipalId":"g-admins"},{"AccountId":"111111111111","PrincipalType":"GROUP","PrincipalId":"g-other"}]}"#)
        service.answers[Self.sso("ListManagedPoliciesInPermissionSet")] = (200, #"{"AttachedManagedPolicies":[]}"#)
        service.answers[Self.sso("GetInlinePolicyForPermissionSet")] = (200, #"{}"#)
        service.answers[Self.store("DescribeGroup")] = (400, #"{"__type":"AccessDeniedException","Message":"not authorized to perform identitystore:DescribeGroup"}"#)
        let ps = "arn:aws:sso:::permissionSet/ssoins-0123456789abcdef/ps-aaaaaaaaaaaaaaaa"
        let alice = try await callTool(AWS.adapter, "identity-center-assignments", #"{"principal":"alice@example.com","inAccount":"Production","permissionSet":"\#(ps)"}"#, on: service, in: aws)
        XCTAssertFalse(alice.isError, alice.text)
        XCTAssertTrue(alice.text.contains("for user alice@example.com and the 1 group they are in: 1 assignment"), alice.text)
        XCTAssertTrue(alice.text.contains("- Admin: group g-admins"), alice.text)
        XCTAssertFalse(alice.text.contains("g-other"), alice.text)
        XCTAssertTrue(alice.text.contains("names could not be read") && alice.text.contains("add identitystore:DescribeGroup"), alice.text)
        XCTAssertNil(service.requests.first { $0.value(forHTTPHeaderField: "X-Amz-Target") == Self.sso("ListAccountsForProvisionedPermissionSet") }, "the account was named")

        service.answers[Self.store("GetUserId")] = (400, #"{"__type":"ResourceNotFoundException","Message":"USER not found"}"#)
        service.answers[Self.store("GetGroupId")] = (400, #"{"__type":"ResourceNotFoundException","Message":"GROUP not found"}"#)
        // An inline policy that cannot be read leaves the set neither administrator nor not.
        service.answers[Self.store("GetUserId")] = (200, #"{"UserId":"u-alice","IdentityStoreId":"d-1234567890"}"#)
        service.answers[Self.store("DescribeGroup")] = (200, #"{"DisplayName":"Admins"}"#)
        service.answers[Self.sso("ListAccountAssignments")] = (200, #"{"AccountAssignments":[{"AccountId":"111111111111","PrincipalType":"GROUP","PrincipalId":"g-admins"}]}"#)
        service.answers[Self.sso("GetInlinePolicyForPermissionSet")] = (200, #"{"InlinePolicy":"{not json"}"#)
        let unread = try await callTool(AWS.adapter, "identity-center-assignments", #"{"principal":"alice@example.com","inAccount":"Production","permissionSet":"\#(ps)"}"#, on: service, in: aws)
        service.answers[Self.store("GetUserId")] = (400, #"{"__type":"ResourceNotFoundException","Message":"USER not found"}"#)
        XCTAssertTrue(unread.text.contains("- Admin [whether it makes them administrators is not known]: group Admins"), unread.text)
        XCTAssertTrue(unread.text.contains("The inline policies of Admin could not be read"), unread.text)
        XCTAssertEqual(unread.structured?["complete"] as? Bool, false)
        XCTAssertNil((unread.structured?["assignments"] as? [[String: Any]])?.first?["fullAdministrator"] as? Bool)

        let nobody = try await callTool(AWS.adapter, "identity-center-assignments", #"{"principal":"mallory"}"#, on: service, in: aws)
        XCTAssertTrue(nobody.isError && nobody.text.contains("no user with user name mallory"), nobody.text)

        service.answers[Self.sso("ListAccountAssignments")] = (200, #"{"AccountAssignments":"x"}"#)
        let malformed = try await callTool(AWS.adapter, "identity-center-assignments", #"{"inAccount":"111111111111","permissionSet":"\#(ps)"}"#, on: service, in: aws)
        XCTAssertTrue(malformed.isError, malformed.text)

        service.answers[Self.sso("ListPermissionSets")] = (200, #"{"PermissionSets":[],"NextToken":"forever"}"#)
        let endless = try await callTool(AWS.adapter, "identity-center-assignments", "{}", on: service, in: aws)
        XCTAssertFalse(endless.isError, endless.text)
        XCTAssertTrue(endless.text.contains("Stopped after") && endless.text.contains("some assignments are missing"), endless.text)
        XCTAssertEqual(endless.structured?["complete"] as? Bool, false)

        service.answers[Self.sso("ListInstances")] = (400, #"{"__type":"AccessDeniedException","Message":"User is not authorized to perform: sso:ListInstances"}"#)
        let member = try await callTool(AWS.adapter, "identity-center-assignments", "{}", on: service, in: aws)
        XCTAssertTrue(member.isError)
        XCTAssertTrue(member.text.contains("add sso:ListInstances") && member.text.contains("Only the organisation's management account"), member.text)

        service.answers[Self.sso("ListInstances")] = (200, #"{"Instances":[]}"#)
        let elsewhere = try await callTool(AWS.adapter, "identity-center-assignments", "{}", on: service, in: aws)
        XCTAssertTrue(elsewhere.text.contains("No IAM Identity Center instance answers in account Production (111111111111) in eu-west-1"), elsewhere.text)

        for bad in [#"{"permissionSet":"arn:aws:sso:::permissionSet/x"}"#, #"{"inAccount":"Sandbox"}"#, #"{"principal":"a\"b"}"#] {
            let refused = try await callTool(AWS.adapter, "identity-center-assignments", bad, on: service, in: aws)
            XCTAssertTrue(refused.isError, bad)
        }
    }

    // MARK: credential-hygiene

    func testCredentialHygieneFindsRootKeysMissingMFAAndStaleCredentials() async throws {
        let service = FakeService()
        let iso = ISO8601DateFormatter()
        func ago(_ days: Double) -> String { iso.string(from: Date().addingTimeInterval(-days * 86_400)) }
        let header = "user,arn,user_creation_time,password_enabled,password_last_used,password_last_changed,password_next_rotation,mfa_active,access_key_1_active,access_key_1_last_rotated,access_key_1_last_used_date,access_key_1_last_used_region,access_key_1_last_used_service,access_key_2_active,access_key_2_last_rotated,access_key_2_last_used_date,access_key_2_last_used_region,access_key_2_last_used_service,cert_1_active,cert_1_last_rotated,cert_2_active,cert_2_last_rotated"
        let rows = [
            "<root_account>,arn:aws:iam::111111111111:root,\(ago(900)),not_supported,\(ago(2)),not_supported,not_supported,false,true,\(ago(400)),\(ago(1)),us-east-1,iam,false,N/A,N/A,N/A,N/A,false,N/A,false,N/A",
            "alice,arn:aws:iam::111111111111:user/alice,\(ago(300)),true,\(ago(3)),\(ago(300)),N/A,false,false,N/A,N/A,N/A,N/A,false,N/A,N/A,N/A,N/A,false,N/A,false,N/A",
            "ci-bot,arn:aws:iam::111111111111:user/ci-bot,\(ago(500)),false,N/A,N/A,N/A,false,true,\(ago(200)),N/A,N/A,N/A,true,\(ago(10)),\(ago(1)),eu-west-1,s3,false,N/A,false,N/A",
            "carol,arn:aws:iam::111111111111:user/carol,\(ago(400)),true,\(ago(120)),\(ago(400)),N/A,true,true,\(ago(20)),\(ago(100)),eu-west-1,ec2,false,N/A,N/A,N/A,N/A,false,N/A,false,N/A",
            "dan,arn:aws:iam::111111111111:user/dan,\(ago(10)),true,no_information,\(ago(10)),N/A,true,false,N/A,N/A,N/A,N/A,false,N/A,N/A,N/A,N/A,false,N/A,false,N/A",
            "erin,arn:aws:iam::111111111111:user/erin,\(ago(400)),true,\(ago(1)),\(ago(400)),N/A,maybe,false,N/A,N/A,N/A,N/A,false,N/A,N/A,N/A,N/A,false,N/A,false,N/A",
        ]
        let csv = ([header] + rows).joined(separator: "\n")
        service.answers["action:GenerateCredentialReport"] = (200, "<GenerateCredentialReportResponse><GenerateCredentialReportResult><State>COMPLETE</State></GenerateCredentialReportResult></GenerateCredentialReportResponse>")
        service.answers["action:GetCredentialReport"] = (200, "<GetCredentialReportResponse><GetCredentialReportResult><Content>\(Data(csv.utf8).base64EncodedString())</Content><GeneratedTime>\(ago(0.05))</GeneratedTime></GetCredentialReportResult></GetCredentialReportResponse>")
        let hygiene = try await callTool(AWS.adapter, "credential-hygiene", "{}", on: service, in: aws)
        XCTAssertFalse(hygiene.isError, hygiene.text)
        let lines = hygiene.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "In account Production (111111111111), 5 IAM users; stale means 90 days.")
        XCTAssertTrue(lines[1].hasPrefix("Root: root has no MFA; root has active access key 1 (made 400 days ago): delete root's keys"), hygiene.text)
        XCTAssertEqual(lines[2], "Console users without MFA (1):")
        XCTAssertEqual(lines[3], "- alice")
        XCTAssertTrue(lines.contains("Users with access keys and no MFA, without a console password (1):") && lines.contains("- ci-bot"), hygiene.text)
        XCTAssertTrue(lines.contains("- ci-bot: active access key 1 (made 200 days ago, never used)"), hygiene.text)
        XCTAssertTrue(lines.contains("- carol: active access key 1 (last used 100 days ago)"), hygiene.text)
        XCTAssertTrue(lines.contains("- carol: console password last used 120 days ago"), hygiene.text)
        XCTAssertFalse(lines.contains { $0.hasPrefix("- dan") }, "a new user's unused password is not stale:\n\(hygiene.text)")
        XCTAssertTrue(hygiene.text.contains("From the credential report made ") && hygiene.text.contains("minutes ago; AWS reuses a report up to four hours old"), hygiene.text)
        XCTAssertFalse(lines.contains("- erin"), "an MFA state the report did not give is not \"no MFA\":\n\(hygiene.text)")
        XCTAssertTrue(hygiene.text.contains("could not all be read") && hygiene.text.contains("erin: not known: whether MFA is on"), hygiene.text)
        XCTAssertEqual(hygiene.structured?["complete"] as? Bool, false)

        service.answers["action:GetCredentialReport"] = (200, "<GetCredentialReportResponse><GetCredentialReportResult><Content>\(Data("name,arn\nx,y".utf8).base64EncodedString())</Content></GetCredentialReportResult></GetCredentialReportResponse>")
        let malformed = try await callTool(AWS.adapter, "credential-hygiene", "{}", on: service, in: aws)
        XCTAssertTrue(malformed.isError, malformed.text)
        let days = try await callTool(AWS.adapter, "credential-hygiene", #"{"days":5}"#, on: service, in: aws)
        XCTAssertTrue(days.isError, days.text)
    }

    // MARK: Inspector and Macie

    func testInspectorAndMacieFindingsSayWhatTheyReadAndWhenTheyAreOff() async throws {
        let service = FakeService()
        service.sequences["/findings/list"] = [
            (200, #"{"findings":[{"findingArn":"arn:f1","awsAccountId":"111111111111","severity":"CRITICAL","title":"CVE-2026-0001 - openssl","resources":[{"id":"i-0abc","type":"AWS_EC2_INSTANCE","region":"eu-west-1"}],"exploitAvailable":"YES","fixAvailable":"YES"}],"nextToken":"n"}"#),
            (200, #"{"findings":[{"findingArn":"arn:f2","awsAccountId":"222222222222","severity":"HIGH","title":"CVE-2026-0002 - glibc","resources":[{"id":"i-0def","type":"AWS_EC2_INSTANCE"}]}],"nextToken":"m"}"#),
        ]
        let inspector = try await callTool(AWS.adapter, "inspector-findings", #"{"limit":2}"#, on: service, in: aws)
        XCTAssertFalse(inspector.isError, inspector.text)
        XCTAssertTrue(inspector.text.contains("CRITICAL CVE-2026-0001 - openssl — AWS_EC2_INSTANCE i-0abc, exploit known, fix available"), inspector.text)
        XCTAssertTrue(inspector.text.contains("HIGH CVE-2026-0002 - glibc — AWS_EC2_INSTANCE i-0def in member account 222222222222"), inspector.text)
        XCTAssertTrue(inspector.text.contains("More findings matched than the 2 kept"), inspector.text)
        XCTAssertEqual(service.requests.first?.url?.host, "inspector2.eu-west-1.amazonaws.com")
        let criteria = try XCTUnwrap(try json(service.requests.first)["filterCriteria"] as? [String: Any])
        XCTAssertEqual((criteria["findingStatus"] as? [[String: String]])?.first?["value"], "ACTIVE")
        service.answers["/findings/list"] = (403, #"{"__type":"AccessDeniedException","message":"Invoking account does not have access. Amazon Inspector is not enabled"}"#)
        let off = try await callTool(AWS.adapter, "inspector-findings", "{}", on: service, in: aws)
        XCTAssertFalse(off.isError, off.text)
        XCTAssertTrue(off.text.contains("Amazon Inspector is not turned on in account Production (111111111111) in eu-west-1"), off.text)
        service.answers["/findings/list"] = (200, #"{"findings":[{"severity":"CRITICAL","title":"no ARN"}]}"#)
        let noARN = try await callTool(AWS.adapter, "inspector-findings", "{}", on: service, in: aws)
        XCTAssertFalse(noARN.text.contains("No active Inspector findings"), noARN.text)
        XCTAssertTrue(noARN.text.contains("1 findings Inspector returned had no finding ARN"), noARN.text)
        XCTAssertEqual(noARN.structured?["complete"] as? Bool, false)
        service.answers["/findings/list"] = (200, #"{"findings":[],"nextToken":"again"}"#)
        let pagesOnly = try await callTool(AWS.adapter, "inspector-findings", "{}", on: service, in: aws)
        XCTAssertFalse(pagesOnly.text.contains("No active Inspector findings") || pagesOnly.text.contains("More findings matched"), pagesOnly.text)
        XCTAssertTrue(pagesOnly.text.contains("Inspector's listing in account Production (111111111111) in eu-west-1 was not finished after 10 pages"), pagesOnly.text)
        XCTAssertEqual(pagesOnly.structured?["complete"] as? Bool, false)
        service.answers["/findings/list"] = (200, #"{"findings":{}}"#)
        let malformed = try await callTool(AWS.adapter, "inspector-findings", "{}", on: service, in: aws)
        XCTAssertTrue(malformed.isError, malformed.text)

        service.answers["/findings"] = (200, #"{"findingIds":["m1"],"nextToken":"more"}"#)
        service.answers["/findings/describe"] = (200, #"{"findings":[{"id":"m1","accountId":"111111111111","type":"SensitiveData:S3Object/Credentials","severity":{"description":"High"},"updatedAt":"2026-11-20T10:00:00Z","resourcesAffected":{"s3Bucket":{"name":"exports"},"s3Object":{"key":"keys.txt"}},"classificationDetails":{"result":{"sensitiveData":[{"category":"CREDENTIALS","detections":[{"type":"AWS_CREDENTIALS","count":3}]}]}}}]}"#)
        let macie = try await callTool(AWS.adapter, "macie-findings", "{}", on: service, in: aws)
        XCTAssertFalse(macie.isError, macie.text)
        XCTAssertTrue(macie.text.contains("2026-11-20T10:00:00Z High SensitiveData:S3Object/Credentials: exports/keys.txt — AWS_CREDENTIALS ×3"), macie.text)
        XCTAssertTrue(macie.text.contains("More findings matched than the 1 listed"), macie.text)
        let criterion = try XCTUnwrap((try json(service.requests.first { $0.url?.path == "/findings" })["findingCriteria"] as? [String: Any])?["criterion"] as? [String: Any])
        XCTAssertEqual((criterion["archived"] as? [String: [String]])?["eq"], ["false"])
        // A finding listed whose details do not come back is said, never "no findings".
        service.answers["/findings"] = (200, #"{"findingIds":["m1","m2"]}"#)
        let partial = try await callTool(AWS.adapter, "macie-findings", "{}", on: service, in: aws)
        XCTAssertTrue(partial.text.contains("1 of the 2 findings Macie listed came back without their details"), partial.text)
        XCTAssertEqual(partial.structured?["complete"] as? Bool, false)
        XCTAssertEqual(partial.structured?["missingDetails"] as? [String], ["m2"])
        service.answers["/findings/describe"] = (200, #"{"findings":[]}"#)
        let none = try await callTool(AWS.adapter, "macie-findings", "{}", on: service, in: aws)
        XCTAssertFalse(none.text.contains("No sensitive data findings"), none.text)
        XCTAssertTrue(none.text.contains("2 of the 2 findings Macie listed came back without their details"), none.text)
        service.answers["/findings"] = (200, #"{"findingIds":[]}"#)
        let empty = try await callTool(AWS.adapter, "macie-findings", "{}", on: service, in: aws)
        XCTAssertTrue(empty.text.hasPrefix("No sensitive data findings that are not archived"), empty.text)
        XCTAssertEqual(empty.structured?["complete"] as? Bool, true)
        // An empty page with a token is followed; a listing still unfinished at the bound says so, never "none".
        service.answers["/findings/describe"] = (200, #"{"findings":[{"id":"m1","type":"SensitiveData:S3Object/Personal"}]}"#)
        service.sequences["/findings"] = [(200, #"{"findingIds":[],"nextToken":"t"}"#), (200, #"{"findingIds":["m1"]}"#)]
        let followed = try await callTool(AWS.adapter, "macie-findings", "{}", on: service, in: aws)
        XCTAssertTrue(followed.text.contains("SensitiveData:S3Object/Personal"), followed.text)
        XCTAssertEqual(followed.structured?["complete"] as? Bool, true)
        service.answers["/findings"] = (200, #"{"findingIds":[],"nextToken":"t"}"#)
        let before = service.requests.count
        let unfinished = try await callTool(AWS.adapter, "macie-findings", "{}", on: service, in: aws)
        XCTAssertEqual(service.requests.count - before, 5, "five pages, then it stops")
        XCTAssertFalse(unfinished.text.contains("No sensitive data findings"), unfinished.text)
        XCTAssertFalse(unfinished.text.contains("More findings matched"), unfinished.text)
        XCTAssertTrue(unfinished.text.contains("was not finished after 5 pages, none of which held a finding, so whether it has findings is not known"), unfinished.text)
        XCTAssertEqual(unfinished.structured?["complete"] as? Bool, false)
        service.answers["/findings"] = (403, #"{"__type":"AccessDeniedException","message":"Macie is not enabled for this AWS account"}"#)
        let macieOff = try await callTool(AWS.adapter, "macie-findings", "{}", on: service, in: aws)
        XCTAssertTrue(macieOff.text.contains("Amazon Macie is not turned on"), macieOff.text)
    }

    // MARK: check-access

    func testCheckAccessTriesTheDeeperReadsToo() async throws {
        let service = FakeService()
        service.answers["action:GetAccountAuthorizationDetails"] = (200, Self.details())
        service.answers["action:GetCredentialReport"] = (410, "<ErrorResponse><Error><Code>ReportNotPresent</Code><Message>none</Message></Error></ErrorResponse>")
        service.answers["StarlingDoveService.DescribeConfigurationRecorders"] = (200, #"{"ConfigurationRecorders":[]}"#)
        service.answers["?max-buckets=1"] = (403, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>")
        service.answers[Self.sso("ListInstances")] = (400, #"{"__type":"AccessDeniedException","Message":"User is not authorized to perform: sso:ListInstances"}"#)
        service.answers["/findings/list"] = (200, #"{"findings":[]}"#)
        service.answers["/findings"] = (403, #"{"__type":"AccessDeniedException","message":"Macie is not enabled for this AWS account"}"#)
        let check = try await callTool(AWS.adapter, "check-access", "{}", on: service, in: aws)
        XCTAssertFalse(check.isError, check.text)
        for said in ["✓ IAM's authorization details, for iam-access", "✓ The credential report, for credential-report and credential-hygiene",
                     "✓ AWS Config's recorders and history, for config-history", "✗ S3's buckets and Block Public Access, for s3-exposure: the role may not do this: add s3:ListAllMyBuckets",
                     "· IAM Identity Center's assignments: refused here. Only the organisation's management account", "✓ Amazon Inspector's findings.",
                     "· Amazon Macie is off in eu-west-1"] {
            XCTAssertTrue(check.text.contains(said), "\(said):\n\(check.text)")
        }
    }

    func testTheAuditPolicyOnlyReads() throws {
        let policy = try XCTUnwrap(AWS.policy(AWS.compact(AWS.auditPolicy)))
        let actions = AWS.statements(policy).flatMap { AWS.strings($0["Action"]) }
        for needed in ["config:GetResourceConfigHistory", "s3:GetBucketPolicyStatus", "sso:ListAccountAssignments", "identitystore:DescribeUser",
                       "iam:SimulatePrincipalPolicy", "inspector2:ListFindings", "macie2:GetFindings"] {
            XCTAssertTrue(actions.contains(needed), needed)
        }
        let reads = ["List", "Get", "Describe", "Simulate", "StartQuery", "GenerateCredentialReport"]
        for action in actions { XCTAssertTrue(reads.contains { action.split(separator: ":").last!.hasPrefix($0) }, action) }
        XCTAssertTrue(AWS.setup[1].contains("config:GetResourceConfigHistory"))
    }
}
