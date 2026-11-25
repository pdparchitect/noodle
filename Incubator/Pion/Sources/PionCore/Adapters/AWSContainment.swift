import CryptoKit
import Foundation
import NoodleCore
import NoodleToolConnections

/// AWS Containment: acting on an organisation's accounts to contain an incident, through a permission set of its own,
/// kept apart from AWS Detection's so the detection role stays read-only. Every principal, instance, bucket, trail and finding
/// it acts on must be in the account named; what cuts off or restores access, stops an instance, hides a finding or
/// deletes something waits for the champion's approval. What Pion makes or changes carries its mark, a tag or a name,
/// so an undo only ever removes Pion's own.
extension AWS {
    public static let containment = ToolDefinition(
        id: "519c7abb-cb08-4f06-8abc-ad64d5497d6f", name: "AWS Containment",
        summary: "Deactivate an access key, quarantine a user or role, isolate, stop or snapshot an instance, block S3 public access, restart logging and archive or close findings, across an organisation's accounts.",
        defaultInstructions: """
        Use AWS Containment to contain an incident in an organisation's accounts. Find what to act on with AWS Detection \
        first, and give each user and role by its ARN, each instance by its ID, with the account it is in. \
        deactivate-access-key turns a user's key off, saying when it was last used; reactivate-access-key undoes only \
        what Pion did. quarantine-principal attaches AWS's AWSDenyAll policy, or AWSCompromisedKeyQuarantineV3, to a \
        user or role, which also stops sessions already open, and tags it as Pion's; release-principal removes only \
        Pion's quarantine. revoke-role-sessions denies every session of a role made before now, if the permission set \
        has the optional permission it needs; remove-session-revocation undoes it. delete-login-profile removes a \
        user's console password and cannot be undone. isolate-instance moves each of an instance's network interfaces \
        into a security group named pion-isolate and the instance's ID, tagged as Pion's, with no rules in or out, and \
        records each interface's groups on it; unisolate-instance puts back the recorded groups of the interfaces still \
        in Pion's group. Connections already open may continue until they close, so stop-instance stops it when it must \
        stop now, losing what is only in its memory: snapshot-volumes first. detach-instance-profile takes away the \
        instance's role, but credentials it already took stay good until they expire, so quarantine the role too. \
        protect-instance stops it being terminated. block-s3-public-access turns on all four Block Public Access \
        settings of a bucket or the whole account, saying what they were. restart-logging starts a stopped CloudTrail \
        trail or turns GuardDuty back on. archive-guardduty-findings and close-findings take findings out of the alert \
        watch and responders' views; unarchive-guardduty-findings and set-finding-workflow reopen them. \
        deactivate-access-key, reactivate-access-key, quarantine-principal, release-principal, revoke-role-sessions, \
        remove-session-revocation, delete-login-profile, isolate-instance, unisolate-instance, detach-instance-profile, \
        stop-instance, block-s3-public-access, archive-guardduty-findings and close-findings are held for the \
        champion's approval: give the exact resource, and in --approval-reason why, the expected effect and how to \
        undo it, with the Investigation as --approval-conversation. AWS takes no write condition for these, so each \
        reads what it acts on first and again after, and says when something changed meanwhile. Record what each \
        returns as evidence. Run check-access when something is refused, and tell the champion exactly what it says to \
        add to the permission set.
        """,
        iconName: "aws",
        configuration: .connection(.init(endpointTemplate: "https://amazonaws.com",
            fields: [ToolField(key: "startURL", title: "AWS access portal URL", placeholder: "https://example.awsapps.com/start", kind: .text),
                     ToolField(key: "role", title: "Role in each account", placeholder: "PionContainment", kind: .text),
                     ToolField(key: "region", title: "Default region", placeholder: "us-east-1",
                               kind: .choice(regions.map { .init(value: $0, title: $0) }))],
            signsInWithAWSIdentityCenter: true, adapter: "aws-containment")),
        setup: containmentSetup)

    static let containmentSetup = [
        "In the **IAM Identity Center** console, open **Permission sets** and create a custom permission set for containment alone, named such as `PionContainment`, apart from AWS Detection's. Set its session duration to an hour.",
        "Give it this inline policy and nothing else; leave out any statement whose actions you do not want agents to have: `\(compact(containmentPolicy))`",
        "Only if agents should be able to end a role's open sessions with revoke-role-sessions, add this statement to the policy's list too. IAM cannot limit what an inline policy it allows says, so it lets the permission set give any role any permission; it is off unless you add it: `\(compact(revocationStatement))`",
        "Under **AWS accounts**, assign the permission set only to a responder user or group, and only in the accounts where containment is wanted, not the management account. Require MFA for them at your identity provider.",
        "Enter the **AWS access portal URL** and the permission set's name as the role, and choose the default region. Choose **Add & Connect** and approve the code on your organisation's sign-in page, then ask an agent to run check-access.",
    ]

    /// The containment permission set's policy: reads to check each target first, then only the changes the operations
    /// make, IAM's attachments limited to AWS's deny-all policies, and nothing on Identity Center's own roles.
    static let containmentPolicy = """
    {"Version":"2012-10-17","Statement":[
     {"Sid":"Read","Effect":"Allow","Resource":"*","Action":["sts:GetCallerIdentity","iam:GetRole","iam:ListAccessKeys","iam:GetAccessKeyLastUsed",
      "iam:GetLoginProfile","iam:ListAttachedUserPolicies","iam:ListAttachedRolePolicies","iam:GetRolePolicy","iam:ListUserTags","iam:ListRoleTags",
      "iam:SimulatePrincipalPolicy","ec2:DescribeInstances","ec2:DescribeNetworkInterfaces","ec2:DescribeSecurityGroups",
      "ec2:DescribeIamInstanceProfileAssociations","s3:GetBucketPublicAccessBlock","s3:GetAccountPublicAccessBlock","cloudtrail:GetTrailStatus",
      "guardduty:ListDetectors","guardduty:GetDetector","guardduty:GetFindings","securityhub:GetFindings"]},
     {"Sid":"Users","Effect":"Allow","Resource":"arn:aws:iam::*:user/*","Action":["iam:UpdateAccessKey","iam:DeleteLoginProfile","iam:TagUser","iam:UntagUser"]},
     {"Sid":"Roles","Effect":"Allow","Resource":"arn:aws:iam::*:role/*","Action":["iam:TagRole","iam:UntagRole"]},
     {"Sid":"DenyAllOnly","Effect":"Allow","Resource":"*","Action":["iam:AttachUserPolicy","iam:DetachUserPolicy","iam:AttachRolePolicy","iam:DetachRolePolicy"],
      "Condition":{"ArnEquals":{"iam:PolicyARN":["arn:aws:iam::aws:policy/AWSDenyAll","arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3"]}}},
     {"Sid":"Instances","Effect":"Allow","Resource":"*","Action":["ec2:CreateSecurityGroup","ec2:RevokeSecurityGroupEgress","ec2:CreateTags","ec2:DeleteTags",
      "ec2:ModifyNetworkInterfaceAttribute","ec2:DisassociateIamInstanceProfile","ec2:CreateSnapshots","ec2:StopInstances","ec2:ModifyInstanceAttribute"]},
     {"Sid":"Buckets","Effect":"Allow","Resource":"*","Action":["s3:PutBucketPublicAccessBlock","s3:PutAccountPublicAccessBlock"]},
     {"Sid":"Findings","Effect":"Allow","Resource":"*","Action":["guardduty:ArchiveFindings","guardduty:UnarchiveFindings","guardduty:UpdateFindingsFeedback",
      "guardduty:UpdateDetector","securityhub:BatchUpdateFindings","cloudtrail:StartLogging"]},
     {"Sid":"NeverIdentityCenterOrAdminRoles","Effect":"Deny","NotAction":["iam:Get*","iam:List*","iam:SimulatePrincipalPolicy"],
      "Resource":["arn:aws:iam::*:role/aws-reserved/*","arn:aws:iam::*:role/OrganizationAccountAccessRole"]}]}
    """

    /// A policy on one line, as a setup step shows it.
    static func compact(_ policy: String) -> String {
        policy.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
    }

    static let revocationStatement = """
    {"Sid":"RevokeSessions","Effect":"Allow","Resource":"arn:aws:iam::*:role/*","Action":["iam:PutRolePolicy","iam:DeleteRolePolicy"]}
    """

    public static let containmentAdapter = OperationAdapter(operations: [
        DeactivateAccessKey(), ReactivateAccessKey(), QuarantinePrincipal(), ReleasePrincipal(), RevokeRoleSessions(), RemoveSessionRevocation(),
        DeleteLoginProfile(), IsolateInstance(), UnisolateInstance(), DetachInstanceProfile(), StopInstance(), SnapshotVolumes(), ProtectInstance(),
        BlockS3PublicAccess(), RestartLogging(), ArchiveGuardDutyFindings(), UnarchiveGuardDutyFindings(), GuardDutyFeedback(), SetFindingWorkflow(),
        CloseFindings(), ContainmentCheckAccess(),
    ])

    // MARK: Marks

    /// What Pion's marks are called: tags on what it changed, and the name and tag of what it made.
    static let quarantineTag = "pion-quarantine", deactivatedTag = "pion-deactivated-", isolationTag = "pion-isolation"
    static let previousGroupsTag = "pion-previous-groups", evidenceTag = "pion-evidence", revocationPolicy = "PionRevokeOlderSessions"
    static let quarantinePolicies = ["deny-all": "arn:aws:iam::aws:policy/AWSDenyAll", "compromised-key": "arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3"]

    static func isolationGroup(_ instance: String) -> String { "pion-isolate-\(instance)" }

    // MARK: Inputs

    /// An IAM user or role, from its ARN, in the account named; never one of Identity Center's or AWS's own roles, or
    /// the role an organisation administers its accounts with.
    struct Principal: Sendable {
        let kind: String, name: String, arn: String
        var isUser: Bool { kind == "user" }
        var said: String { "\(kind) \(name)" }
    }

    static func principal(_ value: String, in target: Target) throws -> Principal {
        let value = value.trimmingCharacters(in: .whitespaces)
        let pattern = #"^arn:aws:iam::([0-9]{12}):(user|role)((/[A-Za-z0-9+=,.@_-]+)*)/([A-Za-z0-9+=,.@_-]{1,64})$"#
        guard value.count <= 2_048, let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let account = Range(match.range(at: 1), in: value), let kind = Range(match.range(at: 2), in: value), let name = Range(match.range(at: 5), in: value) else {
            throw ServiceError.input("Give the user or role as its ARN, such as arn:aws:iam::\(target.account.id):user/name or arn:aws:iam::\(target.account.id):role/name.")
        }
        let path = Range(match.range(at: 3), in: value).map { String(value[$0]) } ?? ""
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ServiceError.input("Give the user or role as its ARN, without . or .. in its path.")
        }
        guard String(value[account]) == target.account.id else {
            throw ServiceError.input("\(value) is in account \(value[account]), not \(target.named): only the account named can be changed. Name its own account.")
        }
        let principal = Principal(kind: String(value[kind]), name: String(value[name]), arn: value)
        if principal.kind == "role" {
            let reserved = path.hasPrefix("/aws-reserved/") || path.hasPrefix("/aws-service-role/") || principal.name.hasPrefix("AWSReservedSSO_")
                || principal.name.hasPrefix("AWSServiceRoleFor")
            guard !reserved, principal.name != "OrganizationAccountAccessRole" else {
                throw ServiceError.input("Nothing was changed: \(principal.name) is a role IAM Identity Center, AWS or the organisation manages, which Pion never changes; remove the person's access in IAM Identity Center or your identity provider instead.")
            }
        }
        return principal
    }

    static func accessKeyID(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespaces)
        guard (16...128).contains(key.count), key.hasPrefix("AKIA"), key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw ServiceError.input("Give a long-term access key ID, AKIA…; a temporary one, ASIA…, ends with its session: quarantine-principal or revoke-role-sessions stops it.")
        }
        return key
    }

    /// A bucket's name as S3 allows one, which only ever goes in a path, never a host.
    static func bucket(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespaces)
        guard (3...63).contains(name.count), name.range(of: #"^[a-z0-9][a-z0-9.-]*[a-z0-9]$"#, options: .regularExpression) != nil, !name.contains(".."),
              name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) == nil else {
            throw ServiceError.input("Give the bucket's name alone, such as payroll-exports.")
        }
        return name
    }

    static func tags(_ node: XMLNode?) -> [String: String] {
        Dictionary((node?.children ?? []).compactMap { item in
            (item.value("Key") ?? item.value("key")).map { ($0, item.value("Value") ?? item.value("value") ?? "") }
        }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Requests

    static func iam(_ target: Target, _ action: String, _ parameters: [String: String]) async throws -> XMLNode {
        try await target.client.xml([], query: ["Action": action, "Version": "2010-05-08"].merging(parameters.mapValues { Optional($0) }) { $1 })
    }

    /// A change, sent as a POST, which is never sent twice when AWS could not answer.
    static func change(_ target: Target, _ action: String, _ parameters: [String: String]) async throws -> XMLNode {
        let version = target.service == .ec2 ? "2016-11-15" : "2010-05-08"
        return try await target.client.xml([], form: ["Action": action, "Version": version].merging(parameters) { $1 })
    }

    static func ec2(_ target: Target, _ action: String, _ parameters: [String: String]) async throws -> XMLNode {
        try await target.client.xml([], query: ["Action": action, "Version": "2016-11-15"].merging(parameters.mapValues { Optional($0) }) { $1 })
    }

    static func iamTarget(_ account: String?, on service: ServiceClient) async throws -> Target {
        let (chosen, signed) = try await AWS.account(account, on: service)
        return try Target(client: signed, account: chosen, region: "us-east-1", service: .iam).at(.iam)
    }

    /// A partial change said precisely: what was done, then what failed, and how to undo what was done.
    static func partly(_ done: [String], _ failure: String, undo: String) -> ServiceError {
        ServiceError.input(done.isEmpty ? "Nothing was changed: \(failure)." : "Only partly done: \(done.joined(separator: "; ")); then \(failure). \(undo)")
    }

    static func principalTags(_ iam: Target, _ principal: Principal) async throws -> [String: String] {
        let answer = try await AWS.iam(iam, principal.isUser ? "ListUserTags" : "ListRoleTags", [principal.isUser ? "UserName" : "RoleName": principal.name])
        return tags(answer.child(principal.isUser ? "ListUserTagsResult" : "ListRoleTagsResult")?.child("Tags"))
    }

    static func tag(_ iam: Target, _ principal: Principal, _ key: String, _ value: String) async throws {
        _ = try await change(iam, principal.isUser ? "TagUser" : "TagRole", [principal.isUser ? "UserName" : "RoleName": principal.name,
                                                                                 "Tags.member.1.Key": key, "Tags.member.1.Value": value])
    }

    static func untag(_ iam: Target, _ principal: Principal, _ key: String) async throws {
        _ = try await change(iam, principal.isUser ? "UntagUser" : "UntagRole", [principal.isUser ? "UserName" : "RoleName": principal.name, "TagKeys.member.1": key])
    }

    static func attached(_ iam: Target, _ principal: Principal) async throws -> [String] {
        let answer = try await AWS.iam(iam, principal.isUser ? "ListAttachedUserPolicies" : "ListAttachedRolePolicies",
                                       [principal.isUser ? "UserName" : "RoleName": principal.name, "MaxItems": "1000"])
        return answer.all("PolicyArn").map(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func stamp() -> String { iso(Date()) }

    /// A structured result of texts and lists of texts.
    static func fields(_ values: [String: Any]) -> JSON {
        .object(values.mapValues { value in
            if let text = value as? String { return .string(text) }
            if let list = value as? [String] { return .array(list.map(JSON.string)) }
            return .null
        })
    }
}

// MARK: Access keys and principals

extension AWS {
    struct KeyInput: Decodable, Sendable { let user: String, accessKeyId: String, account: String? }
    static let keyInput = JSONSchema.object([
        "user": .string("The user's ARN, such as arn:aws:iam::111111111111:user/name."),
        "accessKeyId": .string("The access key ID, AKIA…."),
        "account": .string("The account the user is in, by its ID or name. Needed unless the sign-in covers only one."),
    ], required: ["user", "accessKeyId"])

    /// A user's key as IAM lists it now, or a refusal when the key is not that user's.
    static func key(_ iam: Target, user: Principal, id: String) async throws -> String {
        guard user.isUser else { throw ServiceError.input("Give a user's ARN: access keys belong to users.") }
        let answer = try await read("the user's access keys", needs: ["iam:ListAccessKeys"]) {
            try await AWS.iam(iam, "ListAccessKeys", ["UserName": user.name, "MaxItems": "100"])
        }
        guard let found = answer.all("member").first(where: { $0.value("AccessKeyId") == id }), let status = found.value("Status") else {
            throw ServiceError.input("Nothing was changed: \(id) is not one of \(user.name)'s access keys in \(iam.named). access-key in AWS Detection says whose it is.")
        }
        return status
    }

    static func lastUse(_ iam: Target, _ id: String) async -> String {
        guard let answer = try? await AWS.iam(iam, "GetAccessKeyLastUsed", ["AccessKeyId": id]),
              let result = answer.child("GetAccessKeyLastUsedResult") else { return "its last use could not be read" }
        guard let used = result.value("AccessKeyLastUsed", "LastUsedDate") else { return "IAM records no use of it" }
        return "it was last used \(used) with \(result.value("AccessKeyLastUsed", "ServiceName") ?? "?") in \(result.value("AccessKeyLastUsed", "Region") ?? "?")"
    }

    struct DeactivateAccessKey: ServiceOperation {
        typealias Input = KeyInput
        static let name = "deactivate-access-key"
        static let summary = "Turn off one of a user's access keys, ending what uses it, and tag the user as Pion's doing, saying the key's status before and its last use. Undo with reactivate-access-key."
        static let input = AWS.keyInput
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            let user = try AWS.principal(input.user, in: iam), id = try AWS.accessKeyID(input.accessKeyId)
            let before = try await AWS.key(iam, user: user, id: id)
            let used = await AWS.lastUse(iam, id)
            guard before == "Active" else {
                return try ServiceResult(text: "\(id) of \(user.name) in \(iam.named) is already \(before.lowercased()); nothing was changed. \(used.prefix(1).uppercased() + used.dropFirst()).",
                                         structured: ["accessKeyId": id, "user": user.arn, "status": before, "changed": "false"])
            }
            // Pion's mark goes first, so whatever happens next, reactivate-access-key knows the key was turned off by Pion.
            do { try await AWS.tag(iam, user, AWS.deactivatedTag + id, AWS.stamp()) }
            catch { throw AWS.partly([], "tagging \(user.name) as Pion's change failed: \(AWS.fix(for: error, needs: ["iam:TagUser"]) ?? error.localizedDescription)", undo: "") }
            do {
                _ = try await AWS.change(iam, "UpdateAccessKey", ["UserName": user.name, "AccessKeyId": id, "Status": "Inactive"])
            } catch {
                try? await AWS.untag(iam, user, AWS.deactivatedTag + id)
                throw AWS.partly([], "turning \(id) off failed: \(AWS.fix(for: error, needs: ["iam:UpdateAccessKey"]) ?? error.localizedDescription)", undo: "")
            }
            let after = (try? await AWS.key(iam, user: user, id: id)) ?? "unknown"
            let meanwhile = after == "Inactive" ? "" : " Read again, it is \(after.lowercased()): someone may have changed it meanwhile, so check it."
            return try ServiceResult(text: "Turned off \(id) of \(user.name) in \(iam.named); it was active and \(used).\(meanwhile) Other keys of the user, its console password and sessions already open are untouched: quarantine-principal stops those. Undo with reactivate-access-key.",
                                     structured: ["accessKeyId": id, "user": user.arn, "account": iam.account.id, "before": before, "after": after])
        }
    }

    struct ReactivateAccessKey: ServiceOperation {
        typealias Input = KeyInput
        static let name = "reactivate-access-key"
        static let summary = "Undo deactivate-access-key: turn a key Pion turned off back on, only when the user still carries Pion's tag for it, and remove the tag."
        static let input = AWS.keyInput
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            let user = try AWS.principal(input.user, in: iam), id = try AWS.accessKeyID(input.accessKeyId)
            let before = try await AWS.key(iam, user: user, id: id)
            guard try await AWS.principalTags(iam, user)[AWS.deactivatedTag + id] != nil else {
                throw ServiceError.input("Nothing was changed: \(user.name) carries no tag saying Pion turned \(id) off, so it was turned off some other way and is left for someone to decide.")
            }
            var done: [String] = []
            if before != "Active" {
                do {
                    _ = try await AWS.change(iam, "UpdateAccessKey", ["UserName": user.name, "AccessKeyId": id, "Status": "Active"])
                    done.append("turned \(id) back on")
                } catch {
                    throw AWS.partly([], "turning \(id) on failed: \(AWS.fix(for: error, needs: ["iam:UpdateAccessKey"]) ?? error.localizedDescription)", undo: "")
                }
            }
            do { try await AWS.untag(iam, user, AWS.deactivatedTag + id) }
            catch { throw AWS.partly(done, "removing Pion's tag from \(user.name) failed: \(error.localizedDescription)", undo: "Remove the tag \(AWS.deactivatedTag + id) in IAM.") }
            return try ServiceResult(text: before == "Active" ? "\(id) was already active; removed Pion's tag from \(user.name)." : "Turned \(id) of \(user.name) in \(iam.named) back on and removed Pion's tag.",
                                     structured: ["accessKeyId": id, "user": user.arn, "before": before, "after": "Active"])
        }
    }

    struct PrincipalInput: Decodable, Sendable { let principal: String, account: String? }

    struct QuarantinePrincipal: ServiceOperation {
        struct Input: Decodable, Sendable { let principal: String, policy: String?, account: String? }
        static let name = "quarantine-principal"
        static let summary = "Cut a user or role off: attach AWS's AWSDenyAll policy, or AWSCompromisedKeyQuarantineV3, which also stops sessions and keys already in use, tagging it pion-quarantine first so release-principal removes only Pion's quarantine. Refuses Identity Center's, AWS's and the organisation's own roles."
        static let input = JSONSchema.object([
            "principal": .string("The user's or role's ARN."),
            "policy": .string("Which AWS policy: deny-all, AWSDenyAll, which denies everything, or compromised-key, AWSCompromisedKeyQuarantineV3, AWS's own for exposed keys. deny-all when left out.", oneOf: ["deny-all", "compromised-key"]),
            "account": .string("The account it is in, by its ID or name. Needed unless the sign-in covers only one."),
        ], required: ["principal"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            let principal = try AWS.principal(input.principal, in: iam)
            let choice = try ServiceInput.oneOf(input.policy ?? "deny-all", ["deny-all", "compromised-key"], "policy")
            let policy = AWS.quarantinePolicies[choice]!
            let attached = try await AWS.read("the \(principal.kind)'s policies", needs: [principal.isUser ? "iam:ListAttachedUserPolicies" : "iam:ListAttachedRolePolicies"]) {
                try await AWS.attached(iam, principal)
            }
            let tags = try await AWS.read("the \(principal.kind)'s tags", needs: [principal.isUser ? "iam:ListUserTags" : "iam:ListRoleTags"]) {
                try await AWS.principalTags(iam, principal)
            }
            if attached.contains(policy) {
                return try ServiceResult(text: tags[AWS.quarantineTag] != nil
                                            ? "\(principal.said) in \(iam.named) is already quarantined by Pion with \(policy); nothing was changed."
                                            : "\(principal.said) in \(iam.named) already has \(policy) attached, not by Pion, so release-principal will not remove it; nothing was changed.",
                                         structured: ["principal": principal.arn, "policy": policy, "changed": "false"])
            }
            if let mark = tags[AWS.quarantineTag], let other = AWS.quarantinePolicies.values.first(where: { mark.hasPrefix($0) }), other != policy, attached.contains(other) {
                throw ServiceError.input("Nothing was changed: \(principal.said) is already quarantined by Pion with \(other); release-principal first to change the policy.")
            }
            do { try await AWS.tag(iam, principal, AWS.quarantineTag, "\(policy) \(AWS.stamp())") }
            catch { throw AWS.partly([], "tagging \(principal.said) as Pion's quarantine failed: \(AWS.fix(for: error, needs: [principal.isUser ? "iam:TagUser" : "iam:TagRole"]) ?? error.localizedDescription)", undo: "") }
            do {
                _ = try await AWS.change(iam, principal.isUser ? "AttachUserPolicy" : "AttachRolePolicy", [principal.isUser ? "UserName" : "RoleName": principal.name, "PolicyArn": policy])
            } catch {
                let untagged = (try? await AWS.untag(iam, principal, AWS.quarantineTag)) != nil
                throw AWS.partly(untagged ? [] : ["tagged \(principal.said) \(AWS.quarantineTag)"],
                                 "attaching \(policy) failed: \(AWS.fix(for: error, needs: [principal.isUser ? "iam:AttachUserPolicy" : "iam:AttachRolePolicy"]) ?? error.localizedDescription)",
                                 undo: "Remove the tag \(AWS.quarantineTag) from it in IAM.")
            }
            let now = (try? await AWS.attached(iam, principal)) ?? []
            let meanwhile = now.contains(policy) ? "" : " Read again, \(policy) is not attached: someone may have removed it meanwhile, so check it."
            return try ServiceResult(text: "Quarantined \(principal.said) in \(iam.named): attached \(policy), which takes effect on its sessions and keys already in use within seconds, and tagged it \(AWS.quarantineTag).\(meanwhile) Undo with release-principal.",
                                     structured: ["principal": principal.arn, "account": iam.account.id, "policy": policy, "tag": AWS.quarantineTag])
        }
    }

    struct ReleasePrincipal: ServiceOperation {
        typealias Input = PrincipalInput
        static let name = "release-principal"
        static let summary = "Undo quarantine-principal: detach the policy Pion attached and remove its pion-quarantine tag, only when the user or role carries that tag; a deny-all policy someone else attached stays."
        static let input = JSONSchema.object(["principal": .string("The user's or role's ARN."),
                                              "account": .string("The account it is in, by its ID or name. Needed unless the sign-in covers only one.")], required: ["principal"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            let principal = try AWS.principal(input.principal, in: iam)
            guard let mark = try await AWS.principalTags(iam, principal)[AWS.quarantineTag],
                  let policy = AWS.quarantinePolicies.values.first(where: { mark.hasPrefix($0 + " ") || mark == $0 }) else {
                throw ServiceError.input("Nothing was changed: \(principal.said) carries no \(AWS.quarantineTag) tag naming a policy Pion attaches, so any deny-all policy on it was attached some other way and is left for someone to decide.")
            }
            var done: [String] = []
            if try await AWS.attached(iam, principal).contains(policy) {
                do {
                    _ = try await AWS.change(iam, principal.isUser ? "DetachUserPolicy" : "DetachRolePolicy", [principal.isUser ? "UserName" : "RoleName": principal.name, "PolicyArn": policy])
                    done.append("detached \(policy)")
                } catch {
                    throw AWS.partly([], "detaching \(policy) failed: \(AWS.fix(for: error, needs: [principal.isUser ? "iam:DetachUserPolicy" : "iam:DetachRolePolicy"]) ?? error.localizedDescription)", undo: "")
                }
            }
            do { try await AWS.untag(iam, principal, AWS.quarantineTag) }
            catch { throw AWS.partly(done, "removing the tag failed: \(error.localizedDescription)", undo: "Remove the tag \(AWS.quarantineTag) in IAM.") }
            return try ServiceResult(text: done.isEmpty ? "\(policy) was no longer attached to \(principal.said); removed Pion's tag." : "Released \(principal.said) in \(iam.named): detached \(policy) and removed Pion's tag.",
                                     structured: ["principal": principal.arn, "policy": policy])
        }
    }

    /// The inline policy that denies a role's sessions made before `time`, as the IAM console's own revocation does.
    static func revocation(_ time: String) -> String {
        #"{"Version":"2012-10-17","Statement":[{"Sid":"\#(revocationPolicy)","Effect":"Deny","Action":"*","Resource":"*","Condition":{"DateLessThan":{"aws:TokenIssueTime":"\#(time)"}}}]}"#
    }

    /// The role's inline policy of Pion's name, or nil when it has none; whether it is Pion's, by its statement's Sid.
    static func revocationOf(_ iam: Target, _ role: Principal) async throws -> (pions: Bool, document: String)? {
        do {
            let answer = try await AWS.iam(iam, "GetRolePolicy", ["RoleName": role.name, "PolicyName": revocationPolicy])
            let document = answer.value("GetRolePolicyResult", "PolicyDocument")?.removingPercentEncoding ?? ""
            let parsed = try? JSONDecoder().decode(JSON.self, from: Data(document.utf8))
            let pions = parsed.map { statements($0).count == 1 && text(statements($0)[0]["Sid"]) == revocationPolicy && text(statements($0)[0]["Effect"]) == "Deny" } ?? false
            return (pions, document)
        } catch ServiceError.notFound {
            return nil
        }
    }

    struct RevokeRoleSessions: ServiceOperation {
        typealias Input = PrincipalInput
        static let name = "revoke-role-sessions"
        static let summary = "End every session of a role made before now, whoever holds it, with an inline policy named PionRevokeOlderSessions denying them, as IAM's own revocation does; new sessions still work. Needs the optional permission from Setup Steps. Undo with remove-session-revocation."
        static let input = JSONSchema.object(["principal": .string("The role's ARN."),
                                              "account": .string("The account it is in, by its ID or name. Needed unless the sign-in covers only one.")], required: ["principal"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            let role = try AWS.principal(input.principal, in: iam)
            guard !role.isUser else { throw ServiceError.input("Give a role's ARN: a user's sessions end with quarantine-principal or deactivate-access-key.") }
            if let existing = try await AWS.revocationOf(iam, role), !existing.pions {
                throw ServiceError.input("Nothing was changed: \(role.name) already has an inline policy named \(AWS.revocationPolicy) that Pion did not write, so it is left as it is.")
            }
            let time = AWS.stamp()
            do {
                _ = try await AWS.change(iam, "PutRolePolicy", ["RoleName": role.name, "PolicyName": AWS.revocationPolicy, "PolicyDocument": AWS.revocation(time)])
            } catch {
                throw AWS.partly([], "putting the policy failed: \(AWS.fix(for: error, needs: ["iam:PutRolePolicy"]) ?? error.localizedDescription) This permission is optional and off unless the permission set has it", undo: "")
            }
            return try ServiceResult(text: "Every session of \(role.name) in \(iam.named) made before \(time) is now denied everything, through its inline policy \(AWS.revocationPolicy). IAM has no write condition, so had someone written a policy of that name at the same moment, this replaced it. Undo with remove-session-revocation.",
                                     structured: ["role": role.arn, "account": iam.account.id, "revokedBefore": time, "policy": AWS.revocationPolicy])
        }
    }

    struct RemoveSessionRevocation: ServiceOperation {
        typealias Input = PrincipalInput
        static let name = "remove-session-revocation"
        static let summary = "Undo revoke-role-sessions: delete the role's PionRevokeOlderSessions policy, only when it is the one Pion wrote, letting sessions made before it work again until they expire."
        static let input = RevokeRoleSessions.input
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            let role = try AWS.principal(input.principal, in: iam)
            guard !role.isUser else { throw ServiceError.input("Give a role's ARN.") }
            guard let existing = try await AWS.revocationOf(iam, role) else {
                return try ServiceResult(text: "\(role.name) has no \(AWS.revocationPolicy) policy; nothing was changed.", structured: ["role": role.arn, "changed": "false"])
            }
            guard existing.pions else {
                throw ServiceError.input("Nothing was changed: \(role.name)'s \(AWS.revocationPolicy) policy is not the one Pion writes, so it is left as it is.")
            }
            do { _ = try await AWS.change(iam, "DeleteRolePolicy", ["RoleName": role.name, "PolicyName": AWS.revocationPolicy]) }
            catch { throw AWS.partly([], "deleting the policy failed: \(AWS.fix(for: error, needs: ["iam:DeleteRolePolicy"]) ?? error.localizedDescription)", undo: "") }
            return try ServiceResult(text: "Deleted \(role.name)'s \(AWS.revocationPolicy) policy in \(iam.named): its older sessions work again until they expire.", structured: ["role": role.arn])
        }
    }

    struct DeleteLoginProfile: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, account: String? }
        static let name = "delete-login-profile"
        static let summary = "Remove a user's console password, so it can no longer sign in to the console. It cannot be undone: a new password must be set in IAM. Keys and sessions are untouched."
        static let input = JSONSchema.object(["user": .string("The user's ARN."),
                                              "account": .string("The account it is in, by its ID or name. Needed unless the sign-in covers only one.")], required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            let user = try AWS.principal(input.user, in: iam)
            guard user.isUser else { throw ServiceError.input("Give a user's ARN: roles have no console password.") }
            let made: String?
            do {
                made = try await AWS.iam(iam, "GetLoginProfile", ["UserName": user.name]).value("GetLoginProfileResult", "LoginProfile", "CreateDate")
            } catch ServiceError.notFound {
                return try ServiceResult(text: "\(user.name) in \(iam.named) has no console password; nothing was changed.", structured: ["user": user.arn, "changed": "false"])
            }
            do { _ = try await AWS.change(iam, "DeleteLoginProfile", ["UserName": user.name]) }
            catch { throw AWS.partly([], "deleting the console password failed: \(AWS.fix(for: error, needs: ["iam:DeleteLoginProfile"]) ?? error.localizedDescription)", undo: "") }
            return try ServiceResult(text: "Removed \(user.name)'s console password in \(iam.named)\(made.map { ", set \($0)" } ?? ""). It cannot be restored: set a new one in IAM if the user should sign in again. Its access keys and open console sessions are untouched.",
                                     structured: ["user": user.arn, "account": iam.account.id, "passwordSet": made ?? ""])
        }
    }
}

// MARK: Instances

extension AWS {
    struct InstanceInput: Decodable, Sendable { let instanceId: String, region: String?, account: String? }
    static let instanceInput = JSONSchema.object([
        "instanceId": .string("The instance's ID, such as i-0abc1234def567890."),
        "region": .string("Its region, when not the connection's default."),
        "account": .string("The account it is in, by its ID or name. Needed unless the sign-in covers only one."),
    ], required: ["instanceId"])

    /// An instance as EC2 describes it now: in the account named, with its VPC and every network interface, each by
    /// its ID.
    struct Instance {
        struct Interface { let id: String; let groups: [String] }
        let id: String, state: String, vpc: String?, interfaces: [Interface]
    }

    static func isInterfaceID(_ value: String) -> Bool { value.range(of: #"^eni-[0-9a-f]{8,17}$"#, options: .regularExpression) != nil }
    static func isGroupID(_ value: String) -> Bool { value.range(of: #"^sg-[0-9a-f]{8,17}$"#, options: .regularExpression) != nil }

    static func instance(_ ec2: Target, _ id: String) async throws -> Instance {
        let answer: XMLNode
        do {
            answer = try await read("the instance", needs: ["ec2:DescribeInstances"]) { try await AWS.ec2(ec2, "DescribeInstances", ["InstanceId.1": id]) }
        } catch ServiceError.refused(let reason) where reason.contains("InvalidInstanceID") {
            throw ServiceError.input("Nothing was changed: \(ec2.place) has no instance \(id). Name the account and region it is in.")
        }
        guard let reservation = answer.child("reservationSet")?.children.first, let item = reservation.child("instancesSet")?.children.first,
              item.value("instanceId") == id else {
            throw ServiceError.input("Nothing was changed: \(ec2.place) has no instance \(id). Name the account and region it is in.")
        }
        guard reservation.value("ownerId") == ec2.account.id else {
            throw ServiceError.input("Nothing was changed: \(id) belongs to account \(reservation.value("ownerId") ?? "?"), not \(ec2.named).")
        }
        // Every interface is accounted for, or nothing is done: one listed without a valid ID could not be isolated.
        let interfaces = try (item.child("networkInterfaceSet")?.children ?? []).map { interface -> Instance.Interface in
            guard let nic = interface.value("networkInterfaceId"), isInterfaceID(nic) else {
                throw ServiceError.input("Nothing was changed: EC2 lists a network interface of \(id) without a valid ID, so not all its traffic could be accounted for. Check the instance in the EC2 console, or stop-instance.")
            }
            return Instance.Interface(id: nic, groups: interface.child("groupSet")?.children.compactMap { $0.value("groupId") } ?? [])
        }
        return Instance(id: id, state: item.value("instanceState", "name") ?? "?", vpc: item.value("vpcId"), interfaces: interfaces)
    }

    /// A network interface as EC2 describes it now: its groups, at least one, each a valid ID, and its tags.
    struct InterfaceState { let groups: [String]; let tags: [String: String] }

    /// Every network interface of `ids` as EC2 describes it now, or a reason why not all of them could be: one missing,
    /// without groups, or with a group that is not a valid ID.
    static func interfaces(_ ec2: Target, _ ids: [String]) async throws -> [String: InterfaceState] {
        var parameters: [String: String] = [:]
        for (index, id) in ids.enumerated() { parameters["NetworkInterfaceId.\(index + 1)"] = id }
        let answer = try await read("the network interfaces", needs: ["ec2:DescribeNetworkInterfaces"]) { try await AWS.ec2(ec2, "DescribeNetworkInterfaces", parameters) }
        var found: [String: InterfaceState] = [:]
        for item in answer.child("networkInterfaceSet")?.children ?? [] {
            guard let id = item.value("networkInterfaceId"), ids.contains(id) else { continue }
            let groups = item.child("groupSet")?.children.compactMap { $0.value("groupId") } ?? []
            guard !groups.isEmpty, groups.allSatisfy(isGroupID) else {
                throw ServiceError.input("EC2 describes \(id) without a valid list of its security groups, so they could not be recorded or restored")
            }
            found[id] = InterfaceState(groups: groups, tags: tags(item.child("tagSet")))
        }
        let missing = ids.filter { found[$0] == nil }
        guard missing.isEmpty else { throw ServiceError.input("EC2 did not describe \(GoogleCloud.listed(missing)), so not all the instance's traffic could be accounted for") }
        return found
    }

    /// A security group as EC2 describes it: whether it is Pion's isolation group of `instance` in `vpc` in the account,
    /// and how many rules it has, from both its lists of rules, which must both be there.
    struct IsolationGroup { let id: String; let pions: Bool; let rules: Int }

    static func isolationGroup(_ item: XMLNode, instance: String, vpc: String, account: String) throws -> IsolationGroup {
        guard let id = item.value("groupId"), isGroupID(id) else { throw ServiceError.input("EC2 describes a security group without a valid ID") }
        guard let ingress = item.child("ipPermissions"), let egress = item.child("ipPermissionsEgress") else {
            throw ServiceError.input("EC2 did not list all of \(id)'s rules, so whether it lets traffic through is unknown")
        }
        let pions = tags(item.child("tagSet"))[isolationTag] == instance && item.value("ownerId") == account && item.value("vpcId") == vpc
        return IsolationGroup(id: id, pions: pions, rules: ingress.children.count + egress.children.count)
    }

    /// The security group named for the instance's isolation in its VPC, if there is one.
    static func isolationGroup(_ ec2: Target, instance: String, vpc: String) async throws -> IsolationGroup? {
        let answer = try await read("the security groups", needs: ["ec2:DescribeSecurityGroups"]) {
            try await AWS.ec2(ec2, "DescribeSecurityGroups", ["Filter.1.Name": "group-name", "Filter.1.Value.1": isolationGroup(instance),
                                                             "Filter.2.Name": "vpc-id", "Filter.2.Value.1": vpc])
        }
        let items = answer.child("securityGroupInfo")?.children ?? []
        guard items.count <= 1 else { throw ServiceError.input("\(vpc) has more than one security group named \(isolationGroup(instance))") }
        return try items.first.map { try isolationGroup($0, instance: instance, vpc: vpc, account: ec2.account.id) }
    }

    /// The same, by its ID, as read back after it was made.
    static func isolationGroup(_ ec2: Target, id: String, instance: String, vpc: String) async throws -> (group: IsolationGroup, egress: [XMLNode]) {
        let answer = try await AWS.ec2(ec2, "DescribeSecurityGroups", ["GroupId.1": id])
        let items = answer.child("securityGroupInfo")?.children ?? []
        guard items.count == 1, let item = items.first else { throw ServiceError.input("EC2 did not describe \(id) when read back") }
        let group = try isolationGroup(item, instance: instance, vpc: vpc, account: ec2.account.id)
        guard group.id == id else { throw ServiceError.input("EC2 described another group, \(group.id), when \(id) was read back") }
        return (group, item.child("ipPermissionsEgress")?.children ?? [])
    }

    /// Before any change, an error saying nothing was changed.
    static func unchanged<Value>(_ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch ServiceError.input(let reason) where !reason.hasPrefix("Nothing was changed") {
            throw ServiceError.input("Nothing was changed: \(reason).")
        }
    }

    struct IsolateInstance: ServiceOperation {
        typealias Input = InstanceInput
        static let name = "isolate-instance"
        static let summary = "Cut an instance off the network: move each of its network interfaces into a security group named pion-isolate and the instance's ID, made and tagged by Pion with no rules in or out, recording each interface's groups in a tag on it first, and say exactly what changed. It changes nothing unless every interface and its groups, and every rule of Pion's group, can be read, and refuses a group of that name Pion did not make or an interface whose record differs. Connections already open may continue until they close. Undo with unisolate-instance."
        static let input = AWS.instanceInput
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try AWS.instanceID(input.instanceId)
            let ec2 = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            let instance = try await AWS.instance(ec2, id)
            guard let vpc = instance.vpc, !instance.interfaces.isEmpty else {
                throw ServiceError.input("Nothing was changed: \(id) has no network interfaces in a VPC to isolate; stop-instance stops it instead.")
            }
            // Everything is read and checked before the first change: every interface with its groups, Pion's group
            // with all its rules, and a record to put back for each interface that moves.
            let current = try await AWS.unchanged { try await AWS.interfaces(ec2, instance.interfaces.map(\.id)) }
            let existing = try await AWS.unchanged { try await AWS.isolationGroup(ec2, instance: id, vpc: vpc) }
            if let existing {
                guard existing.pions else {
                    throw ServiceError.input("Nothing was changed: \(vpc) already has a security group named \(AWS.isolationGroup(id)), \(existing.id), that Pion did not make for this instance, so it is left as it is.")
                }
                guard existing.rules == 0 else {
                    throw ServiceError.input("Nothing was changed: Pion's isolation group \(existing.id) now has rules someone added, so it no longer isolates; check it before trying again.")
                }
            }
            var moves: [(interface: String, record: String, writeRecord: Bool)] = []
            for interface in instance.interfaces {
                let groups = current[interface.id]!.groups, record = groups.joined(separator: ",")
                if let existing, groups == [existing.id] { continue }
                if let existing, groups.contains(existing.id) {
                    throw ServiceError.input("Nothing was changed: \(interface.id) is in Pion's group \(existing.id) and others, \(record), so what to put back is unclear; set its groups in the EC2 console.")
                }
                guard record.count <= 256 else {
                    throw ServiceError.input("Nothing was changed: \(interface.id) has more groups than one tag can record, so they could not be put back.")
                }
                // A record already there is kept: one that says what the interface's groups are now is used again, as
                // after a move that failed; one that says anything else is left for someone to check.
                if let kept = current[interface.id]!.tags[AWS.previousGroupsTag], kept != record {
                    throw ServiceError.input("Nothing was changed: \(interface.id) already has a \(AWS.previousGroupsTag) record, \(kept), that is not its groups now, \(record): an earlier isolation may be half undone. Check it, and remove the tag in the EC2 console if it is stale.")
                }
                moves.append((interface.id, record, current[interface.id]!.tags[AWS.previousGroupsTag] == nil))
            }
            var done: [String] = []
            let undo = "Run unisolate-instance to put back the interfaces moved, then try again, or stop-instance."
            let group: String
            if let existing {
                group = existing.id
            } else {
                do {
                    let made = try await AWS.change(ec2, "CreateSecurityGroup", [
                        "GroupName": AWS.isolationGroup(id), "VpcId": vpc,
                        "GroupDescription": "Pion isolation of \(id): no traffic in or out. Remove with unisolate-instance.",
                        "TagSpecification.1.ResourceType": "security-group", "TagSpecification.1.Tag.1.Key": AWS.isolationTag, "TagSpecification.1.Tag.1.Value": id,
                        "TagSpecification.1.Tag.2.Key": "Name", "TagSpecification.1.Tag.2.Value": AWS.isolationGroup(id)])
                    guard let made = made.value("groupId"), AWS.isGroupID(made) else {
                        throw ServiceError.input("EC2 answered without the new group's ID; look for \(AWS.isolationGroup(id)) in \(vpc) and delete it")
                    }
                    group = made
                    done.append("made security group \(made)")
                } catch {
                    throw AWS.partly([], "making the isolation group failed: \(AWS.fix(for: error, needs: ["ec2:CreateSecurityGroup", "ec2:CreateTags"]) ?? error.localizedDescription)", undo: undo)
                }
                // The new group is read back as Pion's, in the account and VPC, then everything it lets out is revoked,
                // rule by rule as read, and it is read again to have no rules at all.
                do {
                    let read = try await AWS.isolationGroup(ec2, id: group, instance: id, vpc: vpc)
                    guard read.group.pions else { throw ServiceError.input("\(group) does not read back as Pion's isolation group of \(id) in \(vpc) of \(ec2.named)") }
                    for rule in read.egress {
                        var parameters = ["GroupId": group, "IpPermissions.1.IpProtocol": rule.value("ipProtocol") ?? "-1"]
                        if let low = rule.value("fromPort") { parameters["IpPermissions.1.FromPort"] = low }
                        if let high = rule.value("toPort") { parameters["IpPermissions.1.ToPort"] = high }
                        for (index, range) in (rule.child("ipRanges")?.children ?? []).compactMap({ $0.value("cidrIp") }).enumerated() {
                            parameters["IpPermissions.1.IpRanges.\(index + 1).CidrIp"] = range
                        }
                        for (index, range) in (rule.child("ipv6Ranges")?.children ?? []).compactMap({ $0.value("cidrIpv6") }).enumerated() {
                            parameters["IpPermissions.1.Ipv6Ranges.\(index + 1).CidrIpv6"] = range
                        }
                        _ = try await AWS.change(ec2, "RevokeSecurityGroupEgress", parameters)
                    }
                    let left = try await AWS.isolationGroup(ec2, id: group, instance: id, vpc: vpc)
                    guard left.group.pions, left.group.rules == 0 else { throw ServiceError.input("\(group) still has rules when read again") }
                    done.append("removed its outbound rules")
                } catch {
                    throw AWS.partly(done, "readying the new group failed: \(AWS.fix(for: error, needs: ["ec2:RevokeSecurityGroupEgress"]) ?? error.localizedDescription); no interface was moved", undo: "Delete security group \(group) in the EC2 console.")
                }
            }
            var moved: [String: [String]] = [:]
            for move in moves {
                // The record goes first, and is said as soon as it is written, so a move that fails still leaves what
                // to put back, and says so.
                if move.writeRecord {
                    do {
                        _ = try await AWS.change(ec2, "CreateTags", ["ResourceId.1": move.interface, "Tag.1.Key": AWS.previousGroupsTag, "Tag.1.Value": move.record])
                        done.append("recorded \(move.interface)'s groups \(move.record) in its \(AWS.previousGroupsTag) tag")
                    } catch {
                        throw AWS.partly(done, "recording \(move.interface)'s groups failed: \(AWS.fix(for: error, needs: ["ec2:CreateTags"]) ?? error.localizedDescription)", undo: undo)
                    }
                }
                do {
                    _ = try await AWS.change(ec2, "ModifyNetworkInterfaceAttribute", ["NetworkInterfaceId": move.interface, "SecurityGroupId.1": group])
                    moved[move.interface] = move.record.split(separator: ",").map(String.init)
                    done.append("moved \(move.interface) from \(move.record) into \(group)")
                } catch {
                    throw AWS.partly(done, "moving \(move.interface) failed: \(AWS.fix(for: error, needs: ["ec2:ModifyNetworkInterfaceAttribute"]) ?? error.localizedDescription); its record stays, so trying again moves it", undo: undo)
                }
            }
            // Read again, as EC2 takes no write condition: an interface changed meanwhile is said.
            var text = moved.isEmpty ? "\(id) in \(ec2.place) was already isolated in \(group); nothing was moved."
                : "Isolated \(id) in \(ec2.place): \(done.joined(separator: "; ")). Each interface's groups before are in its \(AWS.previousGroupsTag) tag."
            if let after = try? await AWS.interfaces(ec2, instance.interfaces.map(\.id)) {
                let changed = instance.interfaces.map(\.id).filter { after[$0]?.groups != [group] }
                if !changed.isEmpty { text += " Read again, \(GoogleCloud.listed(changed)) \(changed.count == 1 ? "is" : "are") not only in \(group): someone may have changed \(changed.count == 1 ? "it" : "them") meanwhile, so check." }
            } else {
                text += " The interfaces could not be read again to confirm it, so check them in the EC2 console."
            }
            text += " Connections already open may continue until they close; stop-instance stops it now. Undo with unisolate-instance."
            struct Kept: Encodable { let instance: String; let account: String; let region: String; let group: String; let previousGroups: [String: [String]] }
            return try ServiceResult(text: text, structured: Kept(instance: id, account: ec2.account.id, region: ec2.region, group: group, previousGroups: moved))
        }
    }

    struct UnisolateInstance: ServiceOperation {
        typealias Input = InstanceInput
        static let name = "unisolate-instance"
        static let summary = "Undo isolate-instance: put back the groups recorded on each of the instance's network interfaces that is still only in Pion's isolation group, and remove the record, saying any record that could not be removed. An interface changed since is left as it is and said. Pion's empty group stays; delete it in the EC2 console."
        static let input = AWS.instanceInput
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try AWS.instanceID(input.instanceId)
            let ec2 = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            let instance = try await AWS.instance(ec2, id)
            guard let vpc = instance.vpc, let found = try await AWS.unchanged({ try await AWS.isolationGroup(ec2, instance: id, vpc: vpc) }) else {
                return try ServiceResult(text: "\(id) in \(ec2.place) has no Pion isolation group; nothing was changed.", structured: AWS.fields(["instance": id, "restored": [String]()]))
            }
            guard found.pions else {
                throw ServiceError.input("Nothing was changed: the security group named \(AWS.isolationGroup(id)) was not made by Pion for this instance, so it is left as it is.")
            }
            let current = try await AWS.unchanged { try await AWS.interfaces(ec2, instance.interfaces.map(\.id)) }
            var restore: [(interface: String, groups: [String], record: String)] = [], cleanup: [(interface: String, record: String)] = [], left: [String] = []
            for interface in instance.interfaces {
                let now = current[interface.id]!, record = now.tags[AWS.previousGroupsTag]
                if now.groups == [found.id] {
                    guard let record else { left.append("\(interface.id), which has no record of its groups"); continue }
                    let groups = record.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    guard !groups.isEmpty, groups.allSatisfy(AWS.isGroupID), !groups.contains(found.id) else {
                        left.append("\(interface.id), whose record is not a list of groups"); continue
                    }
                    restore.append((interface.id, groups, record))
                } else if now.groups.contains(found.id) {
                    left.append("\(interface.id), which is in other groups too")
                } else if let record, record == now.groups.joined(separator: ",") {
                    // Put back before, but its record could not be removed then.
                    cleanup.append((interface.id, record))
                }
            }
            var restored: [String] = [], remaining: [String] = []
            func removeRecord(_ interface: String, _ record: String) async {
                do {
                    // Removed only while it still says what was put back.
                    _ = try await AWS.change(ec2, "DeleteTags", ["ResourceId.1": interface, "Tag.1.Key": AWS.previousGroupsTag, "Tag.1.Value": record])
                } catch {
                    remaining.append("\(interface)'s \(AWS.previousGroupsTag) tag (\(AWS.fix(for: error, needs: ["ec2:DeleteTags"]) ?? error.localizedDescription))")
                }
            }
            for item in restore {
                do {
                    var parameters = ["NetworkInterfaceId": item.interface]
                    for (index, group) in item.groups.enumerated() { parameters["SecurityGroupId.\(index + 1)"] = group }
                    _ = try await AWS.change(ec2, "ModifyNetworkInterfaceAttribute", parameters)
                    restored.append("\(item.interface) back in \(item.record)")
                } catch {
                    throw AWS.partly(restored + remaining.map { "could not remove \($0)" },
                                     "putting back \(item.interface)'s groups failed: \(AWS.fix(for: error, needs: ["ec2:ModifyNetworkInterfaceAttribute"]) ?? error.localizedDescription)",
                                     undo: "Run unisolate-instance again once it is fixed.")
                }
                await removeRecord(item.interface, item.record)
            }
            var cleaned: [String] = []
            for item in cleanup {
                let before = remaining.count
                await removeRecord(item.interface, item.record)
                if remaining.count == before { cleaned.append(item.interface) }
            }
            var text = restored.isEmpty ? "No interface of \(id) was only in Pion's group \(found.id); none was moved." : "Put back \(id) in \(ec2.place): \(restored.joined(separator: "; "))."
            if !cleaned.isEmpty { text += " Removed the leftover records of \(GoogleCloud.listed(cleaned)), already put back." }
            if !remaining.isEmpty { text += " Could not remove \(remaining.joined(separator: "; ")): remove the tag in the EC2 console, or run unisolate-instance again." }
            if !left.isEmpty { text += " Left as it is: \(left.joined(separator: "; ")); set its groups in the EC2 console." }
            text += " Pion's group \(found.id) stays, empty; delete it in the EC2 console when no longer needed."
            return try ServiceResult(text: text, structured: AWS.fields(["instance": id, "restored": restored, "left": left, "remainingRecords": remaining, "cleaned": cleaned]))
        }
    }

    struct DetachInstanceProfile: ServiceOperation {
        typealias Input = InstanceInput
        static let name = "detach-instance-profile"
        static let summary = "Take an instance's IAM role away by removing its instance profile, saying which it was so it can be put back. Credentials the instance already took stay good until they expire, so quarantine the role too."
        static let input = AWS.instanceInput
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try AWS.instanceID(input.instanceId)
            let ec2 = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            _ = try await AWS.instance(ec2, id)
            let listed = try await AWS.read("the instance's profile", needs: ["ec2:DescribeIamInstanceProfileAssociations"]) {
                try await AWS.ec2(ec2, "DescribeIamInstanceProfileAssociations", ["Filter.1.Name": "instance-id", "Filter.1.Value.1": id])
            }
            guard let association = listed.child("iamInstanceProfileAssociationSet")?.children.first(where: { $0.value("state") == "associated" && $0.value("instanceId") == id }),
                  let associationID = association.value("associationId") else {
                return try ServiceResult(text: "\(id) in \(ec2.place) has no instance profile; nothing was changed.", structured: ["instance": id, "changed": "false"])
            }
            let profile = association.value("iamInstanceProfile", "arn") ?? "?"
            do { _ = try await AWS.change(ec2, "DisassociateIamInstanceProfile", ["AssociationId": associationID]) }
            catch { throw AWS.partly([], "removing the profile failed: \(AWS.fix(for: error, needs: ["ec2:DisassociateIamInstanceProfile"]) ?? error.localizedDescription)", undo: "") }
            return try ServiceResult(text: "Removed instance profile \(profile) from \(id) in \(ec2.place). Credentials it already took stay good until they expire, up to hours: quarantine-principal on its role stops them. Put the profile back in the EC2 console's Security › Modify IAM role.",
                                     structured: ["instance": id, "account": ec2.account.id, "instanceProfile": profile])
        }
    }

    struct StopInstance: ServiceOperation {
        typealias Input = InstanceInput
        static let name = "stop-instance"
        static let summary = "Stop an instance, ending everything running on it and what is only in its memory; its volumes stay. Snapshot them first with snapshot-volumes. Start it again in the EC2 console."
        static let input = AWS.instanceInput
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try AWS.instanceID(input.instanceId)
            let ec2 = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            let instance = try await AWS.instance(ec2, id)
            guard ["running", "pending"].contains(instance.state) else {
                return try ServiceResult(text: "\(id) in \(ec2.place) is \(instance.state); nothing was changed.", structured: ["instance": id, "state": instance.state, "changed": "false"])
            }
            let answer: XMLNode
            do { answer = try await AWS.change(ec2, "StopInstances", ["InstanceId.1": id]) }
            catch { throw AWS.partly([], "stopping it failed: \(AWS.fix(for: error, needs: ["ec2:StopInstances"]) ?? error.localizedDescription)", undo: "") }
            let state = answer.all("currentState").first?.value("name") ?? "stopping"
            return try ServiceResult(text: "Stopping \(id) in \(ec2.place): it was \(instance.state) and is now \(state). Start it again in the EC2 console to undo; what was only in its memory is gone.",
                                     structured: ["instance": id, "account": ec2.account.id, "before": instance.state, "after": state])
        }
    }

    struct SnapshotVolumes: ServiceOperation {
        struct Input: Decodable, Sendable { let instanceId: String, notes: String?, region: String?, account: String? }
        static let name = "snapshot-volumes"
        static let summary = "Snapshot every EBS volume of an instance at the same moment, as evidence before it is changed or stopped, each tagged pion-evidence with the instance's ID."
        static let input = JSONSchema.object([
            "instanceId": .string("The instance's ID."), "notes": .string("Why, kept in the snapshots' description, up to 200 characters."),
            "region": .string("Its region, when not the connection's default."), "account": .string("The account it is in, by its ID or name."),
        ], required: ["instanceId"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try AWS.instanceID(input.instanceId)
            let notes = try input.notes.map { try ServiceInput.quoted($0, "notes") } ?? "taken during an investigation"
            let ec2 = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            _ = try await AWS.instance(ec2, id)
            let answer = try await AWS.read("snapshotting the volumes", needs: ["ec2:CreateSnapshots", "ec2:CreateTags"]) {
                try await AWS.change(ec2, "CreateSnapshots", ["InstanceSpecification.InstanceId": id, "Description": "Pion evidence of \(id): \(notes)",
                                                              "CopyTagsFromSource": "volume", "TagSpecification.1.ResourceType": "snapshot",
                                                              "TagSpecification.1.Tag.1.Key": AWS.evidenceTag, "TagSpecification.1.Tag.1.Value": id])
            }
            let snapshots = (answer.child("snapshotSet")?.children ?? []).compactMap { item in
                item.value("snapshotId").map { "\($0) of \(item.value("volumeId") ?? "?")" }
            }
            return try ServiceResult(text: snapshots.isEmpty ? "EC2 made no snapshots of \(id): it may have no EBS volumes." : "Snapshotting \(id)'s volumes in \(ec2.place): \(snapshots.joined(separator: ", ")). They finish in the background.",
                                     structured: AWS.fields(["instance": id, "account": ec2.account.id, "snapshots": snapshots]))
        }
    }

    struct ProtectInstance: ServiceOperation {
        typealias Input = InstanceInput
        static let name = "protect-instance"
        static let summary = "Stop an instance being terminated, as evidence or a foothold an attacker may try to remove, by turning on its termination protection. Turn it off in the EC2 console."
        static let input = AWS.instanceInput
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try AWS.instanceID(input.instanceId)
            let ec2 = try await AWS.target(.ec2, region: input.region, account: input.account, on: service)
            _ = try await AWS.instance(ec2, id)
            _ = try await AWS.read("protecting the instance", needs: ["ec2:ModifyInstanceAttribute"]) {
                try await AWS.change(ec2, "ModifyInstanceAttribute", ["InstanceId": id, "DisableApiTermination.Value": "true"])
            }
            return try ServiceResult(text: "Turned on termination protection for \(id) in \(ec2.place). Turn it off in the EC2 console to undo.",
                                     structured: ["instance": id, "account": ec2.account.id])
        }
    }
}

// MARK: S3, logging and findings

extension AWS {
    static let blockAll = ["BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"]

    static func blockDocument(namespace: String) -> Data {
        Data(("<PublicAccessBlockConfiguration xmlns=\"\(namespace)\">" + blockAll.map { "<\($0)>true</\($0)>" }.joined() + "</PublicAccessBlockConfiguration>").utf8)
    }

    struct BlockS3PublicAccess: ServiceOperation {
        struct Input: Decodable, Sendable { let bucket: String?, wholeAccount: Bool?, region: String?, account: String? }
        static let name = "block-s3-public-access"
        static let summary = "Turn on all four S3 Block Public Access settings for one bucket, or for the whole account, saying what they were before so they can be set back. Only a bucket the account owns is changed."
        static let input = JSONSchema.object([
            "bucket": .string("The bucket's name alone."), "wholeAccount": .boolean("Block public access for every bucket of the account instead."),
            "region": .string("The bucket's region, when not the connection's default."), "account": .string("The account, by its ID or name."),
        ])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard (input.bucket != nil) != (input.wholeAccount == true) else { throw ServiceError.input("Give a bucket, or wholeAccount true, not both.") }
            if let given = input.bucket {
                let bucket = try AWS.bucket(given)
                let s3 = try await AWS.target(.s3, region: input.region, account: input.account, on: service)
                // S3 refuses either request unless the account named owns the bucket.
                let owner = ["x-amz-expected-bucket-owner": s3.account.id]
                let before = try await previous(s3, [bucket], owner: owner, region: s3.region)
                let body = AWS.blockDocument(namespace: "http://s3.amazonaws.com/doc/2006-03-01/")
                let digest = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
                _ = try await AWS.read("blocking the bucket's public access", needs: ["s3:PutBucketPublicAccessBlock"]) {
                    try await s3.client.data([bucket], query: ["publicAccessBlock": ""], method: "PUT", body: body, contentType: "application/xml",
                                             headers: owner.merging(["Content-MD5": digest]) { $1 })
                }
                return try ServiceResult(text: "Turned on all four Block Public Access settings of bucket \(bucket) in \(s3.place); before, \(before.said). Set them back in the S3 console's Permissions to undo.",
                                         structured: ["bucket": bucket, "account": s3.account.id, "before": before.said])
            }
            let control = try await AWS.target(.s3Control, region: input.region, account: input.account, on: service)
            let headers = ["x-amz-account-id": control.account.id]
            let before = try await previous(control, ["v20180820", "configuration", "publicAccessBlock"], owner: headers, region: control.region)
            _ = try await AWS.read("blocking the account's public access", needs: ["s3:PutAccountPublicAccessBlock"]) {
                try await control.client.data(["v20180820", "configuration", "publicAccessBlock"], method: "PUT",
                                              body: AWS.blockDocument(namespace: "http://awss3control.amazonaws.com/doc/2018-08-20/"), contentType: "application/xml", headers: headers)
            }
            return try ServiceResult(text: "Turned on all four Block Public Access settings for every bucket of \(control.named); before, \(before.said). Set them back in the S3 console's Block Public Access settings for this account to undo.",
                                     structured: ["account": control.account.id, "before": before.said])
        }

        /// The settings as they are, said as text, or none set.
        func previous(_ target: Target, _ path: [String], owner: [String: String], region: String) async throws -> (said: String, settings: [String: String]) {
            let query: [String: String?] = path.count == 1 ? ["publicAccessBlock": ""] : [:]
            let answer = try await AWS.read("the current Block Public Access settings", needs: [path.count == 1 ? "s3:GetBucketPublicAccessBlock" : "s3:GetAccountPublicAccessBlock"]) {
                try await target.client.exchange(path, query: query, headers: owner.merging(["Accept": "application/xml"]) { $1 }, returning: [301, 404])
            }
            if answer.response.statusCode == 301 {
                let elsewhere = answer.response.value(forHTTPHeaderField: "x-amz-bucket-region").flatMap { try? AWS.checkedRegion($0) }
                throw ServiceError.input("Nothing was changed: the bucket is not in \(region)\(elsewhere.map { "; it is in \($0), so give region \($0)" } ?? "; give its region").")
            }
            if answer.response.statusCode == 404 {
                let reason = ServiceClient.reason(answer.data) ?? ""
                guard reason.contains("NoSuchPublicAccessBlockConfiguration") else {
                    throw ServiceError.input("Nothing was changed: \(path.count == 1 ? "S3 has no bucket \(path[0]) in \(target.named)" : "S3 could not read the account's settings") (\(reason.isEmpty ? "not found" : reason)).")
                }
                return ("none of the settings was on", [:])
            }
            guard let node = XMLNode.parse(answer.data) else { throw ServiceError.unreadable }
            let settings = Dictionary(uniqueKeysWithValues: AWS.blockAll.map { ($0, node.value($0) ?? "false") })
            return (AWS.blockAll.map { "\($0) \(settings[$0]!)" }.joined(separator: ", "), settings)
        }
    }

    struct RestartLogging: ServiceOperation {
        struct Input: Decodable, Sendable { let trail: String?, guardDuty: Bool?, region: String?, account: String? }
        static let name = "restart-logging"
        static let summary = "Start a CloudTrail trail that was stopped, by its ARN, or turn GuardDuty's detector back on in a region."
        static let input = JSONSchema.object([
            "trail": .string("The trail's ARN, such as arn:aws:cloudtrail:eu-west-1:111111111111:trail/org-trail."),
            "guardDuty": .boolean("Turn GuardDuty's suspended detector back on in the region instead."),
            "region": .string("For GuardDuty, the region, when not the connection's default."), "account": .string("The account, by its ID or name."),
        ])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard (input.trail != nil) != (input.guardDuty == true) else { throw ServiceError.input("Give a trail, or guardDuty true, not both.") }
            if let given = input.trail?.trimmingCharacters(in: .whitespaces) {
                let parts = given.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard given.count <= 500, parts.count == 6, parts[0] == "arn", parts[1] == "aws", parts[2] == "cloudtrail", parts[5].hasPrefix("trail/"),
                      parts[5].dropFirst(6).range(of: #"^[A-Za-z0-9._-]{3,128}$"#, options: .regularExpression) != nil else {
                    throw ServiceError.input("Give the trail's ARN, such as arn:aws:cloudtrail:eu-west-1:111111111111:trail/org-trail.")
                }
                let region = try AWS.checkedRegion(parts[3])
                let trail = try await AWS.target(.cloudtrail, region: region, account: input.account, on: service)
                guard parts[4] == trail.account.id else {
                    throw ServiceError.input("Nothing was changed: the trail is in account \(parts[4]), not \(trail.named). Name its own account.")
                }
                _ = try await AWS.read("starting the trail", needs: ["cloudtrail:StartLogging"]) {
                    try await AWS.call(trail, operation: AWS.trailService + "StartLogging", body: ["Name": given])
                }
                let status = try? await AWS.call(trail, operation: AWS.trailService + "GetTrailStatus", body: ["Name": given])
                let logging = status.flatMap { AWS.flag($0["IsLogging"]) }
                return try ServiceResult(text: "Started \(parts[5].dropFirst(6)) in \(trail.place)\(logging == true ? "; it is logging" : logging == false ? "; read again, it is not logging, so check it" : ""). What happened while it was stopped is only in event history, for 90 days.",
                                         structured: ["trail": given, "logging": logging.map { $0 ? "true" : "false" } ?? "unknown"])
            }
            let guardduty = try await AWS.target(.guardduty, region: input.region, account: input.account, on: service)
            guard let detector = try await AWS.detector(guardduty) else {
                throw ServiceError.input("Nothing was changed: GuardDuty has no detector in \(guardduty.place); turn it on in the GuardDuty console.")
            }
            _ = try await AWS.read("turning GuardDuty back on", needs: ["guardduty:UpdateDetector"]) {
                try await AWS.call(guardduty, ["detector", detector], body: ["enable": true])
            }
            return try ServiceResult(text: "Turned GuardDuty's detector \(detector) back on in \(guardduty.place).", structured: ["detector": detector, "account": guardduty.account.id])
        }
    }

    struct FindingsInput: Decodable, Sendable { let findingIds: [String], region: String?, account: String? }
    static let findingsInput = JSONSchema.object([
        "findingIds": .array(.string("A GuardDuty finding's ID, 32 hexadecimal characters, as guardduty-findings lists it."), "Up to 50 findings."),
        "region": .string("Their region, when not the connection's default."), "account": .string("The account whose detector holds them, by its ID or name."),
    ], required: ["findingIds"])

    /// GuardDuty findings that the account's detector in the region holds, each checked before anything changes.
    static func heldFindings(_ input: FindingsInput, on service: ServiceClient) async throws -> (target: Target, detector: String, findings: [GuardDutyFinding]) {
        let ids = try ServiceInput.list(input.findingIds, limit: 50) { value in
            let id = value.trimmingCharacters(in: .whitespaces)
            guard id.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else { throw ServiceError.input("Give each finding's ID as guardduty-findings lists it: 32 hexadecimal characters.") }
            return id
        }
        let target = try await AWS.target(.guardduty, region: input.region, account: input.account, on: service)
        guard let detector = try await AWS.detector(target) else { throw ServiceError.input("Nothing was changed: GuardDuty has no detector in \(target.place).") }
        let found = try await AWS.guardDutyFindings(target, detector: detector, ids: ids)
        let missing = ids.filter { id in !found.contains { $0.id == id } }
        guard missing.isEmpty else {
            throw ServiceError.input("Nothing was changed: \(target.place)'s detector holds no finding \(missing.joined(separator: ", ")). Name the account and region whose detector holds them.")
        }
        return (target, detector, found)
    }

    static func findingList(_ findings: [GuardDutyFinding], own: String) -> String {
        findings.map { "\($0.id) (\($0.type ?? "?")\($0.account.map { $0 != own ? ", of account \($0)" : "" } ?? ""))" }.joined(separator: ", ")
    }

    struct ArchiveGuardDutyFindings: ServiceOperation {
        typealias Input = FindingsInput
        static let name = "archive-guardduty-findings"
        static let summary = "Archive GuardDuty findings, which takes them out of the alert watch, GuardDuty's current findings and responders' views. Reopen them with unarchive-guardduty-findings."
        static let input = AWS.findingsInput
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let held = try await AWS.heldFindings(input, on: service)
            _ = try await AWS.read("archiving the findings", needs: ["guardduty:ArchiveFindings"]) {
                try await AWS.call(held.target, ["detector", held.detector, "findings", "archive"], body: ["findingIds": held.findings.map(\.id)])
            }
            return try ServiceResult(text: "Archived \(held.findings.count) GuardDuty finding\(held.findings.count == 1 ? "" : "s") in \(held.target.place): \(AWS.findingList(held.findings, own: held.target.account.id)). Reopen with unarchive-guardduty-findings.",
                                     structured: AWS.fields(["archived": held.findings.map(\.id), "account": held.target.account.id, "region": held.target.region]))
        }
    }

    struct UnarchiveGuardDutyFindings: ServiceOperation {
        typealias Input = FindingsInput
        static let name = "unarchive-guardduty-findings"
        static let summary = "Reopen archived GuardDuty findings, bringing them back to current findings."
        static let input = AWS.findingsInput
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let held = try await AWS.heldFindings(input, on: service)
            _ = try await AWS.read("reopening the findings", needs: ["guardduty:UnarchiveFindings"]) {
                try await AWS.call(held.target, ["detector", held.detector, "findings", "unarchive"], body: ["findingIds": held.findings.map(\.id)])
            }
            return try ServiceResult(text: "Reopened \(held.findings.count) GuardDuty finding\(held.findings.count == 1 ? "" : "s") in \(held.target.place).",
                                     structured: ["unarchived": held.findings.map(\.id)])
        }
    }

    struct GuardDutyFeedback: ServiceOperation {
        struct Input: Decodable, Sendable { let findingIds: [String], feedback: String, comments: String?, region: String?, account: String? }
        static let name = "guardduty-feedback"
        static let summary = "Tell GuardDuty whether findings were useful, which neither archives nor hides them."
        static let input = JSONSchema.object([
            "findingIds": .array(.string("A GuardDuty finding's ID."), "Up to 50 findings."), "feedback": .string("The feedback.", oneOf: ["USEFUL", "NOT_USEFUL"]),
            "comments": .string("Why, up to 200 characters."), "region": .string("Their region."), "account": .string("The account whose detector holds them."),
        ], required: ["findingIds", "feedback"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let feedback = try ServiceInput.oneOf(input.feedback, ["USEFUL", "NOT_USEFUL"], "feedback")
            let comments = try input.comments.map { try ServiceInput.quoted($0, "comments") }
            let held = try await AWS.heldFindings(FindingsInput(findingIds: input.findingIds, region: input.region, account: input.account), on: service)
            var body: [String: Any] = ["findingIds": held.findings.map(\.id), "feedback": feedback]
            if let comments { body["comments"] = comments }
            _ = try await AWS.read("giving feedback", needs: ["guardduty:UpdateFindingsFeedback"]) {
                try await AWS.call(held.target, ["detector", held.detector, "findings", "feedback"], body: body)
            }
            return try ServiceResult(text: "Marked \(held.findings.count) GuardDuty finding\(held.findings.count == 1 ? "" : "s") \(feedback.lowercased().replacingOccurrences(of: "_", with: " ")) in \(held.target.place).",
                                     structured: AWS.fields(["findings": held.findings.map(\.id), "feedback": feedback]))
        }
    }

    struct WorkflowInput: Decodable, Sendable { let findingIds: [String], status: String, note: String?, region: String?, account: String? }

    /// Security Hub findings the account's hub in the region holds, with the product each came from, as
    /// BatchUpdateFindings needs both.
    static func hubFindings(_ ids: [String], region: String?, account: String?, on service: ServiceClient) async throws -> (target: Target, found: [(id: String, product: String, account: String?)]) {
        let ids = try ServiceInput.list(ids, limit: 20) { value in
            let id = value.trimmingCharacters(in: .whitespaces)
            guard (1...512).contains(id.count), !id.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\"" }) else {
                throw ServiceError.input("Give each finding's ID as securityhub-findings lists it.")
            }
            return id
        }
        let target = try await AWS.target(.securityhub, region: region, account: account, on: service)
        let answer = try await AWS.read("the findings", needs: ["securityhub:GetFindings"]) {
            try await AWS.call(target, ["findings"], body: ["Filters": ["Id": ids.map { ["Value": $0, "Comparison": "EQUALS"] }], "MaxResults": 100])
        }
        let found = AWS.items(answer["Findings"]).compactMap { json -> (id: String, product: String, account: String?)? in
            guard let id = AWS.text(json["Id"]), let product = AWS.text(json["ProductArn"]) else { return nil }
            return (id, product, AWS.text(json["AwsAccountId"]))
        }
        let missing = ids.filter { id in !found.contains { $0.0 == id } }
        guard missing.isEmpty else {
            throw ServiceError.input("Nothing was changed: Security Hub in \(target.place) holds no finding \(missing.joined(separator: ", ")). Name the account and region that hold them.")
        }
        return (target, found)
    }

    static func updateWorkflow(_ input: WorkflowInput, allowed: [String], on service: ServiceClient) async throws -> ServiceResult {
        let status = try ServiceInput.oneOf(input.status, allowed, "status")
        let note = try input.note.map { try ServiceInput.quoted($0, "note", limit: 500) }
        let held = try await hubFindings(input.findingIds, region: input.region, account: input.account, on: service)
        var body: [String: Any] = ["FindingIdentifiers": held.found.map { ["Id": $0.id, "ProductArn": $0.product] }, "Workflow": ["Status": status]]
        body["Note"] = ["Text": note ?? "Set to \(status) by Pion during an investigation.", "UpdatedBy": "Pion"]
        let answer = try await read("updating the findings", needs: ["securityhub:BatchUpdateFindings"]) {
            try await call(held.target, ["findings", "batchupdate"], method: "PATCH", body: body)
        }
        let processed = items(answer["ProcessedFindings"]).compactMap { text($0["Id"]) }
        let failed = items(answer["UnprocessedFindings"]).map { "\(text($0["FindingIdentifier"]?["Id"]) ?? "?") (\(text($0["ErrorMessage"]) ?? text($0["ErrorCode"]) ?? "?"))" }
        var said = "Set \(processed.count) Security Hub finding\(processed.count == 1 ? "" : "s") in \(held.target.place) to \(status)."
        if !failed.isEmpty { said += " Not changed: \(failed.joined(separator: "; "))." }
        return try ServiceResult(text: said, structured: ["processed": processed, "unprocessed": failed, "status": [status]])
    }

    struct SetFindingWorkflow: ServiceOperation {
        typealias Input = WorkflowInput
        static let name = "set-finding-workflow"
        static let summary = "Mark Security Hub findings NEW or NOTIFIED, such as to reopen one or say it is in hand, by their IDs from securityhub-findings. close-findings resolves or suppresses them."
        static let input = JSONSchema.object([
            "findingIds": .array(.string("A finding's ID."), "Up to 20 findings."), "status": .string("The workflow status.", oneOf: ["NEW", "NOTIFIED"]),
            "note": .string("A note kept on the findings, up to 500 characters."), "region": .string("Their region."), "account": .string("The account that holds them."),
        ], required: ["findingIds", "status"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await AWS.updateWorkflow(input, allowed: ["NEW", "NOTIFIED"], on: service)
        }
    }

    /// Resolving or suppressing a finding takes it out of the alert watch and Security Hub's open findings, as an
    /// attacker would want, so it waits for the champion's approval.
    struct CloseFindings: ServiceOperation {
        typealias Input = WorkflowInput
        static let name = "close-findings"
        static let summary = "Resolve or suppress Security Hub findings, which takes them out of the alert watch and Security Hub's open findings. Reopen them with set-finding-workflow."
        static let input = JSONSchema.object([
            "findingIds": .array(.string("A finding's ID."), "Up to 20 findings."),
            "status": .string("RESOLVED for one dealt with, SUPPRESSED for one that is no threat.", oneOf: ["RESOLVED", "SUPPRESSED"]),
            "note": .string("Why, kept on the findings, up to 500 characters."), "region": .string("Their region."), "account": .string("The account that holds them."),
        ], required: ["findingIds", "status"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await AWS.updateWorkflow(input, allowed: ["RESOLVED", "SUPPRESSED"], on: service)
        }
    }
}

// MARK: Checking access

extension AWS {
    /// Reads the permission set's own role and simulates each operation's actions against its policies, saying which
    /// it lacks, and warns when it allows far more.
    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String? }
        static let name = "check-access"
        static let summary = "Simulates each operation's actions against the permission set's own policies in an account and says which it lacks, exactly what to add, whether the optional session revocation is on, and whether it allows far more than containment. It changes nothing."
        static let input = JSONSchema.object(["account": .string("The account, by its ID or name. Needed unless the sign-in covers only one.")])

        /// What each operation needs, and on what: a user, a role, or anything.
        static let needs: [(operation: String, resource: String, actions: [String], optional: Bool)] = [
            ("\(DeactivateAccessKey.name) and \(ReactivateAccessKey.name)", "user", ["iam:ListAccessKeys", "iam:UpdateAccessKey", "iam:TagUser", "iam:UntagUser", "iam:ListUserTags"], false),
            ("\(QuarantinePrincipal.name) and \(ReleasePrincipal.name), for users", "user", ["iam:AttachUserPolicy", "iam:DetachUserPolicy", "iam:ListAttachedUserPolicies", "iam:TagUser", "iam:UntagUser"], false),
            ("\(QuarantinePrincipal.name) and \(ReleasePrincipal.name), for roles", "role", ["iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies", "iam:TagRole", "iam:UntagRole"], false),
            ("\(RevokeRoleSessions.name) and \(RemoveSessionRevocation.name)", "role", ["iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy"], true),
            (DeleteLoginProfile.name, "user", ["iam:GetLoginProfile", "iam:DeleteLoginProfile"], false),
            ("\(IsolateInstance.name) and \(UnisolateInstance.name)", "*", ["ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSecurityGroups", "ec2:CreateSecurityGroup",
                                                                            "ec2:RevokeSecurityGroupEgress", "ec2:CreateTags", "ec2:DeleteTags", "ec2:ModifyNetworkInterfaceAttribute"], false),
            (DetachInstanceProfile.name, "*", ["ec2:DescribeIamInstanceProfileAssociations", "ec2:DisassociateIamInstanceProfile"], false),
            (StopInstance.name, "*", ["ec2:StopInstances"], false),
            (SnapshotVolumes.name, "*", ["ec2:CreateSnapshots"], false),
            (ProtectInstance.name, "*", ["ec2:ModifyInstanceAttribute"], false),
            (BlockS3PublicAccess.name, "*", ["s3:GetBucketPublicAccessBlock", "s3:PutBucketPublicAccessBlock", "s3:GetAccountPublicAccessBlock", "s3:PutAccountPublicAccessBlock"], false),
            (RestartLogging.name, "*", ["cloudtrail:StartLogging", "cloudtrail:GetTrailStatus", "guardduty:UpdateDetector"], false),
            ("\(ArchiveGuardDutyFindings.name), \(UnarchiveGuardDutyFindings.name) and \(GuardDutyFeedback.name)", "*",
             ["guardduty:ListDetectors", "guardduty:GetFindings", "guardduty:ArchiveFindings", "guardduty:UnarchiveFindings", "guardduty:UpdateFindingsFeedback"], false),
            ("\(SetFindingWorkflow.name) and \(CloseFindings.name)", "*", ["securityhub:GetFindings", "securityhub:BatchUpdateFindings"], false),
        ]

        /// What the permission set should never be able to do.
        static let far = ["iam:CreateUser", "iam:CreateAccessKey", "iam:PutUserPolicy", "iam:CreatePolicyVersion", "ec2:TerminateInstances",
                          "ec2:AuthorizeSecurityGroupIngress", "s3:DeleteBucket", "s3:PutBucketPolicy", "kms:ScheduleKeyDeletion", "cloudtrail:StopLogging"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let iam = try await AWS.iamTarget(input.account, on: service)
            var lines = ["In \(iam.named):"]
            let role: String
            do {
                let me = try await iam.at(.sts).client.xml([], query: ["Action": "GetCallerIdentity", "Version": "2011-06-15"])
                let arn = me.value("GetCallerIdentityResult", "Arn") ?? ""
                let parts = arn.split(separator: "/")
                guard arn.contains(":assumed-role/"), parts.count >= 2 else { throw ServiceError.unreadable }
                role = String(parts[1])
                lines.append("✓ Signed in as \(arn)")
            } catch {
                return try ServiceResult(text: (lines + ["✗ Who the role is could not be read: \(error.localizedDescription)"]).joined(separator: "\n"), structured: ["checks": lines])
            }
            let arn: String
            do {
                guard let found = try await AWS.iam(iam, "GetRole", ["RoleName": role]).value("GetRoleResult", "Role", "Arn") else { throw ServiceError.unreadable }
                arn = found
            } catch {
                let fix = AWS.fix(for: error, needs: ["iam:GetRole", "iam:SimulatePrincipalPolicy"]) ?? error.localizedDescription
                lines.append("✗ The permission set's own policies could not be read, so nothing was checked: \(fix)")
                return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
            }
            let account = iam.account.id
            let resources = ["user": "arn:aws:iam::\(account):user/pion-access-check", "role": "arn:aws:iam::\(account):role/pion-access-check", "*": "*"]
            func simulate(_ actions: [String], on resource: String, policy: String = quarantinePolicies["deny-all"]!) async throws -> [String: Bool] {
                var query: [String: String?] = ["Action": "SimulatePrincipalPolicy", "Version": "2010-05-08", "PolicySourceArn": arn,
                                                "ResourceArns.member.1": resource, "ContextEntries.member.1.ContextKeyName": "iam:PolicyARN",
                                                "ContextEntries.member.1.ContextKeyType": "string", "ContextEntries.member.1.ContextKeyValues.member.1": policy]
                for (index, action) in actions.enumerated() { query["ActionNames.member.\(index + 1)"] = action }
                let answer = try await iam.client.xml([], query: query)
                return Dictionary(answer.all("member").compactMap { member in
                    member.value("EvalActionName").map { ($0, member.value("EvalDecision") == "allowed") }
                }, uniquingKeysWith: { $0 || $1 })
            }
            do {
                for need in Self.needs {
                    let allowed = try await simulate(need.actions, on: resources[need.resource]!)
                    let missing = need.actions.filter { allowed[$0] != true }
                    if missing.isEmpty { lines.append("✓ \(need.operation)") }
                    else if need.optional { lines.append("· \(need.operation): off, as the permission set lacks \(missing.joined(separator: ", ")); add the optional statement from Setup Steps to turn it on.") }
                    else { lines.append("✗ \(need.operation): add \(missing.joined(separator: ", ")) to the permission set's inline policy, as Setup Steps give it.") }
                }
                let admin = try await simulate(["iam:AttachRolePolicy", "iam:AttachUserPolicy"], on: "*", policy: "arn:aws:iam::aws:policy/AdministratorAccess")
                let far = try await simulate(Self.far, on: "*").filter(\.value).map(\.key).sorted()
                if admin.values.contains(true) || !far.isEmpty {
                    let said = (admin.values.contains(true) ? ["attaching AdministratorAccess"] : []) + far
                    lines.append("⚠ The permission set allows far more than containment: \(said.joined(separator: ", ")). Give it only the inline policy from Setup Steps.")
                }
            } catch {
                lines.append("✗ The permission set's policies could not be simulated: \(AWS.fix(for: error, needs: ["iam:SimulatePrincipalPolicy"]) ?? error.localizedDescription)")
            }
            lines.append("· What it can do is simulated from its own policies, not tried: service control policies, permission boundaries and resource policies can still refuse an action.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
