import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class AWSContainmentTests: XCTestCase {
    private let containment = try! AWS.containment.makeConnection(name: "AWS Containment", values: [
        "startURL": "https://example.awsapps.com/start", "role": "PionContainment", "region": "eu-west-1"])
    private let user = "arn:aws:iam::111111111111:user/mallory"
    private let role = "arn:aws:iam::111111111111:role/deploy"
    private let instance = "i-0abc1234def567890"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await callTool(AWS.containmentAdapter, tool, arguments, on: service, in: containment)
    }

    /// The changes a call sent, as AWS's Query APIs take them: each a POST whose action is in its form.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod == "POST" }.compactMap { formItems($0)["Action"] }
    }

    private func tags(_ pairs: [String: String], list: String) -> String {
        "<\(list)Response><\(list)Result><Tags>" + pairs.map { "<member><Key>\($0.key)</Key><Value>\($0.value)</Value></member>" }.joined() + "</Tags></\(list)Result></\(list)Response>"
    }

    func testContainmentIsItsOwnToolWithItsOwnSignIn() throws {
        XCTAssertEqual(AWS.containment.name, "AWS Containment")
        XCTAssertNotEqual(AWS.containment.id, AWS.preset.id)
        XCTAssertNotNil(UUID(uuidString: AWS.containment.id))
        XCTAssertEqual(AWS.containment.adapter, "aws-containment")
        XCTAssertNotNil(PionAdapters.all["aws-containment"])
        XCTAssertNil(AWS.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == AWS.containment.id })
        XCTAssertEqual(containment.awsIdentityCenter?.role, "PionContainment", "a permission set of its own, with a session of its own")
        XCTAssertEqual(containment.endpoint.absoluteString, "https://amazonaws.com")

        // The permission set's policy is whole JSON, holds every action an operation needs but session revocation, which
        // is a statement of its own, off unless added, and denies everything but reads on Identity Center's roles.
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AWS.containmentPolicy.utf8)) as? [String: Any])
        let statements = try XCTUnwrap(policy["Statement"] as? [[String: Any]])
        let allowed = Set(statements.filter { $0["Effect"] as? String == "Allow" }.flatMap { $0["Action"] as? [String] ?? [] })
        for need in AWS.ContainmentCheckAccess.needs {
            for action in need.actions where !need.optional { XCTAssertTrue(allowed.contains(action), "\(need.operation): \(action)") }
        }
        XCTAssertFalse(allowed.contains("iam:PutRolePolicy"))
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AWS.revocationStatement.utf8)) as? [String: Any])
        XCTAssertEqual(extra["Action"] as? [String], ["iam:PutRolePolicy", "iam:DeleteRolePolicy"])
        let deny = try XCTUnwrap(statements.first { $0["Effect"] as? String == "Deny" })
        XCTAssertEqual(deny["NotAction"] as? [String], ["iam:Get*", "iam:List*", "iam:SimulatePrincipalPolicy"], "check-access may still read its own role")
        let attach = try XCTUnwrap(statements.first { $0["Sid"] as? String == "DenyAllOnly" })
        XCTAssertNotNil(attach["Condition"], "attaching is limited to AWS's deny-all policies")
        XCTAssertTrue(AWS.containmentSetup.contains { $0.contains(AWS.compact(AWS.containmentPolicy)) })
        XCTAssertTrue(AWS.containmentSetup.contains { $0.contains("not the management account") })
    }

    /// What cuts off or restores access, stops an instance, hides a finding or deletes something waits for approval;
    /// ordinary changes run on the bot's call; check-access only reads.
    func testContainmentActionsCutOffAccessOrHideFindingsOnlyWithApproval() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await AWS.containmentAdapter.tools(for: containment)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        func hints(_ name: String) throws -> [String: Any] { try XCTUnwrap(tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any], name) }
        let destructive = ["deactivate-access-key", "reactivate-access-key", "quarantine-principal", "release-principal", "revoke-role-sessions",
                           "remove-session-revocation", "delete-login-profile", "isolate-instance", "unisolate-instance", "detach-instance-profile",
                           "stop-instance", "block-s3-public-access", "archive-guardduty-findings", "close-findings"]
        let ordinary = ["snapshot-volumes", "protect-instance", "restart-logging", "unarchive-guardduty-findings", "guardduty-feedback", "set-finding-workflow"]
        for name in destructive {
            XCTAssertEqual(try hints(name)["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(try hints(name)["destructiveHint"] as? Bool, true, name)
        }
        for name in ordinary {
            XCTAssertEqual(try hints(name)["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(try hints(name)["destructiveHint"] as? Bool, false, name)
        }
        XCTAssertEqual(try hints("check-access")["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(tools.count, destructive.count + ordinary.count + 1)
        // Hiding findings is held; showing them again is not.
        let close = try XCTUnwrap(tools.first { $0["name"] as? String == "close-findings" }?["inputSchema"] as? [String: Any])
        XCTAssertEqual(((close["properties"] as? [String: Any])?["status"] as? [String: Any])?["enum"] as? [String], ["RESOLVED", "SUPPRESSED"])
        let reopen = try XCTUnwrap(tools.first { $0["name"] as? String == "set-finding-workflow" }?["inputSchema"] as? [String: Any])
        XCTAssertEqual(((reopen["properties"] as? [String: Any])?["status"] as? [String: Any])?["enum"] as? [String], ["NEW", "NOTIFIED"])
        let service = FakeService()
        let sneaky = try await call("set-finding-workflow", #"{"findingIds":["arn:x"],"status":"SUPPRESSED"}"#, service)
        XCTAssertTrue(sneaky.isError, "suppressing through the ordinary operation")
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testContainmentRefusesAnythingOutsideTheAccountBeforeRequests() async throws {
        let service = FakeService()
        for (tool, arguments) in [
            ("quarantine-principal", #"{"principal":"arn:aws:iam::999999999999:user/mallory"}"#),
            ("quarantine-principal", #"{"principal":"arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/eu-west-1/AWSReservedSSO_Admin_abc"}"#),
            ("quarantine-principal", #"{"principal":"arn:aws:iam::111111111111:role/aws-service-role/support.amazonaws.com/AWSServiceRoleForSupport"}"#),
            ("quarantine-principal", #"{"principal":"arn:aws:iam::111111111111:role/OrganizationAccountAccessRole"}"#),
            ("quarantine-principal", #"{"principal":"arn:aws:iam::111111111111:user/../root"}"#),
            ("quarantine-principal", #"{"principal":"mallory"}"#),
            ("quarantine-principal", #"{"principal":"arn:aws:iam::111111111111:user/mallory","policy":"AdministratorAccess"}"#),
            ("revoke-role-sessions", #"{"principal":"arn:aws:iam::111111111111:role/AWSReservedSSO_Admin_abc"}"#),
            ("deactivate-access-key", #"{"user":"\#(user)","accessKeyId":"ASIAIOSFODNN7EXAMPLE"}"#),
            ("deactivate-access-key", #"{"user":"arn:aws:iam::222222222222:user/mallory","accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#),
            ("isolate-instance", #"{"instanceId":"i-../../x"}"#),
            ("isolate-instance", #"{"instanceId":"i-0abc","region":"eu-west-1.evil.example"}"#),
            ("block-s3-public-access", #"{"bucket":"evil.example/../x"}"#),
            ("block-s3-public-access", #"{"bucket":"Payroll"}"#),
            ("block-s3-public-access", #"{"bucket":"payroll","wholeAccount":true}"#),
            ("restart-logging", #"{"trail":"arn:aws:cloudtrail:eu-west-1:999999999999:trail/org"}"#),
            ("restart-logging", #"{"trail":"arn:aws:cloudtrail:evil.example:111111111111:trail/org"}"#),
            ("archive-guardduty-findings", #"{"findingIds":["../../detector"]}"#),
            ("close-findings", #"{"findingIds":["a b"],"status":"RESOLVED"}"#),
        ] {
            let refused = try await call(tool, arguments, service)
            XCTAssertTrue(refused.isError, "\(tool) \(arguments)")
            XCTAssertTrue(service.requests.isEmpty, "\(tool) \(arguments) reached AWS: \(service.requests.map { $0.url?.absoluteString ?? "" })")
        }
    }

    // MARK: Keys and principals

    func testDeactivatingAKeyMarksItAsPionsAndOnlyPionsIsUndone() async throws {
        let service = FakeService()
        let keys = { (status: String) in "<ListAccessKeysResponse><ListAccessKeysResult><AccessKeyMetadata><member><AccessKeyId>AKIAIOSFODNN7EXAMPLE</AccessKeyId><Status>\(status)</Status></member></AccessKeyMetadata></ListAccessKeysResult></ListAccessKeysResponse>" }
        service.sequences["action:ListAccessKeys"] = [(200, keys("Active")), (200, keys("Inactive"))]
        service.answers["action:GetAccessKeyLastUsed"] = (200, "<GetAccessKeyLastUsedResponse><GetAccessKeyLastUsedResult><UserName>mallory</UserName><AccessKeyLastUsed><LastUsedDate>2026-11-14T09:01:00Z</LastUsedDate><ServiceName>s3</ServiceName><Region>eu-west-1</Region></AccessKeyLastUsed></GetAccessKeyLastUsedResult></GetAccessKeyLastUsedResponse>")
        service.answers["action:TagUser"] = (200, "<TagUserResponse/>")
        service.answers["action:UpdateAccessKey"] = (200, "<UpdateAccessKeyResponse/>")
        let off = try await call("deactivate-access-key", #"{"user":"\#(user)","accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#, service)
        XCTAssertFalse(off.isError, off.text)
        XCTAssertTrue(off.text.contains("Turned off AKIAIOSFODNN7EXAMPLE of mallory in account Production (111111111111); it was active and it was last used 2026-11-14T09:01:00Z with s3 in eu-west-1."), off.text)
        XCTAssertEqual(changes(service), ["TagUser", "UpdateAccessKey"], "Pion's mark first, then the change, each a POST")
        let update = try XCTUnwrap(service.requests.first { formItems($0)["Action"] == "UpdateAccessKey" })
        XCTAssertEqual(formItems(update)["UserName"], "mallory", "never the caller's own keys")
        XCTAssertEqual(formItems(update)["Status"], "Inactive")
        XCTAssertEqual(update.url?.host, "iam.amazonaws.com")
        XCTAssertEqual(formItems(service.requests.first { formItems($0)["Action"] == "TagUser" })["Tags.member.1.Key"], "pion-deactivated-AKIAIOSFODNN7EXAMPLE")

        // A key that is not the user's is never touched.
        service.requests = []
        service.answers["action:ListAccessKeys"] = (200, "<ListAccessKeysResponse><ListAccessKeysResult><AccessKeyMetadata/></ListAccessKeysResult></ListAccessKeysResponse>")
        let foreign = try await call("deactivate-access-key", #"{"user":"\#(user)","accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#, service)
        XCTAssertTrue(foreign.isError)
        XCTAssertTrue(foreign.text.hasPrefix("Nothing was changed"), foreign.text)
        XCTAssertTrue(changes(service).isEmpty)

        // Reactivating only undoes what carries Pion's mark.
        service.requests = []
        service.answers["action:ListAccessKeys"] = (200, keys("Inactive"))
        service.answers["action:ListUserTags"] = (200, tags(["team": "ops"], list: "ListUserTags"))
        let notPions = try await call("reactivate-access-key", #"{"user":"\#(user)","accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#, service)
        XCTAssertTrue(notPions.isError)
        XCTAssertTrue(notPions.text.contains("carries no tag saying Pion turned AKIAIOSFODNN7EXAMPLE off"), notPions.text)
        XCTAssertTrue(changes(service).isEmpty)
        service.answers["action:ListUserTags"] = (200, tags(["pion-deactivated-AKIAIOSFODNN7EXAMPLE": "2026-11-22T00:00:00Z"], list: "ListUserTags"))
        service.answers["action:UntagUser"] = (200, "<UntagUserResponse/>")
        let back = try await call("reactivate-access-key", #"{"user":"\#(user)","accessKeyId":"AKIAIOSFODNN7EXAMPLE"}"#, service)
        XCTAssertFalse(back.isError, back.text)
        XCTAssertEqual(changes(service), ["UpdateAccessKey", "UntagUser"])
    }

    func testQuarantineTagsFirstReportsPartialChangesAndReleaseRemovesOnlyPions() async throws {
        let service = FakeService()
        let attached = { (arns: [String]) in "<ListAttachedRolePoliciesResponse><ListAttachedRolePoliciesResult><AttachedPolicies>" + arns.map { "<member><PolicyArn>\($0)</PolicyArn></member>" }.joined() + "</AttachedPolicies></ListAttachedRolePoliciesResult></ListAttachedRolePoliciesResponse>" }
        service.sequences["action:ListAttachedRolePolicies"] = [(200, attached([])), (200, attached(["arn:aws:iam::aws:policy/AWSDenyAll"]))]
        service.answers["action:ListRoleTags"] = (200, tags([:], list: "ListRoleTags"))
        service.answers["action:TagRole"] = (200, "<TagRoleResponse/>")
        service.answers["action:AttachRolePolicy"] = (200, "<AttachRolePolicyResponse/>")
        let quarantined = try await call("quarantine-principal", #"{"principal":"\#(role)"}"#, service)
        XCTAssertFalse(quarantined.isError, quarantined.text)
        XCTAssertEqual(changes(service), ["TagRole", "AttachRolePolicy"])
        let attach = try XCTUnwrap(service.requests.first { formItems($0)["Action"] == "AttachRolePolicy" })
        XCTAssertEqual(formItems(attach)["PolicyArn"], "arn:aws:iam::aws:policy/AWSDenyAll")
        XCTAssertEqual(formItems(attach)["RoleName"], "deploy")
        XCTAssertTrue(quarantined.text.contains("Quarantined role deploy in account Production (111111111111)"), quarantined.text)

        // A deny-all policy someone else attached is said, not claimed; release leaves it.
        service.requests = []
        service.answers["action:ListAttachedRolePolicies"] = (200, attached(["arn:aws:iam::aws:policy/AWSDenyAll"]))
        let already = try await call("quarantine-principal", #"{"principal":"\#(role)"}"#, service)
        XCTAssertTrue(already.text.contains("already has arn:aws:iam::aws:policy/AWSDenyAll attached, not by Pion"), already.text)
        let release = try await call("release-principal", #"{"principal":"\#(role)"}"#, service)
        XCTAssertTrue(release.isError)
        XCTAssertTrue(release.text.contains("carries no pion-quarantine tag"), release.text)
        XCTAssertTrue(changes(service).isEmpty)

        // Attaching fails: Pion's mark comes off again and nothing is said to have changed.
        service.requests = []
        service.answers["action:ListAttachedRolePolicies"] = (200, attached([]))
        service.answers["action:AttachRolePolicy"] = (403, "<ErrorResponse><Error><Code>AccessDenied</Code><Message>not authorized to perform iam:AttachRolePolicy</Message></Error></ErrorResponse>")
        service.answers["action:UntagRole"] = (200, "<UntagRoleResponse/>")
        let failed = try await call("quarantine-principal", #"{"principal":"\#(role)","policy":"compromised-key"}"#, service)
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.hasPrefix("Nothing was changed: attaching arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3 failed"), failed.text)
        XCTAssertEqual(changes(service), ["TagRole", "AttachRolePolicy", "UntagRole"])
        service.requests = []
        service.answers["action:UntagRole"] = (500, "")
        let partly = try await call("quarantine-principal", #"{"principal":"\#(role)"}"#, service)
        XCTAssertTrue(partly.text.hasPrefix("Only partly done: tagged role deploy pion-quarantine; then attaching"), partly.text)

        // Release removes only what Pion's tag names.
        service.requests = []
        service.answers["action:UntagRole"] = (200, "<UntagRoleResponse/>")
        service.answers["action:ListRoleTags"] = (200, tags(["pion-quarantine": "arn:aws:iam::aws:policy/AWSDenyAll 2026-11-22T00:00:00Z"], list: "ListRoleTags"))
        service.answers["action:ListAttachedRolePolicies"] = (200, attached(["arn:aws:iam::aws:policy/AWSDenyAll", "arn:aws:iam::aws:policy/ReadOnlyAccess"]))
        service.answers["action:DetachRolePolicy"] = (200, "<DetachRolePolicyResponse/>")
        let released = try await call("release-principal", #"{"principal":"\#(role)"}"#, service)
        XCTAssertFalse(released.isError, released.text)
        XCTAssertEqual(changes(service), ["DetachRolePolicy", "UntagRole"])
        XCTAssertEqual(formItems(service.requests.first { formItems($0)["Action"] == "DetachRolePolicy" })["PolicyArn"], "arn:aws:iam::aws:policy/AWSDenyAll")
    }

    func testRevokingSessionsWritesOnlyPionsPolicyAndRemovesOnlyThat() async throws {
        let service = FakeService()
        service.answers["action:GetRolePolicy"] = (404, "<ErrorResponse><Error><Code>NoSuchEntity</Code></Error></ErrorResponse>")
        service.answers["action:PutRolePolicy"] = (200, "<PutRolePolicyResponse/>")
        let revoked = try await call("revoke-role-sessions", #"{"principal":"\#(role)"}"#, service)
        XCTAssertFalse(revoked.isError, revoked.text)
        let put = try XCTUnwrap(service.requests.first { formItems($0)["Action"] == "PutRolePolicy" })
        XCTAssertEqual(formItems(put)["PolicyName"], "PionRevokeOlderSessions")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((formItems(put)["PolicyDocument"] ?? "").utf8)) as? [String: Any])
        let statement = try XCTUnwrap((document["Statement"] as? [[String: Any]])?.first)
        XCTAssertEqual(statement["Effect"] as? String, "Deny")
        XCTAssertNotNil(((statement["Condition"] as? [String: Any])?["DateLessThan"] as? [String: String])?["aws:TokenIssueTime"])
        XCTAssertTrue(revoked.text.contains("IAM has no write condition"), revoked.text)

        let theirs = #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:*","Resource":"*"}]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        service.answers["action:GetRolePolicy"] = (200, "<GetRolePolicyResponse><GetRolePolicyResult><PolicyDocument>\(theirs)</PolicyDocument></GetRolePolicyResult></GetRolePolicyResponse>")
        service.requests = []
        for tool in ["revoke-role-sessions", "remove-session-revocation"] {
            let refused = try await call(tool, #"{"principal":"\#(role)"}"#, service)
            XCTAssertTrue(refused.isError, tool)
            XCTAssertTrue(refused.text.contains("Pion did not write") || refused.text.contains("not the one Pion writes"), refused.text)
        }
        XCTAssertTrue(changes(service).isEmpty)
        let pions = AWS.revocation("2026-11-22T00:00:00Z").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        service.answers["action:GetRolePolicy"] = (200, "<GetRolePolicyResponse><GetRolePolicyResult><PolicyDocument>\(pions)</PolicyDocument></GetRolePolicyResult></GetRolePolicyResponse>")
        service.answers["action:DeleteRolePolicy"] = (200, "<DeleteRolePolicyResponse/>")
        let removed = try await call("remove-session-revocation", #"{"principal":"\#(role)"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(changes(service), ["DeleteRolePolicy"])
    }

    // MARK: Instances

    private func describe(groups: [String: [String]], owner: String = "111111111111") -> String {
        let interfaces = groups.sorted { $0.key < $1.key }.map { id, list in
            "<item><networkInterfaceId>\(id)</networkInterfaceId><groupSet>" + list.map { "<item><groupId>\($0)</groupId></item>" }.joined() + "</groupSet></item>"
        }.joined()
        return "<DescribeInstancesResponse><reservationSet><item><ownerId>\(owner)</ownerId><instancesSet><item><instanceId>\(instance)</instanceId><vpcId>vpc-1</vpcId><instanceState><name>running</name></instanceState><networkInterfaceSet>\(interfaces)</networkInterfaceSet></item></instancesSet></item></reservationSet></DescribeInstancesResponse>"
    }

    private func interfaces(_ groups: [String: [String]], tags: [String: String] = [:]) -> String {
        "<DescribeNetworkInterfacesResponse><networkInterfaceSet>" + groups.sorted { $0.key < $1.key }.map { id, list in
            "<item><networkInterfaceId>\(id)</networkInterfaceId><groupSet>" + list.map { "<item><groupId>\($0)</groupId></item>" }.joined() + "</groupSet><tagSet>"
                + tags.map { "<item><key>\($0.key)</key><value>\($0.value)</value></item>" }.joined() + "</tagSet></item>"
        }.joined() + "</networkInterfaceSet></DescribeNetworkInterfacesResponse>"
    }

    private func group(_ id: String, pions: Bool, egress: Bool = false, vpc: String = "vpc-1") -> String {
        "<DescribeSecurityGroupsResponse><securityGroupInfo><item><groupId>\(id)</groupId><ownerId>111111111111</ownerId><vpcId>\(vpc)</vpcId><groupName>pion-isolate-\(instance)</groupName><ipPermissions/><ipPermissionsEgress>"
            + (egress ? "<item><ipProtocol>-1</ipProtocol><ipRanges><item><cidrIp>0.0.0.0/0</cidrIp></item></ipRanges></item><item><ipProtocol>-1</ipProtocol><ipv6Ranges><item><cidrIpv6>::/0</cidrIpv6></item></ipv6Ranges></item>" : "")
            + "</ipPermissionsEgress><tagSet>" + (pions ? "<item><key>pion-isolation</key><value>\(instance)</value></item>" : "") + "</tagSet></item></securityGroupInfo></DescribeSecurityGroupsResponse>"
    }

    func testIsolationMovesEachInterfaceIntoPionsOwnGroupAndRecordsItsGroups() async throws {
        let service = FakeService()
        let before = ["eni-0aaa1111": ["sg-0a1b2c3d", "sg-0e5f6a7b"], "eni-0bbb2222": ["sg-0a1b2c3d"]]
        service.answers["action:DescribeInstances"] = (200, describe(groups: before))
        service.sequences["action:DescribeNetworkInterfaces"] = [(200, interfaces(before)), (200, interfaces(before.mapValues { _ in ["sg-0f00ba12"] }))]
        service.sequences["action:DescribeSecurityGroups"] = [(200, "<DescribeSecurityGroupsResponse><securityGroupInfo/></DescribeSecurityGroupsResponse>"),
                                                              (200, group("sg-0f00ba12", pions: true, egress: true)), (200, group("sg-0f00ba12", pions: true))]
        service.answers["action:CreateSecurityGroup"] = (200, "<CreateSecurityGroupResponse><groupId>sg-0f00ba12</groupId></CreateSecurityGroupResponse>")
        for action in ["RevokeSecurityGroupEgress", "CreateTags", "ModifyNetworkInterfaceAttribute"] { service.answers["action:" + action] = (200, "<Response><return>true</return></Response>") }
        let isolated = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertFalse(isolated.isError, isolated.text)
        XCTAssertEqual(changes(service), ["CreateSecurityGroup", "RevokeSecurityGroupEgress", "RevokeSecurityGroupEgress", "CreateTags", "ModifyNetworkInterfaceAttribute",
                                          "CreateTags", "ModifyNetworkInterfaceAttribute"])
        let made = try XCTUnwrap(service.requests.first { formItems($0)["Action"] == "CreateSecurityGroup" })
        XCTAssertEqual(formItems(made)["GroupName"], "pion-isolate-\(instance)")
        XCTAssertEqual(formItems(made)["TagSpecification.1.Tag.1.Key"], "pion-isolation")
        XCTAssertEqual(formItems(made)["TagSpecification.1.Tag.1.Value"], instance)
        XCTAssertEqual(service.requests.filter { formItems($0)["Action"] == "RevokeSecurityGroupEgress" }.map { formItems($0)["IpPermissions.1.IpRanges.1.CidrIp"] ?? formItems($0)["IpPermissions.1.Ipv6Ranges.1.CidrIpv6"] }, ["0.0.0.0/0", "::/0"])
        let record = try XCTUnwrap(service.requests.first { formItems($0)["Action"] == "CreateTags" })
        XCTAssertEqual(formItems(record)["Tag.1.Key"], "pion-previous-groups")
        XCTAssertEqual(formItems(record)["Tag.1.Value"], "sg-0a1b2c3d,sg-0e5f6a7b")
        XCTAssertTrue(isolated.text.contains("moved eni-0aaa1111 from sg-0a1b2c3d,sg-0e5f6a7b into sg-0f00ba12"), isolated.text)
        XCTAssertTrue(isolated.text.contains("Connections already open may continue"), isolated.text)
        XCTAssertEqual((isolated.structured?["previousGroups"] as? [String: [String]])?["eni-0bbb2222"], ["sg-0a1b2c3d"])
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "ec2.eu-west-1.amazonaws.com" })

        // A group of that name Pion did not make is never used.
        service.requests = []
        service.sequences["action:DescribeNetworkInterfaces"] = [(200, interfaces(before))]
        service.sequences["action:DescribeSecurityGroups"] = [(200, group("sg-0bad0bad", pions: false))]
        let collision = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(collision.isError)
        XCTAssertTrue(collision.text.contains("that Pion did not make"), collision.text)
        XCTAssertTrue(changes(service).isEmpty)

        // An instance of another account is never touched.
        service.requests = []
        service.answers["action:DescribeInstances"] = (200, describe(groups: before, owner: "999999999999"))
        let foreign = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(foreign.text.contains("belongs to account 999999999999"), foreign.text)
        XCTAssertTrue(changes(service).isEmpty)

        // A move that fails part way says exactly what was done and how to undo it.
        service.requests = []
        service.answers["action:DescribeInstances"] = (200, describe(groups: before))
        service.sequences["action:DescribeNetworkInterfaces"] = [(200, interfaces(before))]
        service.sequences["action:DescribeSecurityGroups"] = [(200, group("sg-0f00ba12", pions: true))]
        service.sequences["action:ModifyNetworkInterfaceAttribute"] = [(200, "<Response><return>true</return></Response>"), (400, "<Response><Errors><Error><Code>InvalidParameterValue</Code><Message>bad</Message></Error></Errors></Response>")]
        let partly = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(partly.isError)
        XCTAssertTrue(partly.text.hasPrefix("Only partly done: recorded eni-0aaa1111's groups sg-0a1b2c3d,sg-0e5f6a7b in its pion-previous-groups tag; moved eni-0aaa1111 from sg-0a1b2c3d,sg-0e5f6a7b into sg-0f00ba12; recorded eni-0bbb2222's groups sg-0a1b2c3d in its pion-previous-groups tag; then moving eni-0bbb2222 failed"), partly.text)
        XCTAssertTrue(partly.text.contains("unisolate-instance"), partly.text)

        // Tried again, the interface moved stays, and the one whose record was written moves without writing another.
        service.requests = []
        let halfway = ["eni-0aaa1111": ["sg-0f00ba12"], "eni-0bbb2222": ["sg-0a1b2c3d"]]
        service.answers["action:DescribeInstances"] = (200, describe(groups: halfway))
        service.sequences["action:DescribeNetworkInterfaces"] = [(200, interfaces(halfway, tags: ["pion-previous-groups": "sg-0a1b2c3d"]))]
        service.sequences["action:DescribeSecurityGroups"] = [(200, group("sg-0f00ba12", pions: true))]
        service.sequences["action:ModifyNetworkInterfaceAttribute"] = [(200, "<Response><return>true</return></Response>")]
        let retried = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertFalse(retried.isError, retried.text)
        XCTAssertEqual(changes(service), ["ModifyNetworkInterfaceAttribute"])
        XCTAssertEqual(formItems(service.requests.first { formItems($0)["Action"] == "ModifyNetworkInterfaceAttribute" })["NetworkInterfaceId"], "eni-0bbb2222")
    }

    /// Nothing is changed unless every interface, its groups, and every rule of Pion's group can be read, and every
    /// interface has a record of its groups that can be put back; a record that says otherwise is kept, not replaced.
    func testIsolationChangesNothingWithoutEveryPieceOfEvidence() async throws {
        let before = ["eni-0aaa1111": ["sg-0a1b2c3d"], "eni-0bbb2222": ["sg-0e5f6a7b"]]
        let empty = "<DescribeSecurityGroupsResponse><securityGroupInfo/></DescribeSecurityGroupsResponse>"
        let unnamed = describe(groups: before).replacingOccurrences(of: "<networkInterfaceId>eni-0bbb2222</networkInterfaceId>", with: "")
        for (case_, instanceAnswer, interfacesAnswer, groupAnswer, said) in [
            ("an interface without its ID", unnamed, interfaces(before), empty, "without a valid ID"),
            ("an interface EC2 does not describe", describe(groups: before), interfaces(["eni-0aaa1111": ["sg-0a1b2c3d"]]), empty, "did not describe eni-0bbb2222"),
            ("an interface without groups", describe(groups: before), interfaces(["eni-0aaa1111": ["sg-0a1b2c3d"], "eni-0bbb2222": []]), empty, "without a valid list of its security groups"),
            ("Pion's group without its rules listed", describe(groups: before), interfaces(before),
             group("sg-0f00ba12", pions: true).replacingOccurrences(of: "<ipPermissions/>", with: ""), "did not list all of sg-0f00ba12's rules"),
            ("Pion's name on a group in another VPC's listing", describe(groups: before), interfaces(before), group("sg-0f00ba12", pions: true, vpc: "vpc-9"), "that Pion did not make"),
            ("a record that differs", describe(groups: before), interfaces(before, tags: ["pion-previous-groups": "sg-0c0ffee0"]), empty, "already has a pion-previous-groups record, sg-0c0ffee0"),
        ] {
            let service = FakeService()
            service.answers["action:DescribeInstances"] = (200, instanceAnswer)
            service.answers["action:DescribeNetworkInterfaces"] = (200, interfacesAnswer)
            service.answers["action:DescribeSecurityGroups"] = (200, groupAnswer)
            let refused = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
            XCTAssertTrue(refused.isError, case_)
            XCTAssertTrue(refused.text.hasPrefix("Nothing was changed") && refused.text.contains(said), "\(case_): \(refused.text)")
            XCTAssertTrue(changes(service).isEmpty, case_)
        }

        // The group EC2 made is read back as Pion's, in the account and VPC, before any interface moves.
        let service = FakeService()
        service.answers["action:DescribeInstances"] = (200, describe(groups: before))
        service.answers["action:DescribeNetworkInterfaces"] = (200, interfaces(before))
        service.sequences["action:DescribeSecurityGroups"] = [(200, empty), (200, group("sg-0f00ba12", pions: true, vpc: "vpc-9"))]
        service.answers["action:CreateSecurityGroup"] = (200, "<CreateSecurityGroupResponse><groupId>sg-0f00ba12</groupId></CreateSecurityGroupResponse>")
        let strange = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(strange.text.hasPrefix("Only partly done: made security group sg-0f00ba12; then readying the new group failed"), strange.text)
        XCTAssertTrue(strange.text.contains("does not read back as Pion's isolation group") && strange.text.contains("no interface was moved"), strange.text)
        XCTAssertEqual(changes(service), ["CreateSecurityGroup"])

        // A record written before a move failed says so, and trying again moves it without writing another.
        let tagged = FakeService()
        tagged.answers["action:DescribeInstances"] = (200, describe(groups: ["eni-0aaa1111": ["sg-0a1b2c3d"]]))
        tagged.sequences["action:DescribeNetworkInterfaces"] = [(200, interfaces(["eni-0aaa1111": ["sg-0a1b2c3d"]])),
                                                                (200, interfaces(["eni-0aaa1111": ["sg-0a1b2c3d"]], tags: ["pion-previous-groups": "sg-0a1b2c3d"])),
                                                                (200, interfaces(["eni-0aaa1111": ["sg-0f00ba12"]], tags: ["pion-previous-groups": "sg-0a1b2c3d"]))]
        tagged.answers["action:DescribeSecurityGroups"] = (200, group("sg-0f00ba12", pions: true))
        tagged.answers["action:CreateTags"] = (200, "<Response><return>true</return></Response>")
        tagged.sequences["action:ModifyNetworkInterfaceAttribute"] = [(400, "<Response><Errors><Error><Code>InvalidGroup.NotFound</Code><Message>gone</Message></Error></Errors></Response>"),
                                                                      (200, "<Response><return>true</return></Response>")]
        let failed = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, tagged)
        XCTAssertTrue(failed.text.hasPrefix("Only partly done: recorded eni-0aaa1111's groups sg-0a1b2c3d in its pion-previous-groups tag; then moving eni-0aaa1111 failed"), failed.text)
        XCTAssertTrue(failed.text.contains("its record stays"), failed.text)
        tagged.requests = []
        let again = try await call("isolate-instance", #"{"instanceId":"\#(instance)"}"#, tagged)
        XCTAssertFalse(again.isError, again.text)
        XCTAssertEqual(changes(tagged), ["ModifyNetworkInterfaceAttribute"], "the record already there is used, never written over")
    }

    func testUnisolationPutsBackOnlyInterfacesStillInPionsGroup() async throws {
        let service = FakeService()
        service.answers["action:DescribeInstances"] = (200, describe(groups: ["eni-0aaa1111": ["sg-0f00ba12"], "eni-0bbb2222": ["sg-0f00ba12", "sg-0c0ffee0"]]))
        service.answers["action:DescribeSecurityGroups"] = (200, group("sg-0f00ba12", pions: true))
        service.answers["action:DescribeNetworkInterfaces"] = (200, interfaces(["eni-0aaa1111": ["sg-0f00ba12"], "eni-0bbb2222": ["sg-0f00ba12", "sg-0c0ffee0"]],
                                                                               tags: ["pion-previous-groups": "sg-0a1b2c3d,sg-0e5f6a7b"]))
        service.answers["action:ModifyNetworkInterfaceAttribute"] = (200, "<Response><return>true</return></Response>")
        service.answers["action:DeleteTags"] = (200, "<Response><return>true</return></Response>")
        let back = try await call("unisolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertFalse(back.isError, back.text)
        XCTAssertEqual(changes(service), ["ModifyNetworkInterfaceAttribute", "DeleteTags"])
        let modify = try XCTUnwrap(service.requests.first { formItems($0)["Action"] == "ModifyNetworkInterfaceAttribute" })
        XCTAssertEqual(formItems(modify)["NetworkInterfaceId"], "eni-0aaa1111")
        XCTAssertEqual([formItems(modify)["SecurityGroupId.1"], formItems(modify)["SecurityGroupId.2"]], ["sg-0a1b2c3d", "sg-0e5f6a7b"])
        XCTAssertEqual(formItems(service.requests.first { formItems($0)["Action"] == "DeleteTags" })["Tag.1.Value"], "sg-0a1b2c3d,sg-0e5f6a7b", "removed only while it says what was put back")
        XCTAssertTrue(back.text.contains("Left as it is: eni-0bbb2222, which is in other groups too"), back.text)

        // A record that cannot be removed is said, and removed when tried again, once the interface is back.
        service.requests = []
        service.answers["action:DescribeInstances"] = (200, describe(groups: ["eni-0aaa1111": ["sg-0f00ba12"]]))
        service.answers["action:DescribeNetworkInterfaces"] = (200, interfaces(["eni-0aaa1111": ["sg-0f00ba12"]], tags: ["pion-previous-groups": "sg-0a1b2c3d"]))
        service.answers["action:DeleteTags"] = (403, "<Response><Errors><Error><Code>UnauthorizedOperation</Code><Message>You are not authorized to perform this operation.</Message></Error></Errors></Response>")
        let stuck = try await call("unisolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(stuck.text.contains("Put back i-0abc1234def567890") && stuck.text.contains("Could not remove eni-0aaa1111's pion-previous-groups tag"), stuck.text)
        XCTAssertTrue(stuck.text.contains("add ec2:DeleteTags"), stuck.text)
        XCTAssertEqual(stuck.structured?["remainingRecords"] as? [String], ["eni-0aaa1111's pion-previous-groups tag (the role may not do this: add ec2:DeleteTags to the permission set in IAM Identity Center, then re-provision it to the account.)"])
        service.requests = []
        service.answers["action:DescribeInstances"] = (200, describe(groups: ["eni-0aaa1111": ["sg-0a1b2c3d"]]))
        service.answers["action:DescribeNetworkInterfaces"] = (200, interfaces(["eni-0aaa1111": ["sg-0a1b2c3d"]], tags: ["pion-previous-groups": "sg-0a1b2c3d"]))
        service.answers["action:DeleteTags"] = (200, "<Response><return>true</return></Response>")
        let cleaned = try await call("unisolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(cleaned.text.contains("Removed the leftover records of eni-0aaa1111"), cleaned.text)
        XCTAssertEqual(changes(service), ["DeleteTags"])

        // A record that is not a list of groups is never applied.
        service.requests = []
        service.answers["action:DescribeNetworkInterfaces"] = (200, interfaces(["eni-0aaa1111": ["sg-0f00ba12"]], tags: ["pion-previous-groups": "sg-0a1b2c3d,arn:evil"]))
        let forged = try await call("unisolate-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(forged.text.contains("whose record is not a list of groups"), forged.text)
        XCTAssertTrue(changes(service).isEmpty)
    }

    func testInstanceActionsSendTheirRequests() async throws {
        let service = FakeService()
        service.answers["action:DescribeInstances"] = (200, describe(groups: ["eni-0aaa1111": ["sg-0a1b2c3d"]]))
        service.answers["action:DescribeIamInstanceProfileAssociations"] = (200, "<Response><iamInstanceProfileAssociationSet><item><associationId>iip-assoc-0abc</associationId><instanceId>\(instance)</instanceId><state>associated</state><iamInstanceProfile><arn>arn:aws:iam::111111111111:instance-profile/web</arn></iamInstanceProfile></item></iamInstanceProfileAssociationSet></Response>")
        service.answers["action:DisassociateIamInstanceProfile"] = (200, "<Response/>")
        let detached = try await call("detach-instance-profile", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(detached.text.contains("Removed instance profile arn:aws:iam::111111111111:instance-profile/web"), detached.text)
        XCTAssertEqual(formItems(service.requests.last)["AssociationId"], "iip-assoc-0abc")
        service.answers["action:StopInstances"] = (200, "<StopInstancesResponse><instancesSet><item><currentState><name>stopping</name></currentState></item></instancesSet></StopInstancesResponse>")
        let stopped = try await call("stop-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertTrue(stopped.text.contains("it was running and is now stopping"), stopped.text)
        service.answers["action:CreateSnapshots"] = (200, "<CreateSnapshotsResponse><snapshotSet><item><snapshotId>snap-01</snapshotId><volumeId>vol-01</volumeId></item></snapshotSet></CreateSnapshotsResponse>")
        let snapshots = try await call("snapshot-volumes", #"{"instanceId":"\#(instance)","notes":"case 42"}"#, service)
        XCTAssertTrue(snapshots.text.contains("snap-01 of vol-01"), snapshots.text)
        XCTAssertEqual(formItems(service.requests.last)["TagSpecification.1.Tag.1.Key"], "pion-evidence")
        service.answers["action:ModifyInstanceAttribute"] = (200, "<Response><return>true</return></Response>")
        _ = try await call("protect-instance", #"{"instanceId":"\#(instance)"}"#, service)
        XCTAssertEqual(formItems(service.requests.last)["DisableApiTermination.Value"], "true")
        XCTAssertEqual(changes(service), ["DisassociateIamInstanceProfile", "StopInstances", "CreateSnapshots", "ModifyInstanceAttribute"])
        XCTAssertTrue(service.requests.filter { $0.httpMethod == "GET" }.allSatisfy { ["DescribeInstances", "DescribeIamInstanceProfileAssociations"].contains(queryItems($0)["Action"]) },
                      "every change is a POST, which is never sent twice")
    }

    // MARK: S3, logging and findings

    func testBlockingPublicAccessSaysWhatItWasAndOnlyTouchesTheAccountsOwnBucket() async throws {
        let service = FakeService()
        service.sequences["/payroll?publicAccessBlock="] = [(200, "<PublicAccessBlockConfiguration><BlockPublicAcls>true</BlockPublicAcls><IgnorePublicAcls>false</IgnorePublicAcls><BlockPublicPolicy>false</BlockPublicPolicy><RestrictPublicBuckets>false</RestrictPublicBuckets></PublicAccessBlockConfiguration>"),
                                                            (200, "")]
        let blocked = try await call("block-s3-public-access", #"{"bucket":"payroll"}"#, service)
        XCTAssertFalse(blocked.isError, blocked.text)
        XCTAssertTrue(blocked.text.contains("before, BlockPublicAcls true, IgnorePublicAcls false, BlockPublicPolicy false, RestrictPublicBuckets false"), blocked.text)
        XCTAssertEqual(service.requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "s3.eu-west-1.amazonaws.com" && $0.url?.path == "/payroll" }, "the bucket only ever in the path")
        XCTAssertTrue(service.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-amz-expected-bucket-owner") == "111111111111" })
        let put = try XCTUnwrap(service.requests.last)
        let body = String(data: put.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertEqual(body.components(separatedBy: ">true<").count - 1, 4)
        XCTAssertNotNil(put.value(forHTTPHeaderField: "Content-MD5"))

        // A bucket in another region is said, with its region, and nothing is changed.
        service.requests = []
        service.responseHeaders = ["x-amz-bucket-region": "us-west-2"]
        service.answers["/elsewhere?publicAccessBlock="] = (301, "<Error><Code>PermanentRedirect</Code></Error>")
        let moved = try await call("block-s3-public-access", #"{"bucket":"elsewhere"}"#, service)
        XCTAssertTrue(moved.text.contains("give region us-west-2"), moved.text)
        XCTAssertEqual(service.requests.count, 1)
        service.responseHeaders = [:]

        // The whole account, through S3 Control at the account's own name.
        service.requests = []
        service.sequences["/v20180820/configuration/publicAccessBlock"] = [(404, "<Error><Code>NoSuchPublicAccessBlockConfiguration</Code></Error>"), (200, "")]
        let account = try await call("block-s3-public-access", #"{"wholeAccount":true}"#, service)
        XCTAssertFalse(account.isError, account.text)
        XCTAssertTrue(account.text.contains("before, none of the settings was on"), account.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "111111111111.s3-control.eu-west-1.amazonaws.com" && $0.value(forHTTPHeaderField: "x-amz-account-id") == "111111111111" })
    }

    func testFindingsAreCheckedBeforeTheyAreArchivedOrClosed() async throws {
        let service = FakeService()
        let id = String(repeating: "a", count: 32)
        service.answers["/detector"] = (200, #"{"detectorIds":["d1"]}"#)
        service.answers["/detector/d1/findings/get"] = (200, #"{"findings":[{"id":"\#(id)","type":"Recon:EC2/PortProbeUnprotectedPort","accountId":"333333333333","severity":2}]}"#)
        service.answers["/detector/d1/findings/archive"] = (200, "{}")
        let archived = try await call("archive-guardduty-findings", #"{"findingIds":["\#(id)"]}"#, service)
        XCTAssertFalse(archived.isError, archived.text)
        XCTAssertTrue(archived.text.contains("(Recon:EC2/PortProbeUnprotectedPort, of account 333333333333)"), archived.text)
        XCTAssertEqual(service.requests.map { $0.url?.path }, ["/detector", "/detector/d1/findings/get", "/detector/d1/findings/archive"])
        let missing = try await call("archive-guardduty-findings", #"{"findingIds":["\#(String(repeating: "b", count: 32))"]}"#, service)
        XCTAssertTrue(missing.text.hasPrefix("Nothing was changed"), missing.text)
        XCTAssertFalse(service.requests.dropFirst(3).contains { $0.url?.path.hasSuffix("/archive") == true })

        service.answers["/findings"] = (200, #"{"Findings":[{"Id":"arn:f1","ProductArn":"arn:aws:securityhub:eu-west-1::product/aws/securityhub","AwsAccountId":"111111111111"},{"Id":"arn:f2","ProductArn":"arn:p","AwsAccountId":"111111111111"}]}"#)
        service.answers["/findings/batchupdate"] = (200, #"{"ProcessedFindings":[{"Id":"arn:f1"}],"UnprocessedFindings":[{"FindingIdentifier":{"Id":"arn:f2"},"ErrorMessage":"Finding not found"}]}"#)
        let closed = try await call("close-findings", #"{"findingIds":["arn:f1","arn:f2"],"status":"SUPPRESSED","note":"benign scanner"}"#, service)
        XCTAssertTrue(closed.text.contains("Set 1 Security Hub finding in account Production (111111111111) in eu-west-1 to SUPPRESSED. Not changed: arn:f2 (Finding not found)."), closed.text)
        let update = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(update.httpMethod, "PATCH")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: update.httpBody!) as? [String: Any])
        XCTAssertEqual((body["Workflow"] as? [String: String])?["Status"], "SUPPRESSED")
        XCTAssertEqual((body["FindingIdentifiers"] as? [[String: String]])?.map { $0["ProductArn"] }, ["arn:aws:securityhub:eu-west-1::product/aws/securityhub", "arn:p"])
    }

    func testRestartLoggingStartsOnlyTheAccountsOwnTrail() async throws {
        let service = FakeService()
        service.answers["com.amazonaws.cloudtrail.v20131101.CloudTrail_20131101.StartLogging"] = (200, "{}")
        service.answers["com.amazonaws.cloudtrail.v20131101.CloudTrail_20131101.GetTrailStatus"] = (200, #"{"IsLogging":true}"#)
        let started = try await call("restart-logging", #"{"trail":"arn:aws:cloudtrail:us-east-1:111111111111:trail/org-trail"}"#, service)
        XCTAssertTrue(started.text.contains("Started org-trail in account Production (111111111111) in us-east-1; it is logging"), started.text)
        XCTAssertEqual(service.requests.first?.url?.host, "cloudtrail.us-east-1.amazonaws.com")
    }

    // MARK: Checking access

    func testCheckAccessSimulatesEachOperationAndWarnsWhenItAllowsFarMore() async throws {
        let service = FakeService()
        service.answers["action:GetCallerIdentity"] = (200, "<R><GetCallerIdentityResult><Arn>arn:aws:sts::111111111111:assumed-role/AWSReservedSSO_PionContainment_abc/pdp</Arn></GetCallerIdentityResult></R>")
        service.answers["action:GetRole"] = (200, "<R><GetRoleResult><Role><Arn>arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_PionContainment_abc</Arn></Role></GetRoleResult></R>")
        final class Simulator: ServiceAccess, @unchecked Sendable {
            let inner: FakeService
            init(_ inner: FakeService) { self.inner = inner }
            func awsAccounts() async throws -> [AWSAccount] { try await inner.awsAccounts() }
            func access(asAWSAccount id: String) async throws -> any ServiceAccess { self }
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let query = queryItems(request)
                guard query["Action"] == "SimulatePrincipalPolicy" else { return try await inner.data(for: request) }
                _ = try await inner.data(for: request)
                // Allowed: everything the policy gives but the optional revocation and stopping instances; and far
                // more, as a role given AdministratorAccess would.
                let actions = query.filter { $0.key.hasPrefix("ActionNames.member.") }.map(\.value)
                let members = actions.map { action -> String in
                    let allowed = !["iam:PutRolePolicy", "iam:DeleteRolePolicy", "ec2:StopInstances"].contains(action)
                        && (!action.hasPrefix("iam:Attach") || query["ContextEntries.member.1.ContextKeyValues.member.1"]?.hasSuffix("AWSDenyAll") == true)
                        && (!AWS.ContainmentCheckAccess.far.contains(action) || action == "s3:DeleteBucket")
                    return "<member><EvalActionName>\(action)</EvalActionName><EvalDecision>\(allowed ? "allowed" : "implicitDeny")</EvalDecision></member>"
                }.joined()
                return (Data("<R><SimulatePrincipalPolicyResult><EvaluationResults>\(members)</EvaluationResults></SimulatePrincipalPolicyResult></R>".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
        }
        let check = try await callTool(AWS.containmentAdapter, "check-access", "{}", on: FakeService(), in: containment)
        XCTAssertTrue(check.text.contains("Who the role is could not be read"), check.text)
        let data = try await AWS.containmentAdapter.run("check-access", arguments: Data("{}".utf8), connection: containment, access: Simulator(service))
        let text = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        for said in ["✓ deactivate-access-key and reactivate-access-key", "✓ quarantine-principal and release-principal, for roles",
                     "· revoke-role-sessions and remove-session-revocation: off, as the permission set lacks iam:PutRolePolicy, iam:DeleteRolePolicy",
                     "✗ stop-instance: add ec2:StopInstances", "⚠ The permission set allows far more than containment: s3:DeleteBucket",
                     "· What it can do is simulated from its own policies, not tried"] {
            XCTAssertTrue(text.contains(said), "\(said):\n\(text)")
        }
        let simulated = service.requests.filter { queryItems($0)["Action"] == "SimulatePrincipalPolicy" }
        XCTAssertTrue(simulated.allSatisfy { queryItems($0)["PolicySourceArn"] == "arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_PionContainment_abc" })
        XCTAssertTrue(simulated.contains { queryItems($0)["ResourceArns.member.1"] == "arn:aws:iam::111111111111:user/pion-access-check" })
    }
}
