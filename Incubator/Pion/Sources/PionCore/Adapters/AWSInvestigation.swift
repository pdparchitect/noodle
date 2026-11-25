import Foundation
import NoodleCore
import NoodleToolConnections

/// AWS Detection's deeper reads, all within its read-only permission set: who could make themselves an administrator and
/// whom each role trusts, how a resource's configuration changed and who changed it, which buckets are open, who holds
/// which Identity Center permission set where, whose credentials are weak or stale, and what Inspector and Macie found.
extension AWS {
    // MARK: Policies

    /// Whether `pattern`, with IAM's * and ? wildcards, matches `value`, ignoring case as IAM does for actions.
    static func wildcard(_ pattern: String, _ value: String) -> Bool {
        let pattern = Array(pattern.lowercased()), value = Array(value.lowercased())
        var p = 0, v = 0, star = -1, mark = 0
        while v < value.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == value[v] { p += 1; v += 1 }
            else if p < pattern.count, pattern[p] == "*" { star = p; mark = v; p += 1 }
            else if star >= 0 { p = star + 1; mark += 1; v = mark }
            else { return false }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// A policy document as a service gives it, JSON or URL-encoded JSON, or nil when it is neither.
    static func policy(_ text: String?) -> JSON? {
        guard let text else { return nil }
        let decoded = text.hasPrefix("%") ? text.removingPercentEncoding ?? text : text
        guard let json = try? JSONDecoder().decode(JSON.self, from: Data(decoded.utf8)), case .object = json else { return nil }
        return json
    }

    /// Whether a policy allows every action on every resource.
    static func allowsEverything(_ document: JSON) -> Bool {
        statements(document).contains { statement in
            text(statement["Effect"]) == "Allow" && strings(statement["Action"]).contains { $0 == "*" || $0 == "*:*" }
                && strings(statement["Resource"]).contains("*")
        }
    }

    /// A statement's conditions: each operator, key and its values.
    static func conditions(_ statement: JSON) -> [(operator: String, key: String, values: [String])] {
        guard case .object(let operators)? = statement["Condition"] else { return [] }
        var said: [(String, String, [String])] = []
        for (name, keys) in operators.sorted(by: { $0.key < $1.key }) {
            guard case .object(let fields) = keys else { continue }
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                let values = strings(value)
                said.append((name, key, values.isEmpty ? text(value).map { [$0] } ?? [] : values))
            }
        }
        return said
    }

    /// Conditions on one short line, such as "aws:PrincipalOrgID StringEquals o-abc".
    static func said(_ conditions: [(operator: String, key: String, values: [String])]) -> String {
        conditions.prefix(4).map { "\($0.key) \($0.operator) \($0.values.prefix(3).joined(separator: ", "))\($0.values.count > 3 ? " …" : "")" }
            .joined(separator: "; ") + (conditions.count > 4 ? "; and \(conditions.count - 4) more" : "")
    }

    /// For each of `actions`, the resources the documents' statements allow it on, leaving out an action a statement
    /// denies on every resource without a condition. A statement allowing everything but some actions, with NotAction,
    /// allows the rest.
    static func grants(_ actions: [String], in documents: [JSON]) -> [String: [String]] {
        var allowed: [String: [String]] = [:], denied = Set<String>()
        for statement in documents.flatMap(statements) {
            let listed = strings(statement["Action"]), excluded = strings(statement["NotAction"])
            let resources = statement["NotResource"] != nil ? ["*"] : strings(statement["Resource"])
            for action in actions {
                let covers = statement["NotAction"] != nil ? !excluded.contains { wildcard($0, action) } : listed.contains { wildcard($0, action) }
                guard covers else { continue }
                switch text(statement["Effect"]) {
                case "Allow": allowed[action, default: []] += resources
                case "Deny" where resources.contains("*") && statement["Condition"] == nil: denied.insert(action)
                default: break
                }
            }
        }
        for action in denied { allowed[action] = nil }
        return allowed
    }

    // MARK: Trust

    /// One party a role's trust policy lets assume it, and why that is a risk, when it is.
    struct Trustee: Encodable { let who: String; let risk: String? }

    /// The conditions that keep a principal of "*" to the organisation, an account or a source.
    static let limitingKeys = ["aws:principalorgid", "aws:principalorgpaths", "aws:principalaccount", "aws:principalarn", "aws:sourceaccount",
                               "aws:sourcearn", "aws:sourceorgid", "aws:sourceorgpaths"]

    /// Who a trust policy lets assume the role: anyone, another account, a service or an identity provider, with
    /// what is risky about each, judged with the statement's conditions: "*" kept to no organisation or account, an
    /// account outside those the sign-in covers, or an identity provider's tokens kept to no subject.
    static func trustees(_ document: JSON?, own: String?, covered: Set<String>) -> [Trustee] {
        guard let document else { return [] }
        var found: [Trustee] = []
        for statement in statements(document) where text(statement["Effect"]) == "Allow" {
            let conditions = Self.conditions(statement)
            let keys = Dictionary(conditions.map { ($0.key.lowercased(), $0.values) }, uniquingKeysWith: { $0 + $1 })
            let principal = statement["Principal"]
            let accounts = principal?.text == "*" ? ["*"] : strings(principal?["AWS"])
            for arn in accounts {
                if arn == "*" {
                    let limiting = conditions.filter { limitingKeys.contains($0.key.lowercased()) }
                    found.append(limiting.isEmpty ? Trustee(who: "anyone", risk: "anyone with an AWS account can assume it: its trust names \"*\" with no organisation or account condition")
                                                  : Trustee(who: "anyone, when \(said(limiting))", risk: nil))
                    continue
                }
                let account = IAMAccess.account(arn)
                if account == own {
                    found.append(Trustee(who: arn.hasSuffix(":root") || arn == own ? "this account's principals that may call sts:AssumeRole on it" : arn, risk: nil))
                } else if covered.contains(account) {
                    found.append(Trustee(who: "another account \(account), which the sign-in covers", risk: nil))
                } else {
                    let external = keys["sts:externalid"] != nil ? "with an external ID" : "with no external ID"
                    found.append(Trustee(who: "another account \(account)", risk: "account \(account), outside the accounts the sign-in covers, can assume it, \(external)"))
                }
            }
            found += strings(principal?["Service"]).map { Trustee(who: $0, risk: nil) }
            for federated in strings(principal?["Federated"]) {
                found.append(Self.federated(federated, keys: keys))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.who).inserted }
    }

    /// An identity provider a role trusts: a SAML provider is the organisation's own sign-in; an OIDC provider's tokens,
    /// such as GitHub's, must be kept to a subject, or any repository or user of that provider can assume the role.
    static func federated(_ provider: String, keys: [String: [String]]) -> Trustee {
        if provider.contains(":saml-provider/") {
            return Trustee(who: "SAML provider \(provider.components(separatedBy: ":saml-provider/").last ?? provider)", risk: nil)
        }
        let name = provider.components(separatedBy: ":oidc-provider/").last ?? provider
        let lower = name.lowercased()
        if lower == "cognito-identity.amazonaws.com" {
            return keys["cognito-identity.amazonaws.com:aud"] == nil
                ? Trustee(who: name, risk: "any Cognito identity pool's identities can assume it: its trust has no cognito-identity.amazonaws.com:aud condition")
                : Trustee(who: "\(name) for pool \(keys["cognito-identity.amazonaws.com:aud"]!.joined(separator: ", "))", risk: nil)
        }
        let github = lower == "token.actions.githubusercontent.com"
        guard let subjects = keys[lower + ":sub"], !subjects.isEmpty else {
            return Trustee(who: name, risk: github ? "any GitHub repository's workflows can assume it: its trust has no token.actions.githubusercontent.com:sub condition naming a repository"
                                                   : "any subject of \(name)'s tokens can assume it: its trust has no \(name):sub condition")
        }
        let open = subjects.filter { $0 == "*" || (github && ($0.hasPrefix("repo:*") || $0 == "repo:*")) }
        return Trustee(who: "\(name) for \(subjects.prefix(3).joined(separator: ", "))\(subjects.count > 3 ? " …" : "")",
                       risk: open.isEmpty ? nil : "its \(name):sub condition lets any \(github ? "repository" : "subject") in: \(open.joined(separator: ", "))")
    }

    // MARK: iam-access

    /// Who holds which permissions in an account, from IAM's authorization details, which SecurityAudit may read: each
    /// user with what reaches it through its groups, and each role, with full administrators first; who could make
    /// themselves one, by their policies and, where it may be asked, IAM's policy simulator; and which roles anyone,
    /// accounts outside the sign-in's or an identity provider's tokens for any subject could assume.
    struct IAMAccess: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String? }
        static let name = "iam-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Who holds which permissions in an account: each IAM user, with its groups' policies, and each role, with who can assume it; full administrators first, then who could make themselves one (iam:PassRole with Lambda, EC2 or CloudFormation, policy versions, attaching or writing policies, trust changes, other users' keys or passwords, assuming an administrator role), by their policies, with IAM's policy simulator's answer for each action and what it was asked; and roles that anyone, accounts outside the sign-in's or an identity provider's tokens for any subject, such as any GitHub repository, could assume. Says when the account had more than was read."
        static let input = JSONSchema.object(["account": AWS.accountInput])

        /// IAM's policy simulator's answer for one action, and what it was asked about.
        struct Simulation: Encodable {
            let action: String, decision: String
            /// The resources it was asked about: every resource, "*", as no particular one is known.
            let resources: [String]
            /// Whether service control policies and the permission boundary allowed it, when the simulator says; nil when it does not.
            let allowedByOrganizations: Bool?, allowedByBoundary: Bool?
        }

        struct Path: Encodable {
            let actions: [String], how: String
            /// The simulator's answer for each action alone, when it was asked; it judges no path as a whole.
            var simulations: [Simulation]?
        }

        struct Principal: Encodable {
            let kind: String, name: String, arn: String?
            let policies: [String]
            let fullAdministrator: Bool
            /// For a role: who may become it, as its trust policy says.
            var assumableBy: [String] = []
            /// For a role: what about its trust lets in more than the organisation's own.
            var trustRisks: [String] = []
            /// Ways it could make itself, or another, an administrator.
            var escalation: [Path] = []
            /// Policies attached whose documents were not among those read, so what they allow is not known.
            var unknownPolicies: [String] = []
            /// Whether every policy it holds was read, so its paths and whether it is an administrator are judged in full.
            var policiesRead: Bool { unknownPolicies.isEmpty }
        }

        /// A way to more power: every action of it, and what it lets the holder do.
        struct Escalation { let actions: [String]; let how: String; var othersOnly = false }

        static let escalations: [Escalation] = [
            .init(actions: ["iam:CreatePolicyVersion"], how: "rewrite a managed policy, such as one it holds, to allow anything"),
            .init(actions: ["iam:SetDefaultPolicyVersion"], how: "switch a managed policy to another of its versions"),
            .init(actions: ["iam:AttachUserPolicy"], how: "attach any managed policy, AdministratorAccess included, to a user"),
            .init(actions: ["iam:AttachGroupPolicy"], how: "attach any managed policy to a group"),
            .init(actions: ["iam:AttachRolePolicy"], how: "attach any managed policy to a role"),
            .init(actions: ["iam:PutUserPolicy"], how: "write an inline policy allowing anything on a user"),
            .init(actions: ["iam:PutGroupPolicy"], how: "write an inline policy allowing anything on a group"),
            .init(actions: ["iam:PutRolePolicy"], how: "write an inline policy allowing anything on a role"),
            .init(actions: ["iam:AddUserToGroup"], how: "add a user to a more powerful group"),
            .init(actions: ["iam:UpdateAssumeRolePolicy", "sts:AssumeRole"], how: "make a more powerful role trust it, then assume it"),
            .init(actions: ["iam:CreateAccessKey"], how: "make access keys for other users", othersOnly: true),
            .init(actions: ["iam:CreateLoginProfile"], how: "give another user a console password", othersOnly: true),
            .init(actions: ["iam:UpdateLoginProfile"], how: "change another user's console password", othersOnly: true),
            .init(actions: ["iam:PassRole", "lambda:CreateFunction", "lambda:InvokeFunction"], how: "run code in Lambda as a more powerful role"),
            .init(actions: ["iam:PassRole", "ec2:RunInstances"], how: "start an instance with a more powerful role"),
            .init(actions: ["iam:PassRole", "cloudformation:CreateStack"], how: "have CloudFormation act as a more powerful role"),
        ]

        static let pages = 20
        /// The most principals asked about in IAM's policy simulator, one request each.
        static let simulated = 20

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (account, signed) = try await AWS.account(input.account, on: service)
            let covered = Set(try await service.access.awsAccounts().map(\.id))
            let iam = try Target(client: signed, account: account, region: "us-east-1", service: .iam).at(.iam)
            var users: [XMLNode] = [], groups: [XMLNode] = [], roles: [XMLNode] = [], managed: [XMLNode] = []
            var marker: String?, truncated = false
            // An account answers in pages; a few cover any but the largest. AWS managed policies come only when attached.
            for page in 0..<Self.pages {
                var query: [String: String?] = ["Action": "GetAccountAuthorizationDetails", "Version": "2010-05-08", "MaxItems": "1000",
                                                "Filter.member.1": "User", "Filter.member.2": "Group", "Filter.member.3": "Role",
                                                "Filter.member.4": "LocalManagedPolicy", "Filter.member.5": "AWSManagedPolicy"]
                if let marker { query["Marker"] = marker }
                let answer = try await AWS.read("IAM's authorization details", needs: ["iam:GetAccountAuthorizationDetails"]) { try await iam.client.xml([], query: query) }
                guard let result = answer.child("GetAccountAuthorizationDetailsResult") else { throw ServiceError.unreadable }
                users += result.child("UserDetailList")?.children ?? []
                groups += result.child("GroupDetailList")?.children ?? []
                roles += result.child("RoleDetailList")?.children ?? []
                managed += result.child("Policies")?.children ?? []
                guard result.value("IsTruncated") == "true", let next = result.value("Marker") else { marker = nil; break }
                marker = next
                if page == Self.pages - 1 { truncated = true }
            }
            // A managed policy grants what its default version says.
            let documents: [String: JSON] = Dictionary(managed.compactMap { policy in
                let document = policy.child("PolicyVersionList")?.children.first { $0.value("IsDefaultVersion") == "true" }?.value("Document")
                return policy.value("Arn").flatMap { arn in AWS.policy(document).map { (arn, $0) } }
            }, uniquingKeysWith: { first, _ in first })
            struct Held { let name: String; let document: JSON?; let everything: Bool; let unknown: Bool }
            func attached(_ node: XMLNode) -> [Held] {
                (node.child("AttachedManagedPolicies")?.children ?? []).compactMap { policy in
                    guard let name = policy.value("PolicyName") else { return nil }
                    let arn = policy.value("PolicyArn") ?? "", document = documents[arn]
                    return Held(name: name, document: document, everything: arn.hasSuffix(":policy/AdministratorAccess") || document.map(AWS.allowsEverything) == true,
                                unknown: document == nil && !arn.hasSuffix(":policy/AdministratorAccess"))
                }
            }
            func inline(_ node: XMLNode, _ list: String) -> [Held] {
                (node.child(list)?.children ?? []).compactMap { policy in
                    guard let name = policy.value("PolicyName") else { return nil }
                    let document = AWS.policy(policy.value("PolicyDocument"))
                    return Held(name: "\(name) (inline)", document: document, everything: document.map(AWS.allowsEverything) ?? false, unknown: document == nil)
                }
            }
            let groupPolicies = Dictionary(groups.compactMap { group in
                group.value("GroupName").map { ($0, attached(group) + inline(group, "GroupPolicyList")) }
            }, uniquingKeysWith: { first, _ in first })
            var held: [String: [Held]] = [:]
            var principals = users.compactMap { user -> Principal? in
                guard let name = user.value("UserName") else { return nil }
                let through = (user.child("GroupList")?.children ?? []).compactMap { $0.text.isEmpty ? nil : $0.text }.flatMap { group in
                    (groupPolicies[group] ?? []).map { Held(name: "\($0.name) (through group \(group))", document: $0.document, everything: $0.everything, unknown: $0.unknown) }
                }
                let all = attached(user) + inline(user, "UserPolicyList") + through
                held["user/" + name] = all
                return Principal(kind: "user", name: name, arn: user.value("Arn"), policies: all.map(\.name), fullAdministrator: all.contains { $0.everything },
                                 unknownPolicies: all.filter(\.unknown).map(\.name))
            }
            var trusts: [String: JSON] = [:]
            principals += roles.compactMap { role in
                guard let name = role.value("RoleName") else { return nil }
                let all = attached(role) + inline(role, "RolePolicyList")
                held["role/" + name] = all
                let trust = AWS.policy(role.value("AssumeRolePolicyDocument"))
                trusts[name] = trust
                let trustees = AWS.trustees(trust, own: account.id, covered: covered)
                return Principal(kind: "role", name: name, arn: role.value("Arn"), policies: all.map(\.name), fullAdministrator: all.contains { $0.everything },
                                 assumableBy: trustees.map(\.who), trustRisks: trustees.compactMap(\.risk), unknownPolicies: all.filter(\.unknown).map(\.name))
            }

            // Who could make themselves an administrator, by what their policies allow.
            let actions = Array(Set(Self.escalations.flatMap(\.actions))).sorted()
            let adminRoles = principals.filter { $0.kind == "role" && $0.fullAdministrator }
            for index in principals.indices where !principals[index].fullAdministrator {
                let principal = principals[index]
                let granted = AWS.grants(actions, in: (held["\(principal.kind)/\(principal.name)"] ?? []).compactMap(\.document))
                var paths: [Path] = []
                for escalation in Self.escalations where escalation.actions.allSatisfy({ granted[$0] != nil }) {
                    if escalation.othersOnly, !escalation.actions.contains(where: { action in
                        (granted[action] ?? []).contains { $0 != principal.arn && !$0.contains("${aws:username}") }
                    }) { continue }
                    paths.append(Path(actions: escalation.actions, how: escalation.how))
                }
                // An administrator role whose trust names this principal, or its account when its policies allow assuming it.
                for role in adminRoles where role.arn != principal.arn {
                    guard let roleArn = role.arn, let trust = trusts[role.name] else { continue }
                    let named = AWS.statements(trust).filter { AWS.text($0["Effect"]) == "Allow" }.flatMap { AWS.strings($0["Principal"]?["AWS"]) }
                    let direct = principal.arn.map { named.contains($0) } ?? false
                    let throughAccount = named.contains { $0 == account.id || $0 == "arn:aws:iam::\(account.id):root" }
                        && (granted["sts:AssumeRole"] ?? []).contains { AWS.wildcard($0, roleArn) }
                    if direct || throughAccount {
                        paths.append(Path(actions: ["sts:AssumeRole"], how: "assume the administrator role \(role.name)\(direct ? ", whose trust names it" : "")"))
                    }
                }
                principals[index].escalation = paths
            }

            // IAM's policy simulator counts permission boundaries and SCPs, which the policies alone do not.
            var asked = 0, unasked = 0, simulator: String?
            for index in principals.indices where !principals[index].escalation.isEmpty {
                guard let arn = principals[index].arn, simulator == nil, asked < Self.simulated else { unasked += 1; continue }
                asked += 1
                do {
                    let decisions = try await Self.simulate(iam, arn: arn, actions: Array(Set(principals[index].escalation.flatMap(\.actions))).sorted())
                    for path in principals[index].escalation.indices {
                        principals[index].escalation[path].simulations = principals[index].escalation[path].actions.map { action in
                            decisions[action] ?? Simulation(action: action, decision: "not answered", resources: ["*"], allowedByOrganizations: nil, allowedByBoundary: nil)
                        }
                    }
                } catch {
                    simulator = AWS.fix(for: error, needs: ["iam:SimulatePrincipalPolicy"]) ?? error.localizedDescription
                    unasked += 1
                }
            }

            let admins = principals.filter(\.fullAdministrator), others = principals.filter { !$0.fullAdministrator }
            func allowed(_ principal: Principal) -> Bool { principal.escalation.contains { $0.simulations?.allSatisfy { $0.decision == "allowed" } == true } }
            let escalating = others.filter { !$0.escalation.isEmpty }.sorted { (allowed($0) ? 0 : 1) < (allowed($1) ? 0 : 1) }
            let opened = principals.filter { !$0.trustRisks.isEmpty }
            func line(_ principal: Principal) -> String {
                "\(principal.kind) \(principal.name): \(principal.policies.isEmpty ? "no policies" : principal.policies.joined(separator: ", "))"
                    + (principal.assumableBy.isEmpty ? "" : "; assumable by " + principal.assumableBy.joined(separator: ", "))
                    + (principal.policiesRead ? "" : "; \(principal.unknownPolicies.count) of its policies could not be read, so what it may do is not fully known")
            }
            func path(_ path: Path) -> String {
                var said = "\(path.how) (\(path.actions.joined(separator: " with "))), by its policies"
                if let simulations = path.simulations {
                    said += "; the policy simulator, per action on resource *: " + simulations.map { simulation in
                        var scope: [String] = []
                        if let organizations = simulation.allowedByOrganizations { scope.append("SCPs \(organizations ? "allow" : "deny")") }
                        if let boundary = simulation.allowedByBoundary { scope.append("boundary \(boundary ? "allows" : "denies")") }
                        return "\(simulation.action) \(simulation.decision)" + (scope.isEmpty ? "" : " (\(scope.joined(separator: ", ")))")
                    }.joined(separator: ", ")
                }
                return said
            }
            var text = ["In \(iam.named):", "Full administrators (\(admins.count)):"] + admins.map { "- " + line($0) }
            text += ["Could make themselves administrators (\(escalating.count)):"] + escalating.prefix(50).map { principal in
                "- \(principal.kind) \(principal.name): " + principal.escalation.map(path).joined(separator: "; ")
            }
            if escalating.count > 50 { text.append("\(escalating.count - 50) more; read them from the structured result.") }
            text += ["Roles others could assume (\(opened.count)):"] + opened.prefix(50).map { "- role \($0.name): " + $0.trustRisks.joined(separator: "; ") }
            text += ["Everyone else (\(others.count)):"] + others.prefix(100).map { "- " + line($0) }
            if others.count > 100 { text.append("\(others.count - 100) more; read them from the structured result.") }
            if truncated {
                text.append("Stopped after \(Self.pages) pages of the account's authorization details with more remaining, so users, groups and roles past them are missing.")
            }
            if let simulator { text.append("IAM's policy simulator could not be asked (\(simulator)), so these paths are by the policies alone.") }
            else if unasked > 0 { text.append("IAM's policy simulator was asked about the first \(asked); \(unasked) more are by their policies alone.") }
            let unknown = Set(principals.flatMap(\.unknownPolicies))
            if !unknown.isEmpty { text.append("\(unknown.count) policies could not be read, so what they allow is not counted: \(unknown.sorted().prefix(10).joined(separator: ", ")).") }
            if asked > 0 {
                text.append("What the simulator was asked: each action alone, for the principal on resource *, with its identity policies; it says whether SCPs and a permission boundary allowed an action only where noted. It does not judge resource policies, which role would be passed or whether that role is more powerful, or a path as a whole, so \"allowed\" for every action of a path is not proof the path works, and \"implicitDeny\" on * may still allow it on a particular resource.")
            }
            text.append("Not covered: access through IAM Identity Center permission sets, which identity-center-assignments lists; resource policies; and which resources a permission is limited to. A path by the policies alone may be stopped by a resource limit, a condition, a permission boundary or an SCP.")
            struct Kept: Encodable { let principals: [Principal]; let account: String; let complete: Bool; let unreadPolicies: [String] }
            return try ServiceResult(text: text.joined(separator: "\n"), structured: Kept(principals: admins + others, account: account.id,
                                                                                          complete: !truncated && unknown.isEmpty, unreadPolicies: unknown.sorted()))
        }

        /// IAM's policy simulator's answer for each action, for `arn` on every resource: allowed, implicitDeny or
        /// explicitDeny, with what it says of SCPs and the permission boundary.
        static func simulate(_ iam: Target, arn: String, actions: [String]) async throws -> [String: Simulation] {
            var decisions: [String: Simulation] = [:], marker: String?, pages = 0
            repeat {
                var query: [String: String?] = ["Action": "SimulatePrincipalPolicy", "Version": "2010-05-08", "PolicySourceArn": arn]
                for (index, action) in actions.enumerated() { query["ActionNames.member.\(index + 1)"] = action }
                if let marker { query["Marker"] = marker }
                let answer = try await iam.client.xml([], query: query)
                guard let result = answer.child("SimulatePrincipalPolicyResult") else { throw ServiceError.unreadable }
                for member in result.child("EvaluationResults")?.children ?? [] {
                    guard let action = member.value("EvalActionName"), let decision = member.value("EvalDecision") else { throw ServiceError.unreadable }
                    decisions[action] = Simulation(action: action, decision: decision, resources: [member.value("EvalResourceName") ?? "*"],
                                                   allowedByOrganizations: member.value("OrganizationsDecisionDetail", "AllowedByOrganizations").map { $0 == "true" },
                                                   allowedByBoundary: member.value("PermissionsBoundaryDecisionDetail", "AllowedByPermissionsBoundary").map { $0 == "true" })
                }
                marker = result.value("IsTruncated") == "true" ? result.value("Marker") : nil
                pages += 1
            } while marker != nil && pages < 5
            return decisions
        }

        /// The account an ARN is in, its fifth field, after the region that IAM leaves empty; an account ID alone is itself.
        static func account(_ arn: String) -> String {
            let fields = arn.split(separator: ":", omittingEmptySubsequences: false)
            return fields.count > 4 ? String(fields[4]) : arn
        }
    }

    // MARK: config-history

    /// How a resource's configuration changed, from AWS Config's history, each change set against the one before it,
    /// and who made it, from the CloudTrail events on that resource in between.
    struct ConfigHistory: ServiceOperation {
        struct Input: Decodable, Sendable {
            let resourceType: String, resourceId: String, since: String?, until: String?, limit: Int?, region: String?, account: String?
        }
        static let name = "config-history"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "How a resource's configuration changed, from AWS Config's history, newest first: what each change made different from the configuration before it, and who made it, from CloudTrail's event history on that resource between the two, saying plainly when no event matched; and whether Config records that resource type in the region, saying when it does not. Config keeps what a resource looked like, not who changed it, and CloudTrail keeps 90 days."
        static let input = JSONSchema.object([
            "resourceType": .string("The resource's type as AWS Config names it, such as AWS::EC2::SecurityGroup, AWS::S3::Bucket or AWS::IAM::Role."),
            "resourceId": .string("The resource's ID as Config knows it: a security group's sg-…, an instance's i-…, a bucket's name, or an IAM role's or user's unique ID, AROA… or AIDA…."),
            "since": .string("The earliest change, in ISO 8601. The last 30 days when left out."),
            "until": .string("The latest change, in ISO 8601. Now when left out."),
            "limit": .integer("How many changes, at most. 10 when left out.", minimum: 1, maximum: 50),
            "region": .string("The region, when not the connection's default. Config records IAM's resources in one region only."), "account": AWS.accountInput,
        ], required: ["resourceType", "resourceId"])

        /// A configuration laid flat: each value by its path, and each list as a set of its items.
        struct Flat { var values: [String: String] = [:]; var sets: [String: Set<String>] = [:] }

        struct Item {
            let time: Date, status: String, id: String?, name: String?, arn: String?, related: [String]
            let flat: Flat
        }

        /// A CloudTrail event set beside a change, and why: "linked" when Config's item names its event ID, which says who
        /// made the change; "time-and-resource" when it is only a write to the same resource in the interval, a candidate.
        struct Matched: Encodable { let basis: String; let event: CloudTrailEvents.Kept }

        /// An event Config links to a change that could not be read, and why.
        struct Unread: Encodable { let id: String; let reason: String }

        /// The most linked events looked up by ID in one lookup.
        static let linkedLookupLimit = 10

        struct Change: Encodable {
            let time: String, status: String, differences: [String]
            /// The CloudTrail event IDs Config links to it.
            let linkedIDs: [String]
            /// Those of them that could not be read.
            let linkedUnread: [Unread]
            /// The CloudTrail events set beside it, linked ones alone when there are any, newest first.
            let events: [Matched]
            /// The interval searched for candidates: after the configuration before it, up to its capture.
            let window: String
            /// How many candidates there were, of which at most five are kept.
            let candidates: Int
            /// How much of its interval CloudTrail's lookups searched.
            let trailCoverage: TrailCoverage
        }

        /// How much of an interval CloudTrail's lookups on the resource searched: complete, partial, failed or not
        /// searched, with why when not complete.
        struct TrailCoverage: Encodable {
            let state: String, reason: String?
            static let complete = TrailCoverage(state: "complete", reason: nil)
            var rank: Int { ["complete": 0, "partial": 1, "not searched": 2, "failed": 3][state] ?? 3 }
        }

        static let configService = "StarlingDoveService."

        static func item(_ json: JSON) throws -> Item {
            let time = AWS.number(json["configurationItemCaptureTime"]).map { Date(timeIntervalSince1970: $0) }
                ?? ServiceAlert.time(AWS.text(json["configurationItemCaptureTime"]))
            guard let time, let status = AWS.text(json["configurationItemStatus"]) else { throw ServiceError.unreadable }
            var flat = Flat()
            flatten(json["configuration"], "", into: &flat)
            flatten(json["supplementaryConfiguration"], "supplementaryConfiguration", into: &flat)
            flatten(json["tags"], "tags", into: &flat)
            let relationships = AWS.items(json["relationships"]).compactMap { relation -> String? in
                guard let kind = AWS.text(relation["relationshipName"]) else { return nil }
                return "\(kind) \(AWS.text(relation["resourceId"]) ?? AWS.text(relation["resourceName"]) ?? "?")"
            }
            if !relationships.isEmpty { flat.sets["relationships"] = Set(relationships) }
            return Item(time: time, status: status, id: AWS.text(json["resourceId"]), name: AWS.text(json["resourceName"]), arn: AWS.text(json["arn"]),
                        related: AWS.items(json["relatedEvents"]).compactMap(\.text), flat: flat)
        }

        /// Lays `json` flat under `path`, reading JSON that Config gives as a string, such as a bucket's policy, as JSON.
        static func flatten(_ json: JSON?, _ path: String, into flat: inout Flat, depth: Int = 0) {
            guard depth < 16, let json else { return }
            switch json {
            case .object(let fields):
                for (key, value) in fields { flatten(value, path.isEmpty ? key : "\(path).\(key)", into: &flat, depth: depth + 1) }
            case .array(let items):
                flat.sets[path] = Set(items.map(canonical))
            case .string(let text):
                if text.hasPrefix("{") || text.hasPrefix("%7B"), let inner = AWS.embedded(json), case .object = inner {
                    flatten(inner, path, into: &flat, depth: depth + 1)
                } else { flat.values[path] = text }
            case .null: break
            default: flat.values[path] = json.compact()
            }
        }

        /// A value as one line of JSON with its keys in order, so the same item reads the same each time.
        static func canonical(_ json: JSON) -> String {
            if case .string(let text) = json { return text }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(json)).flatMap { String(data: $0, encoding: .utf8) } ?? json.compact()
        }

        static func short(_ text: String) -> String {
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return line.count > 160 ? String(line.prefix(159)) + "…" : line
        }

        /// What differs from `before` to `after`, one line each.
        static func differences(_ before: Flat, _ after: Flat) -> [String] {
            var lines: [String] = []
            for key in Set(before.values.keys).union(after.values.keys).sorted() {
                switch (before.values[key], after.values[key]) {
                case let (old?, new?) where old != new: lines.append("\(key): \(short(old)) → \(short(new))")
                case let (nil, new?): lines.append("\(key): set to \(short(new))")
                case let (old?, nil): lines.append("\(key): removed (was \(short(old)))")
                default: break
                }
            }
            for key in Set(before.sets.keys).union(after.sets.keys).sorted() {
                let old = before.sets[key] ?? [], new = after.sets[key] ?? []
                lines += new.subtracting(old).sorted().map { "\(key): added \(short($0))" }
                lines += old.subtracting(new).sorted().map { "\(key): removed \(short($0))" }
            }
            return lines
        }

        /// Whether Config records `type` in the target's region, said for the result; nil when that could not be read.
        static func coverage(_ config: Target, type: String) async -> (records: Bool?, said: String) {
            do {
                let recorders = AWS.items(try await AWS.call(config, operation: configService + "DescribeConfigurationRecorders", body: [:])["ConfigurationRecorders"])
                let statuses = AWS.items(try await AWS.call(config, operation: configService + "DescribeConfigurationRecorderStatus", body: [:])["ConfigurationRecordersStatus"])
                guard let recorder = recorders.first else {
                    return (false, "AWS Config has no configuration recorder in \(config.place), so it records nothing there.")
                }
                guard statuses.contains(where: { AWS.flag($0["recording"]) == true }) else {
                    return (false, "AWS Config's recorder in \(config.place) is stopped, so changes since it stopped are not recorded.")
                }
                let group = recorder["recordingGroup"]
                let strategy = AWS.text(group?["recordingStrategy"]?["useOnly"])
                let listed = AWS.strings(group?["resourceTypes"]), excluded = AWS.strings(group?["exclusionByResourceTypes"]?["resourceTypes"])
                let global = type.hasPrefix("AWS::IAM::")
                let records: Bool
                switch strategy {
                case "INCLUSION_BY_RESOURCE_TYPES"?: records = listed.contains(type)
                case "EXCLUSION_BY_RESOURCE_TYPES"?: records = !excluded.contains(type) && !global
                default:
                    records = AWS.flag(group?["allSupported"]) == false ? listed.contains(type)
                        : !global || AWS.flag(group?["includeGlobalResourceTypes"]) == true
                }
                if records { return (true, "AWS Config is recording \(type) in \(config.place).") }
                return (false, global ? "AWS Config in \(config.place) does not record IAM's resource types, which are global and recorded in one region only: name the region that records them."
                                      : "AWS Config in \(config.place) is recording, but not \(type), so its changes are not kept.")
            } catch {
                return (nil, "Whether AWS Config records \(type) in \(config.place) was not checked: \(AWS.fix(for: error, needs: ["config:DescribeConfigurationRecorders", "config:DescribeConfigurationRecorderStatus"]) ?? error.localizedDescription)")
            }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let type = input.resourceType.trimmingCharacters(in: .whitespaces)
            guard type.count <= 100, type.range(of: #"^AWS::[A-Za-z0-9]+::[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
                throw ServiceError.input("Give the resource type as AWS Config names it, such as AWS::EC2::SecurityGroup.")
            }
            let id = try ServiceInput.quoted(input.resourceId, "the resource's ID", limit: 768)
            guard !id.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { throw ServiceError.input("Give the resource's ID alone.") }
            let window = try AWS.window(input.since, input.until, days: 30)
            let limit = try AWS.limit(input.limit, default: 10, maximum: 50)
            let config = try await AWS.target(.config, region: input.region, account: input.account, on: service)
            let coverage = await Self.coverage(config, type: type)

            // Newest first, one more than kept, so the oldest kept has the one before it to differ from.
            var items: [Item] = [], token: String?, pages = 0
            do {
                repeat {
                    var body: [String: Any] = ["resourceType": type, "resourceId": id, "earlierTime": Int(window.since.timeIntervalSince1970),
                                               "laterTime": Int(window.until.timeIntervalSince1970.rounded(.up)), "chronologicalOrder": "Reverse", "limit": min(100, limit + 1)]
                    if let token { body["nextToken"] = token }
                    let answer = try await AWS.read("AWS Config's history", needs: ["config:GetResourceConfigHistory"]) {
                        try await AWS.call(config, operation: Self.configService + "GetResourceConfigHistory", body: body)
                    }
                    guard case .object = answer, answer["configurationItems"].map({ if case .array = $0 { true } else { false } }) != false else { throw ServiceError.unreadable }
                    pages += 1
                    items += try AWS.items(answer["configurationItems"]).map(Self.item)
                    token = AWS.text(answer["nextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                } while token != nil && items.count <= limit && pages < AWS.maximumPages
            } catch ServiceError.refused(let reason) where reason.contains("ResourceNotDiscovered") {
                return try ServiceResult(text: "AWS Config has no record of \(type) \(id) in \(config.place). \(coverage.said) It may be in another region or account, be known to Config by another ID, or not have existed while Config recorded.",
                                         structured: AWS.fields(["changes": [String](), "account": config.account.id, "region": config.region, "recorded": "false"]))
            }
            let more = items.count > limit || token != nil
            let kept = Array(items.prefix(limit))
            // What it was before the oldest kept, when the window holds nothing older.
            var baseline: Item? = items.count > limit ? items[limit] : nil, notes: [String] = []
            if baseline == nil, let oldest = kept.last {
                do {
                    let answer = try await AWS.call(config, operation: Self.configService + "GetResourceConfigHistory", body: [
                        "resourceType": type, "resourceId": id, "laterTime": Int(oldest.time.timeIntervalSince1970) - 1, "chronologicalOrder": "Reverse", "limit": 1])
                    baseline = try AWS.items(answer["configurationItems"]).first.map(Self.item)
                } catch {
                    notes.append("The configuration before \(AWS.iso(oldest.time)) could not be read (\(error.localizedDescription)), so the oldest change is shown as it was recorded.")
                }
            }
            let previous = kept.indices.map { index in index + 1 < kept.count ? kept[index + 1] : baseline }

            // Who: CloudTrail's write events on the resource, by each name it may be logged under, across every change's window.
            let trailRegion = type.hasPrefix("AWS::IAM::") ? "us-east-1" : config.region
            let floor = Date().addingTimeInterval(-AWS.cloudTrailDays * 86_400 + 120)
            var events: [CloudTrailEvents.Kept] = [], trailFailed: String?, unreadLinked: [String: String] = [:]
            // LookupEvents reads newest first: a lookup cut short searched back only to the oldest event it read.
            var searchedBack: Date?
            let allLinked = Array(Set(kept.flatMap(\.related))).sorted()
            // A change was made after the configuration before it and by the time Config captured it, never after.
            let windows = kept.indices.map { index in (from: previous[index]?.time ?? kept[index].time.addingTimeInterval(-86_400), to: kept[index].time) }
            if let start = windows.map(\.from).min(), let end = windows.map(\.to).max(), end > floor {
                let names = Array(NSOrderedSet(array: [id] + kept.compactMap(\.name) + kept.compactMap(\.arn))) as? [String] ?? [id]
                do {
                    let trail = try config.at(.cloudtrail, region: trailRegion)
                    for name in names.prefix(3) {
                        var next: String?, read = 0, oldest: Date?
                        repeat {
                            var body: [String: Any] = ["LookupAttributes": [["AttributeKey": "ResourceName", "AttributeValue": name]], "MaxResults": 50,
                                                       "StartTime": Int(max(start, floor).timeIntervalSince1970), "EndTime": Int(min(end, Date()).timeIntervalSince1970.rounded(.up))]
                            if let next { body["NextToken"] = next }
                            let answer = try AWS.decode(CloudTrailEvents.Answer.self, try await AWS.send(trail, operation: AWS.lookupEvents, body: body))
                            read += 1
                            let page = (answer.Events ?? []).map { CloudTrailEvents.kept($0, region: trailRegion) }
                            if let last = page.map(\.date).min() { oldest = min(oldest ?? last, last) }
                            events += page.filter { $0.readOnly != true && $0.error == nil }
                            next = answer.NextToken.flatMap { $0.isEmpty ? nil : $0 }
                        } while next != nil && read < 4
                        if next != nil {
                            let reached = oldest ?? end
                            searchedBack = max(searchedBack ?? reached, reached)
                        }
                    }
                } catch {
                    trailFailed = "CloudTrail's event history in \(trailRegion) could not be searched: \(AWS.fix(for: error, needs: ["cloudtrail:LookupEvents"]) ?? error.localizedDescription)"
                    notes.append("\(trailFailed!), so who made each change is not known from it.")
                }
                // An event Config links to a change is read by its ID when the resource's own lookups did not bring it,
                // up to a limit; each one not read says why.
                let have = Set(events.compactMap(\.id))
                var refused: String?
                for (index, linked) in allLinked.filter({ !have.contains($0) }).enumerated() {
                    guard index < Self.linkedLookupLimit else { unreadLinked[linked] = "the lookup limit of \(Self.linkedLookupLimit) linked events was reached"; continue }
                    if let refused { unreadLinked[linked] = refused; continue }
                    do {
                        let trail = try config.at(.cloudtrail, region: trailRegion)
                        let body: [String: Any] = ["LookupAttributes": [["AttributeKey": "EventId", "AttributeValue": linked]], "MaxResults": 50,
                                                   "StartTime": Int(floor.timeIntervalSince1970), "EndTime": Int(Date().timeIntervalSince1970.rounded(.up))]
                        let answer = try AWS.decode(CloudTrailEvents.Answer.self, try await AWS.send(trail, operation: AWS.lookupEvents, body: body))
                        let found = (answer.Events ?? []).map { CloudTrailEvents.kept($0, region: trailRegion) }.filter { $0.id == linked }
                        if found.isEmpty { unreadLinked[linked] = "CloudTrail's event history in \(trailRegion) does not hold it; it keeps 90 days" }
                        events += found
                    } catch {
                        let reason = "CloudTrail refused or failed: \(AWS.fix(for: error, needs: ["cloudtrail:LookupEvents"]) ?? error.localizedDescription)"
                        unreadLinked[linked] = reason
                        if AWS.isDenied(error) { refused = reason }
                    }
                }
            } else if !kept.isEmpty {
                notes.append("Every change is older than the 90 days CloudTrail's event history keeps, so who made them is not known from it.")
                for linked in allLinked { unreadLinked[linked] = "it is older than the 90 days CloudTrail's event history keeps" }
            }
            var seen = Set<String>()
            events = events.filter { $0.id.map { seen.insert($0).inserted } ?? true }.sorted { $0.date > $1.date }

            // What of each change's interval was searched: all of it, part, none, or nothing, as CloudTrail failed.
            func searched(_ window: (from: Date, to: Date)) -> TrailCoverage {
                if let trailFailed { return TrailCoverage(state: "failed", reason: trailFailed) }
                if window.to <= floor { return TrailCoverage(state: "not searched", reason: "the interval is older than the 90 days CloudTrail's event history keeps") }
                var why: [String] = []
                if window.from < floor { why.append("the part before \(AWS.iso(floor)) is older than the 90 days CloudTrail keeps") }
                if let searchedBack, window.from < searchedBack {
                    why.append("CloudTrail held more events on the resource than were read, so it was searched back only to \(AWS.iso(searchedBack))")
                }
                return why.isEmpty ? .complete : TrailCoverage(state: "partial", reason: why.joined(separator: "; "))
            }
            let changes = kept.indices.map { index -> Change in
                let item = kept[index], window = windows[index]
                let differences = previous[index].map { Self.differences($0.flat, item.flat) } ?? []
                let related = Set(item.related)
                let linked = events.filter { $0.id.map(related.contains) == true }
                let candidates = linked.isEmpty ? events.filter { $0.date > window.from && $0.date <= window.to } : []
                let matched = linked.map { Matched(basis: "linked", event: $0) } + candidates.prefix(5).map { Matched(basis: "time-and-resource", event: $0) }
                let unread = item.related.sorted().compactMap { id in unreadLinked[id].map { Unread(id: id, reason: $0) } }
                return Change(time: AWS.iso(item.time), status: item.status, differences: differences, linkedIDs: item.related.sorted(), linkedUnread: unread,
                              events: matched, window: "\(AWS.iso(window.from)) and \(AWS.iso(window.to))", candidates: candidates.count,
                              trailCoverage: searched(window))
            }
            let named = kept.first?.name.map { $0 != id ? " (\($0))" : "" } ?? ""
            var lines = ["\(type) \(id)\(named) in \(config.place), from \(AWS.iso(window.since)) to \(AWS.iso(window.until)): \(changes.isEmpty ? "no configuration recorded" : "\(changes.count) recorded, newest first").",
                         coverage.said]
            for (index, change) in changes.enumerated() {
                let status: String = switch change.status {
                case "ResourceDiscovered": "first recorded"
                case "ResourceDeleted", "ResourceDeletedNotRecorded": "deleted"
                case "ResourceNotRecorded": "Config stopped recording it"
                default: previous[index] == nil ? "recorded, with nothing earlier to compare" : "changed"
                }
                lines.append("\(change.time): \(status)")
                lines += change.differences.prefix(12).map { "  " + $0 }
                if change.differences.count > 12 { lines.append("  and \(change.differences.count - 12) more differences, in the structured result.") }
                if previous[index] != nil, change.differences.isEmpty, change.status == "OK" { lines.append("  no difference in its configuration, tags or relationships") }
                let linked = change.events.filter { $0.basis == "linked" }
                lines += linked.map { "  Who, from the CloudTrail event Config links to this change: " + CloudTrailEvents.line($0.event, account: config.account.id) }
                // A link Config recorded but that could not be read is said as such, never as no link, beside any that was.
                lines += change.linkedUnread.map { unread in
                    (linked.isEmpty ? "  Who is not known: Config links" : "  Config also links") + " CloudTrail event \(unread.id) to this change, but it could not be read: \(unread.reason)."
                }
                if linked.isEmpty {
                    let lead = change.linkedUnread.isEmpty ? "  Who is not known: Config records no CloudTrail event linked to this change." : " "
                    let searched = change.trailCoverage
                    if change.candidates > 0 {
                        lines.append("\(lead) Candidates, writes to this resource between \(change.window), any of which may or may not be it:")
                        lines += change.events.map { "  - " + CloudTrailEvents.line($0.event, account: config.account.id) }
                        if change.candidates > change.events.count { lines.append("  and \(change.candidates - change.events.count) more candidates.") }
                        if let reason = searched.reason { lines.append("  These are from the events read; the interval was not searched in full: \(reason).") }
                    } else if let reason = searched.reason {
                        lines.append("\(lead) None found in the events read, so whether one exists is not known: \(reason).")
                    } else {
                        lines.append("\(lead) No CloudTrail event in \(trailRegion) writes to this resource between \(change.window); Config does not record who made a change.")
                    }
                }
            }
            if more { lines.append("More changes were recorded in the window than the \(kept.count) kept: narrow since and until, or raise the limit.") }
            if let searchedBack { lines.append("CloudTrail held more events on the resource than were read, so it was searched back only to \(AWS.iso(searchedBack)); changes before that may be missing their events.") }
            lines += notes
            if !changes.isEmpty {
                lines.append("Config records what a resource looked like, not who changed it. Who is said only from a CloudTrail event Config links to the change; otherwise CloudTrail's writes to the resource in \(trailRegion), by its ID, name or ARN, between the configuration before and the capture, are listed as candidates. A change made by an AWS service, or logged under another name, may have none.")
            }
            if !unreadLinked.isEmpty {
                lines.append("\(unreadLinked.count) CloudTrail event\(unreadLinked.count == 1 ? "" : "s") Config links to these changes could not be read; at most \(Self.linkedLookupLimit) are looked up by ID in one lookup.")
            }
            struct History: Encodable {
                let changes: [Change]; let account: String; let region: String; let recorded: Bool?
                let linkedLookupLimit: Int; let linkedUnread: Int
                /// The least of every change's coverage.
                let trailCoverage: TrailCoverage
                let complete: Bool
            }
            let overall = changes.map(\.trailCoverage).max { $0.rank < $1.rank } ?? .complete
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: History(changes: changes, account: config.account.id, region: config.region, recorded: coverage.records,
                                                         linkedLookupLimit: Self.linkedLookupLimit, linkedUnread: unreadLinked.count, trailCoverage: overall,
                                                         complete: !more && unreadLinked.isEmpty && overall.state == "complete"))
        }
    }

    // MARK: s3-exposure

    /// Whether buckets are open to the internet or other accounts, from every setting that decides it.
    struct S3Exposure: ServiceOperation {
        struct Input: Decodable, Sendable { let bucket: String?, limit: Int?, region: String?, account: String? }
        static let name = "s3-exposure"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Whether an account's buckets, or one bucket, are open to the internet or to other accounts: the account's and each bucket's Block Public Access, whether S3 judges its policy public, the policy's statements for anyone or other accounts with their conditions, such as aws:PrincipalOrgID, ACL grants to everyone, any AWS account or other accounts, object ownership, and Access Analyzer's findings for it. Says when the account has more buckets than were read, and when a setting could not be read, rather than calling a bucket private."
        static let input = JSONSchema.object([
            "bucket": .string("One bucket's name alone. Every bucket of the account, up to the limit, when left out."),
            "limit": .integer("How many buckets, at most, when none is named. 25 when left out.", minimum: 1, maximum: 100),
            "region": .string("The bucket's region, when one is named and it is not in the connection's default; buckets listed carry their own."),
            "account": AWS.accountInput,
        ])

        struct Bucket: Encodable {
            let name: String, region: String
            var verdict = ""
            /// Access that is in effect: a public grant with every control that could block it read and off.
            var exposures: [String] = []
            /// A public grant seen whose effect could not be settled, as a control that could block it, or S3's own
            /// judgement of the policy, could not be read.
            var possible: [String] = []
            /// Grants to other accounts, which Block Public Access does not stop.
            var shared: [String] = []
            /// Grants to other accounts whose effect could not be settled: a policy S3 may judge public, which
            /// RestrictPublicBuckets would keep to this account, with one of the two not read.
            var possiblyShared: [String] = []
            /// Grants seen, whatever their effect.
            var observed: [String] = []
            var notes: [String] = []
            /// Each control that can stop public access, as on, off or unknown when it could not be read.
            var controls: [String: String] = [:]
            var blockPublicAccess: [String: Bool]?, policyIsPublic: Bool?, policyGrants: [String] = [], aclGrants: [String] = []
            var objectOwnership: String?, analyzerFindings: [String] = [], unread: [String] = []
        }

        /// A control's state for results: on, off, or unknown when it could not be read.
        static func state(_ value: Bool?) -> String { value.map { $0 ? "on" : "off" } ?? "unknown" }

        /// What S3 answered for one of a bucket's settings.
        enum Got { case found(Data), absent, moved(String?), noBucket, failed(String) }

        static func get(_ s3: Target, _ bucket: String, _ setting: String, needs: String, absent: String) async -> Got {
            do {
                let answer = try await s3.client.exchange([bucket], query: [setting: ""], headers: ["x-amz-expected-bucket-owner": s3.account.id, "Accept": "application/xml"],
                                                          returning: [301, 404])
                switch answer.response.statusCode {
                case 301: return .moved(answer.response.value(forHTTPHeaderField: "x-amz-bucket-region").flatMap { try? AWS.checkedRegion($0) })
                case 404:
                    let reason = ServiceClient.reason(answer.data) ?? ""
                    if reason.contains(absent) { return .absent }
                    if reason.hasPrefix("NoSuchBucket") { return .noBucket }
                    return .failed("S3 said \(reason.isEmpty ? "it was not found" : reason)")
                default: return .found(answer.data)
                }
            } catch {
                guard let fix = AWS.fix(for: error, needs: [needs]) else { return .failed(error.localizedDescription) }
                return .failed(AWS.isDenied(error) ? fix + " S3 refuses it too when another account owns the bucket." : fix)
            }
        }

        static func settings(_ node: XMLNode?) -> [String: Bool]? {
            guard let node, node.name == "PublicAccessBlockConfiguration" else { return nil }
            return Dictionary(uniqueKeysWithValues: AWS.blockAll.map { ($0, node.value($0) == "true") })
        }

        static func describe(_ settings: [String: Bool]?) -> String {
            guard let settings else { return "none set" }
            let on = AWS.blockAll.filter { settings[$0] == true }
            return on.count == 4 ? "all four on" : on.isEmpty ? "none on" : "only \(on.joined(separator: ", ")) on"
        }

        /// A bucket policy's statements that let in anyone or another account, with their conditions.
        static func policyGrants(_ policy: JSON, own: String, covered: Set<String>) -> (anyone: [String], accounts: [String]) {
            var anyone: [String] = [], accounts: [String] = []
            for statement in AWS.statements(policy) where AWS.text(statement["Effect"]) == "Allow" {
                let principal = statement["Principal"]
                var open = principal?.text == "*", others: [String] = []
                for arn in AWS.strings(principal?["AWS"]) {
                    if arn == "*" { open = true; continue }
                    let account = IAMAccess.account(arn)
                    if account != own { others.append("account \(account)\(covered.contains(account) ? "" : ", outside the accounts the sign-in covers")") }
                }
                others += AWS.strings(principal?["CanonicalUser"]).map { "canonical user \($0.prefix(12))…" }
                guard open || !others.isEmpty else { continue }
                let listed = AWS.strings(statement["Action"])
                let actions = statement["NotAction"] != nil ? "everything but \(AWS.strings(statement["NotAction"]).prefix(3).joined(separator: ", "))"
                    : listed.prefix(4).joined(separator: ", ") + (listed.count > 4 ? " and \(listed.count - 4) more" : "")
                let conditions = AWS.conditions(statement)
                let when = conditions.isEmpty ? ", with no condition" : ", when \(AWS.said(conditions))"
                if open { anyone.append("Principal * may \(actions)\(when)") }
                if !others.isEmpty { accounts.append("\(GoogleCloud.listed(Array(NSOrderedSet(array: others)) as? [String] ?? others)) may \(actions)\(when)") }
            }
            return (anyone, accounts)
        }

        /// A bucket ACL's grants beyond its owner: to everyone, any AWS account or another account.
        static func aclGrants(_ node: XMLNode) -> (everyone: [String], accounts: [String]) {
            let owner = node.value("Owner", "ID")
            var everyone: [String] = [], accounts: [String] = []
            for grant in node.child("AccessControlList")?.children ?? [] {
                let grantee = grant.child("Grantee"), permission = grant.value("Permission") ?? "?"
                if let uri = grantee?.value("URI") {
                    if uri.hasSuffix("/global/AllUsers") { everyone.append("everyone: \(permission)") }
                    else if uri.hasSuffix("/global/AuthenticatedUsers") { everyone.append("any AWS account: \(permission)") }
                } else if let id = grantee?.value("ID"), id != owner {
                    accounts.append("another account (canonical ID \(id.prefix(12))…): \(permission)")
                } else if let email = grantee?.value("EmailAddress") {
                    accounts.append("\(email): \(permission)")
                }
            }
            return (everyone, accounts)
        }

        /// One bucket's settings and what they add up to, with the account's Block Public Access.
        static func read(_ name: String, region: String, base: Target, account: [String: Bool]?, accountRead: Bool, covered: Set<String>) async throws -> Bucket {
            var s3 = try base.at(.s3, region: region)
            var block = await get(s3, name, "publicAccessBlock", needs: "s3:GetBucketPublicAccessBlock", absent: "NoSuchPublicAccessBlockConfiguration")
            if case .moved(let elsewhere) = block {
                guard let elsewhere, elsewhere != region else {
                    return Bucket(name: name, region: region, verdict: "not known: the bucket is not in \(region), and S3 did not say where it is; name its region", unread: ["every setting"])
                }
                s3 = try base.at(.s3, region: elsewhere)
                block = await get(s3, name, "publicAccessBlock", needs: "s3:GetBucketPublicAccessBlock", absent: "NoSuchPublicAccessBlockConfiguration")
            }
            if case .noBucket = block { throw ServiceError.notFound }
            let found = s3
            async let status = get(found, name, "policyStatus", needs: "s3:GetBucketPolicyStatus", absent: "NoSuchBucketPolicy")
            async let policy = get(found, name, "policy", needs: "s3:GetBucketPolicy", absent: "NoSuchBucketPolicy")
            async let acl = get(found, name, "acl", needs: "s3:GetBucketAcl", absent: "NoSuchAcl")
            async let ownership = get(found, name, "ownershipControls", needs: "s3:GetBucketOwnershipControls", absent: "OwnershipControlsNotFoundError")
            var bucket = Bucket(name: name, region: found.region)
            func unreadable(_ what: String, _ got: Got) {
                if case .failed(let why) = got { bucket.unread.append("\(what) (\(why))") }
                else if case .moved = got { bucket.unread.append("\(what) (S3 sent it elsewhere)") }
                else if case .noBucket = got { bucket.unread.append("\(what) (S3 says there is no such bucket)") }
                else { bucket.unread.append("\(what) (its answer could not be read)") }
            }
            var settings: [String: Bool]?, blockRead = true
            switch block {
            case .found(let data): if let read = Self.settings(XMLNode.parse(data)) { settings = read } else { unreadable("its Block Public Access", .found(data)); blockRead = false }
            case .absent: settings = nil
            default: unreadable("its Block Public Access", block); blockRead = false
            }
            bucket.blockPublicAccess = settings
            if !accountRead { bucket.unread.append("the account's Block Public Access") }
            // A setting is on when either level is read as on, off only when both are read as off, and otherwise unknown.
            func effective(_ setting: String) -> Bool? {
                if (blockRead && settings?[setting] == true) || (accountRead && account?[setting] == true) { return true }
                return blockRead && accountRead ? false : nil
            }
            let restrict = effective("RestrictPublicBuckets"), ignore = effective("IgnorePublicAcls")

            var ownershipRead = true
            switch await ownership {
            case .found(let data):
                if let value = XMLNode.parse(data)?.value("Rule", "ObjectOwnership") { bucket.objectOwnership = value } else { unreadable("its object ownership", .found(data)); ownershipRead = false }
            case .absent: bucket.objectOwnership = "ObjectWriter (none set)"
            case let other: unreadable("its object ownership", other); ownershipRead = false
            }
            let aclsOff: Bool? = ownershipRead ? bucket.objectOwnership == "BucketOwnerEnforced" : nil
            bucket.controls = ["RestrictPublicBuckets": Self.state(restrict), "IgnorePublicAcls": Self.state(ignore),
                               "BlockPublicPolicy": Self.state(effective("BlockPublicPolicy")), "BlockPublicAcls": Self.state(effective("BlockPublicAcls")),
                               "ACLs disabled (BucketOwnerEnforced)": Self.state(aclsOff)]

            switch await status {
            case .found(let data):
                if let node = XMLNode.parse(data), node.name == "PolicyStatus", let value = node.value("IsPublic") { bucket.policyIsPublic = value == "true" }
                else { unreadable("whether S3 judges its policy public", .found(data)) }
            case .absent: bucket.policyIsPublic = false
            case let other: unreadable("whether S3 judges its policy public", other)
            }
            var anyone: [String] = [], toAccounts: [String] = [], policyRead = true
            switch await policy {
            case .found(let data):
                if let document = try? JSONDecoder().decode(JSON.self, from: data), case .object = document {
                    let grants = Self.policyGrants(document, own: base.account.id, covered: covered)
                    anyone = grants.anyone
                    bucket.policyGrants = grants.anyone + grants.accounts
                    bucket.observed += bucket.policyGrants.map { "its policy: " + $0 }
                    toAccounts = grants.accounts.map { "its policy: " + $0 }
                } else { unreadable("its policy", .found(data)); policyRead = false }
            case .absent: break
            case let other: unreadable("its policy", other); policyRead = false
            }
            // Whether the policy grants public access, as S3 judges it with its conditions; unknown when that was not read.
            switch bucket.policyIsPublic {
            case true?:
                switch restrict {
                case true?: bucket.notes.append("S3 judges its policy public, but RestrictPublicBuckets is on, keeping it to this account and AWS services")
                case false?: bucket.exposures.append("effectively public through its bucket policy: S3 judges it public and RestrictPublicBuckets is off at both levels")
                case nil: bucket.possible.append("S3 judges its policy public; it is effectively public unless RestrictPublicBuckets is on, which could not be read")
                }
            case false?:
                if !anyone.isEmpty { bucket.notes.append("its policy names Principal *, but S3 judges it not public, as its conditions keep it to known accounts, networks or sources") }
            case nil:
                if !anyone.isEmpty { bucket.possible.append("its policy names Principal *, and whether S3 judges that public could not be read") }
                else if !policyRead { bucket.possible.append("neither its policy nor whether S3 judges it public could be read") }
            }
            // RestrictPublicBuckets keeps a public policy's access, other accounts' included, to this account and AWS
            // services; a policy S3 judges not public is untouched by it, so its grants to other accounts stand.
            if !toAccounts.isEmpty {
                if bucket.policyIsPublic == false || restrict == false {
                    bucket.shared += toAccounts
                } else if bucket.policyIsPublic == true, restrict == true {
                    bucket.notes.append("its policy grants other accounts (\(toAccounts.map { $0.replacingOccurrences(of: "its policy: ", with: "") }.joined(separator: "; "))), but as S3 judges the policy public and RestrictPublicBuckets is on, that access is blocked")
                } else {
                    let unknown = [bucket.policyIsPublic == nil ? "whether S3 judges the policy public" : nil, restrict == nil ? "RestrictPublicBuckets" : nil].compactMap { $0 }
                    bucket.possiblyShared += toAccounts.map { "\($0); blocked if the policy is public and RestrictPublicBuckets is on, and \(GoogleCloud.listed(unknown)) could not be read" }
                }
            }
            switch await acl {
            case .found(let data):
                if let node = XMLNode.parse(data), node.name == "AccessControlPolicy" {
                    let grants = Self.aclGrants(node)
                    bucket.aclGrants = grants.everyone + grants.accounts
                    bucket.observed += bucket.aclGrants.map { "its ACL: " + $0 }
                    if !grants.everyone.isEmpty {
                        let granted = grants.everyone.joined(separator: ", ")
                        if aclsOff == true { bucket.notes.append("its ACL grants \(granted), but ACLs are off, as the bucket owner is enforced") }
                        else if ignore == true { bucket.notes.append("its ACL grants \(granted), but IgnorePublicAcls makes S3 ignore that") }
                        else if aclsOff == false, ignore == false { bucket.exposures.append("effectively public through its ACL: \(granted), with ACLs on and IgnorePublicAcls off at both levels") }
                        else {
                            let unknown = [aclsOff == nil ? "its object ownership" : nil, ignore == nil ? "IgnorePublicAcls" : nil].compactMap { $0 }
                            bucket.possible.append("its ACL grants \(granted); it is effectively public unless ACLs are off or IgnorePublicAcls is on, and \(GoogleCloud.listed(unknown)) could not be read")
                        }
                    }
                    switch aclsOff {
                    case false?: bucket.shared += grants.accounts.map { "its ACL: " + $0 }
                    case nil where !grants.accounts.isEmpty: bucket.notes.append("its ACL grants other accounts, which apply unless ACLs are off, and its object ownership could not be read")
                    default: break
                    }
                } else { unreadable("its ACL", .found(data)) }
            case .absent: break
            case let other: unreadable("its ACL", other)
            }
            return bucket
        }

        /// Access Analyzer's active findings for buckets in `region`, by bucket name, and what to say when they could not all be read.
        static func analyzer(_ base: Target, region: String, bucket: String?) async -> (found: [String: [String]], said: String?) {
            do {
                let target = try base.at(.accessAnalyzer, region: region)
                let analyzers = AWS.items(try await AWS.call(target, ["analyzer"], method: "GET", body: nil)["analyzers"]).filter { AWS.text($0["status"]) == "ACTIVE" }
                guard let analyzer = analyzers.first(where: { AWS.text($0["type"]) == "ORGANIZATION" }) ?? analyzers.first(where: { AWS.text($0["type"]) == "ACCOUNT" }),
                      let arn = AWS.text(analyzer["arn"]) else {
                    return ([:], "No external access analyzer is active in \(region), so Access Analyzer's view of buckets there is missing.")
                }
                var filter: [String: Any] = ["status": ["eq": ["ACTIVE"]], "resourceType": ["eq": ["AWS::S3::Bucket"]]]
                if let bucket { filter["resource"] = ["eq": ["arn:aws:s3:::\(bucket)"]] }
                var found: [String: [String]] = [:], token: String?, pages = 0
                repeat {
                    var body: [String: Any] = ["analyzerArn": arn, "filter": filter, "maxResults": 100]
                    if let token { body["nextToken"] = token }
                    let answer = try await AWS.call(target, ["finding"], body: body)
                    pages += 1
                    for finding in AWS.items(answer["findings"]) {
                        guard let resource = AWS.text(finding["resource"]), resource.hasPrefix("arn:aws:s3:::") else { continue }
                        var fields: [String: JSON] = [:]
                        if case .object(let given)? = finding["principal"] { fields = given }
                        let principals = fields.sorted { $0.key < $1.key }.map { "\($0.key) \(AWS.text($0.value) ?? $0.value.compact(60))" }
                        let conditioned = finding["condition"].map { if case .object(let fields) = $0 { !fields.isEmpty } else { false } } ?? false
                        found[String(resource.dropFirst(13)), default: []].append(AWS.flag(finding["isPublic"]) == true ? "public"
                            : "shared with \(principals.isEmpty ? "another account" : principals.joined(separator: ", "))\(conditioned ? " under conditions" : "")")
                    }
                    token = AWS.text(answer["nextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                } while token != nil && pages < AWS.maximumPages
                return (found, token != nil ? "Access Analyzer had more bucket findings in \(region) than were read." : nil)
            } catch {
                return ([:], "Access Analyzer could not be read in \(region): \(AWS.fix(for: error, needs: ["access-analyzer:ListAnalyzers", "access-analyzer:ListFindings"]) ?? error.localizedDescription)")
            }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let named = try input.bucket.map(AWS.bucket)
            let limit = try AWS.limit(input.limit, default: 25, maximum: 100)
            let base = try await AWS.target(.s3, region: input.region, account: input.account, on: service)
            let covered = Set(try await service.access.awsAccounts().map(\.id))

            // The account's Block Public Access applies to every bucket in it.
            var account: [String: Bool]?, accountRead = true, notes: [String] = []
            do {
                let control = try base.at(.s3Control)
                let answer = try await control.client.exchange(["v20180820", "configuration", "publicAccessBlock"], headers: ["x-amz-account-id": base.account.id, "Accept": "application/xml"],
                                                               returning: [404])
                if answer.response.statusCode == 404 {
                    guard (ServiceClient.reason(answer.data) ?? "").contains("NoSuchPublicAccessBlockConfiguration") else { throw ServiceError.notFound }
                } else {
                    guard let read = Self.settings(XMLNode.parse(answer.data)) else { throw ServiceError.unreadable }
                    account = read
                }
            } catch {
                accountRead = false
                notes.append("The account's Block Public Access could not be read: \(AWS.fix(for: error, needs: ["s3:GetAccountPublicAccessBlock"]) ?? error.localizedDescription)")
            }

            var listed: [(name: String, region: String)] = [], more = false
            if let named {
                listed = [(named, base.region)]
            } else {
                var token: String?, pages = 0
                repeat {
                    var query: [String: String?] = ["max-buckets": String(min(1000, limit + 1))]
                    if let token { query["continuation-token"] = token }
                    let answer = try await AWS.read("the account's buckets", needs: ["s3:ListAllMyBuckets"]) {
                        try await base.client.xml([], query: query)
                    }
                    guard answer.name == "ListAllMyBucketsResult" else { throw ServiceError.unreadable }
                    pages += 1
                    for item in answer.child("Buckets")?.children ?? [] {
                        guard let name = item.value("Name") else { throw ServiceError.unreadable }
                        listed.append((name, item.value("BucketRegion").flatMap { try? AWS.checkedRegion($0) } ?? base.region))
                    }
                    token = answer.value("ContinuationToken")
                } while token != nil && listed.count <= limit && pages < AWS.maximumPages
                more = listed.count > limit || token != nil
                listed = Array(listed.prefix(limit))
            }

            var buckets: [Bucket] = []
            for (name, region) in listed {
                do {
                    buckets.append(try await Self.read(name, region: region, base: base, account: account, accountRead: accountRead, covered: covered))
                } catch ServiceError.notFound {
                    if named != nil { throw ServiceError.input("S3 has no bucket \(name) in \(base.named).") }
                    buckets.append(Bucket(name: name, region: region, unread: ["every setting (S3 says there is no such bucket now)"]))
                }
            }
            var analyzerNotes: [String] = []
            for region in Array(Set(buckets.map(\.region))).sorted() {
                let (found, said) = await Self.analyzer(base, region: region, bucket: named)
                if let said { analyzerNotes.append(said) }
                for index in buckets.indices where buckets[index].region == region {
                    buckets[index].analyzerFindings = found[buckets[index].name] ?? []
                    if said != nil, found[buckets[index].name] == nil { continue }
                    if buckets[index].analyzerFindings.contains("public") { buckets[index].possible.append("Access Analyzer reports it public") }
                    buckets[index].shared += buckets[index].analyzerFindings.filter { $0 != "public" }.map { "Access Analyzer: " + $0 }
                }
            }
            for index in buckets.indices {
                let bucket = buckets[index]
                let shared = !bucket.shared.isEmpty ? ", and shared with other accounts" : !bucket.possiblyShared.isEmpty ? ", and possibly shared with other accounts" : ""
                buckets[index].verdict = !bucket.exposures.isEmpty ? "PUBLIC" + shared
                    : !bucket.possible.isEmpty ? "possibly public, not settled from what could be read" + shared
                    : !bucket.shared.isEmpty ? "shared with other accounts" + (bucket.unread.isEmpty ? "" : "; whether it is public is not known, as some settings could not be read")
                    : !bucket.possiblyShared.isEmpty ? "possibly shared with other accounts, not settled from what could be read"
                    : !bucket.unread.isEmpty ? "not known, as some of its settings could not be read"
                    : "not public or shared with other accounts, by its settings"
            }
            var lines = ["\(base.named): \(named == nil ? "\(buckets.count) buckets" : "bucket \(named!)"); the account's Block Public Access: \(accountRead ? Self.describe(account) : "not read")."]
            if buckets.isEmpty { lines.append("The account has no buckets.") }
            func rank(_ bucket: Bucket) -> Int { !bucket.exposures.isEmpty ? 0 : !bucket.possible.isEmpty ? 1 : !bucket.shared.isEmpty ? 2 : !bucket.possiblyShared.isEmpty ? 3 : 4 }
            for bucket in buckets.sorted(by: { (rank($0), $0.name) < (rank($1), $1.name) }) {
                var parts = bucket.exposures + bucket.possible + bucket.shared + bucket.possiblyShared.map { "possibly shared: " + $0 } + bucket.notes
                let grantedPublic = bucket.observed.filter { $0.contains("Principal *") || $0.contains("everyone:") || $0.contains("any AWS account:") }
                if !grantedPublic.isEmpty { parts.append("public grants seen: \(grantedPublic.joined(separator: "; "))") }
                parts.append("Block Public Access \(bucket.unread.contains { $0.hasPrefix("its Block Public Access") } ? "not read" : Self.describe(bucket.blockPublicAccess))")
                let unknown = bucket.controls.filter { $0.value == "unknown" }.keys.sorted()
                if !unknown.isEmpty { parts.append("unknown controls: \(unknown.joined(separator: ", "))") }
                if let ownership = bucket.objectOwnership { parts.append("object ownership \(ownership)") }
                if !bucket.unread.isEmpty { parts.append("could not read \(bucket.unread.joined(separator: "; "))") }
                lines.append("\(bucket.name) [\(bucket.region)]: \(bucket.verdict) — \(parts.joined(separator: "; ")).")
            }
            if more { lines.append("The account has more buckets than the \(buckets.count) read: name one with bucket, or raise the limit.") }
            lines += notes + analyzerNotes
            lines.append("Not read: objects' own ACLs, which can make an object public while ACLs are on and IgnorePublicAcls is off; access points; and Multi-Region Access Points.")
            struct Found: Encodable { let buckets: [Bucket]; let account: String; let accountBlockPublicAccess: [String: Bool]?; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Found(buckets: buckets, account: base.account.id, accountBlockPublicAccess: account,
                                                       complete: !more && accountRead && buckets.allSatisfy { $0.unread.isEmpty }))
        }
    }

    // MARK: identity-center-assignments

    /// Who holds which IAM Identity Center permission set in which account: where most people's access to an
    /// organisation's accounts lives, which IAM's own users and roles do not show.
    struct IdentityCenterAssignments: ServiceOperation {
        struct Input: Decodable, Sendable { let inAccount: String?, permissionSet: String?, principal: String?, region: String?, account: String? }
        static let name = "identity-center-assignments"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Who holds which IAM Identity Center permission set in which account: each user and group by name, with permission sets that make their holders full administrators, AdministratorAccess or an inline policy allowing everything, flagged; filtered by account, permission set, or a user, with the groups they are in, or a group. Read from the organisation's management account or Identity Center's delegated administrator, in Identity Center's region; says when it stopped before reading everything."
        static let input = JSONSchema.object([
            "inAccount": .string("Only assignments in this account, by its 12-digit ID or, for one the sign-in covers, its name."),
            "permissionSet": .string("Only this permission set, by its name or ARN."),
            "principal": .string("Only this user, by user name, with the groups they are in; or this group, by display name."),
            "region": .string("The region IAM Identity Center is in, when not the connection's default."),
            "account": .string("The account to read Identity Center from: the organisation's management account or its delegated administrator, by ID or name. Needed unless the sign-in covers only one."),
        ])

        /// The most requests one lookup sends; an organisation's every account and permission set can take many.
        static let budget = 400

        struct Assignment: Encodable {
            let account: String, accountName: String?, permissionSet: String, permissionSetArn: String
            let principalType: String, principalId: String
            var principal: String?
            var fullAdministrator: Bool?
        }

        /// A list in an answer: none when left out, and an answer of any other shape unreadable.
        static func list(_ json: JSON, _ key: String) throws -> [JSON] {
            switch json[key] {
            case nil, .null?: return []
            case .array(let items)?: return items
            default: throw ServiceError.unreadable
            }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let filterAccount = try input.inAccount.map { try ServiceInput.quoted($0, "the account", limit: 64) }
            let filterSet = try input.permissionSet.map { try ServiceInput.quoted($0, "the permission set", limit: 256) }
            let filterPrincipal = try input.principal.map { try ServiceInput.quoted($0, "the user or group", limit: 256) }
            let sso = try await AWS.target(.sso, region: input.region, account: input.account, on: service)
            let store = try sso.at(.identitystore)
            let covered = try await service.access.awsAccounts()
            let names = Dictionary(covered.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let inAccount: String?
            if let filterAccount {
                if AWS.isAccountID(filterAccount) { inAccount = filterAccount }
                else if let match = covered.first(where: { $0.name.caseInsensitiveCompare(filterAccount) == .orderedSame }) { inAccount = match.id }
                else { throw ServiceError.input("Give inAccount as a 12-digit account ID, or the name of one the sign-in covers: \(AWS.listing(covered)).") }
            } else { inAccount = nil }

            if let filterSet, filterSet.hasPrefix("arn:"),
               filterSet.range(of: #"^arn:aws:sso:::permissionSet/ssoins-[0-9a-f]{16}/ps-[0-9a-f]{16}$"#, options: .regularExpression) == nil {
                throw ServiceError.input("Give the permission set's name, or its ARN such as arn:aws:sso:::permissionSet/ssoins-0123456789abcdef/ps-0123456789abcdef.")
            }
            var calls = 0, stopped = false, groupsCut = false

            func admin(_ operation: String, _ body: [String: Any]) async throws -> JSON {
                calls += 1
                let answer = try await AWS.read("IAM Identity Center's \(operation)", needs: ["sso:\(operation)"]) {
                    try await AWS.call(sso, operation: "SWBExternalService." + operation, body: body)
                }
                guard case .object = answer else { throw ServiceError.unreadable }
                return answer
            }
            func identity(_ operation: String, _ body: [String: Any]) async throws -> JSON {
                calls += 1
                let answer = try await AWS.read("Identity Center's identity store", needs: ["identitystore:\(operation)"]) {
                    try await AWS.call(store, operation: "AWSIdentityStore." + operation, body: body)
                }
                guard case .object = answer else { throw ServiceError.unreadable }
                return answer
            }

            let instances: [JSON]
            do {
                instances = try Self.list(try await admin("ListInstances", [:]), "Instances")
            } catch ServiceError.input(let said) {
                throw ServiceError.input(said + " Only the organisation's management account, or Identity Center's delegated administrator, may read assignments: name that account.")
            }
            guard let instance = instances.first else {
                return try ServiceResult(text: "No IAM Identity Center instance answers in \(sso.place). Name the region Identity Center is in, and the organisation's management account or Identity Center's delegated administrator.",
                                         structured: AWS.fields(["assignments": [String](), "account": sso.account.id, "region": sso.region]))
            }
            guard let instanceArn = AWS.text(instance["InstanceArn"]), let storeID = AWS.text(instance["IdentityStoreId"]) else { throw ServiceError.unreadable }

            // A user stands for themselves and the groups they are in.
            var wanted: Set<String>?, wantedSaid = ""
            if let filterPrincipal {
                func resolve(_ operation: String, _ attribute: String) async throws -> String? {
                    do {
                        let answer = try await identity(operation, ["IdentityStoreId": storeID, "AlternateIdentifier": ["UniqueAttribute": ["AttributePath": attribute, "AttributeValue": filterPrincipal]]])
                        return AWS.text(answer["UserId"]) ?? AWS.text(answer["GroupId"])
                    } catch ServiceError.refused(let reason) where reason.contains("ResourceNotFound") { return nil }
                }
                if let user = try await resolve("GetUserId", "userName") {
                    var groups: [String] = [], token: String?, pages = 0
                    repeat {
                        var body: [String: Any] = ["IdentityStoreId": storeID, "MemberId": ["UserId": user], "MaxResults": 100]
                        if let token { body["NextToken"] = token }
                        let answer = try await identity("ListGroupMembershipsForMember", body)
                        groups += try Self.list(answer, "GroupMemberships").compactMap { AWS.text($0["GroupId"]) }
                        token = AWS.text(answer["NextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                        pages += 1
                    } while token != nil && pages < AWS.maximumPages
                    groupsCut = token != nil
                    wanted = Set([user] + groups)
                    wantedSaid = ", for user \(filterPrincipal) and the \(groups.count) group\(groups.count == 1 ? "" : "s") they are in"
                } else if let group = try await resolve("GetGroupId", "displayName") {
                    wanted = [group]
                    wantedSaid = ", for group \(filterPrincipal)"
                } else {
                    throw ServiceError.input("IAM Identity Center has no user with user name \(filterPrincipal), and no group with that display name.")
                }
            }

            // Permission sets, by name.
            var sets: [(arn: String, name: String)] = []
            if let filterSet, filterSet.hasPrefix("arn:") {
                let described = try await admin("DescribePermissionSet", ["InstanceArn": instanceArn, "PermissionSetArn": filterSet])
                sets = [(filterSet, AWS.text(described["PermissionSet"]?["Name"]) ?? filterSet)]
            } else {
                var arns: [String] = [], token: String?, pages = 0
                repeat {
                    var body: [String: Any] = ["InstanceArn": instanceArn, "MaxResults": 100]
                    if let token { body["NextToken"] = token }
                    let answer = try await admin("ListPermissionSets", body)
                    arns += try Self.list(answer, "PermissionSets").compactMap(\.text)
                    token = AWS.text(answer["NextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                    pages += 1
                } while token != nil && pages < AWS.maximumPages
                if token != nil { stopped = true }
                for arn in arns {
                    guard calls < Self.budget else { stopped = true; break }
                    let described = try await admin("DescribePermissionSet", ["InstanceArn": instanceArn, "PermissionSetArn": arn])
                    sets.append((arn, AWS.text(described["PermissionSet"]?["Name"]) ?? arn))
                }
                if let filterSet {
                    let all = sets
                    sets = sets.filter { $0.name.caseInsensitiveCompare(filterSet) == .orderedSame }
                    guard !sets.isEmpty else {
                        throw ServiceError.input("Identity Center has no permission set named \(filterSet). Its permission sets: \(all.prefix(20).map(\.name).joined(separator: ", "))\(all.count > 20 ? ", and more" : "").")
                    }
                }
            }

            // Assignments: each permission set's accounts, then who holds it in each.
            var assignments: [Assignment] = []
            outer: for set in sets {
                var accounts: [String] = []
                if let inAccount { accounts = [inAccount] } else {
                    var token: String?, pages = 0
                    repeat {
                        guard calls < Self.budget else { stopped = true; break outer }
                        var body: [String: Any] = ["InstanceArn": instanceArn, "PermissionSetArn": set.arn, "MaxResults": 100]
                        if let token { body["NextToken"] = token }
                        let answer = try await admin("ListAccountsForProvisionedPermissionSet", body)
                        accounts += try Self.list(answer, "AccountIds").compactMap(\.text)
                        token = AWS.text(answer["NextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                        pages += 1
                    } while token != nil && pages < AWS.maximumPages
                    if token != nil { stopped = true }
                }
                for account in accounts {
                    var token: String?, pages = 0
                    repeat {
                        guard calls < Self.budget else { stopped = true; break outer }
                        var body: [String: Any] = ["InstanceArn": instanceArn, "AccountId": account, "PermissionSetArn": set.arn, "MaxResults": 100]
                        if let token { body["NextToken"] = token }
                        let answer = try await admin("ListAccountAssignments", body)
                        for item in try Self.list(answer, "AccountAssignments") {
                            guard let id = AWS.text(item["PrincipalId"]), let type = AWS.text(item["PrincipalType"]) else { throw ServiceError.unreadable }
                            if let wanted, !wanted.contains(id) { continue }
                            assignments.append(Assignment(account: account, accountName: names[account], permissionSet: set.name, permissionSetArn: set.arn,
                                                          principalType: type, principalId: id))
                        }
                        token = AWS.text(answer["NextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                        pages += 1
                    } while token != nil && pages < AWS.maximumPages
                    if token != nil { stopped = true }
                }
            }

            // Which of the permission sets held make their holders full administrators.
            var notes: [String] = [], administrators: [String: String] = [:], judged = Set<String>(), unreadInline: [String] = []
            for arn in Array(NSOrderedSet(array: assignments.map(\.permissionSetArn))) as? [String] ?? [] {
                guard calls < Self.budget else { break }
                do {
                    let managed = try Self.list(try await admin("ListManagedPoliciesInPermissionSet", ["InstanceArn": instanceArn, "PermissionSetArn": arn, "MaxResults": 100]), "AttachedManagedPolicies")
                    let text = AWS.text(try await admin("GetInlinePolicyForPermissionSet", ["InstanceArn": instanceArn, "PermissionSetArn": arn])["InlinePolicy"]) ?? ""
                    let inline = AWS.policy(text)
                    if managed.contains(where: { AWS.text($0["Arn"])?.hasSuffix(":policy/AdministratorAccess") == true }) { administrators[arn] = "AdministratorAccess" }
                    else if inline.map(AWS.allowsEverything) == true { administrators[arn] = "an inline policy allowing everything" }
                    // An inline policy that could not be read may allow anything: such a set is not called anything.
                    else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, inline == nil {
                        unreadInline.append(sets.first { $0.arn == arn }?.name ?? arn)
                        continue
                    }
                    judged.insert(arn)
                } catch {
                    notes.append("Whether permission sets make their holders administrators could not be read: \(AWS.fix(for: error, needs: ["sso:ListManagedPoliciesInPermissionSet", "sso:GetInlinePolicyForPermissionSet"]) ?? error.localizedDescription)")
                    break
                }
            }

            // Names for the users and groups, from the identity store.
            var principals: [String: String] = [:]
            for (id, type) in Dictionary(assignments.map { ($0.principalId, $0.principalType) }, uniquingKeysWith: { first, _ in first }).sorted(by: { $0.key < $1.key }).prefix(200) {
                guard calls < Self.budget else { stopped = true; break }
                do {
                    if type == "USER" {
                        let user = try await identity("DescribeUser", ["IdentityStoreId": storeID, "UserId": id])
                        principals[id] = "user " + (AWS.text(user["UserName"]) ?? AWS.text(user["DisplayName"]) ?? id)
                    } else {
                        let group = try await identity("DescribeGroup", ["IdentityStoreId": storeID, "GroupId": id])
                        principals[id] = "group " + (AWS.text(group["DisplayName"]) ?? id)
                    }
                } catch {
                    notes.append("Users' and groups' names could not be read, so some are given by ID: \(AWS.fix(for: error, needs: ["identitystore:DescribeUser", "identitystore:DescribeGroup"]) ?? error.localizedDescription)")
                    break
                }
            }
            for index in assignments.indices {
                let assignment = assignments[index]
                assignments[index].principal = principals[assignment.principalId] ?? "\(assignment.principalType.lowercased()) \(assignment.principalId)"
                assignments[index].fullAdministrator = judged.contains(assignment.permissionSetArn) ? administrators[assignment.permissionSetArn] != nil : nil
            }

            let accountsHeld = Array(NSOrderedSet(array: assignments.map(\.account))) as? [String] ?? []
            let instanceID = instanceArn.split(separator: "/").last.map(String.init) ?? instanceArn
            var lines = ["IAM Identity Center \(instanceID), read from \(sso.place)\(wantedSaid): \(assignments.count) assignment\(assignments.count == 1 ? "" : "s") of \(Set(assignments.map(\.permissionSetArn)).count) permission sets in \(accountsHeld.count) account\(accountsHeld.count == 1 ? "" : "s")."]
            let adminSets = sets.filter { administrators[$0.arn] != nil }
            if !adminSets.isEmpty {
                lines.append("Full administrator permission sets: " + adminSets.map { "\($0.name) (\(administrators[$0.arn]!))" }.joined(separator: "; ") + ".")
            }
            var shown = 0
            for account in accountsHeld.sorted() {
                guard shown < 150 else { break }
                lines.append("Account \(names[account].map { "\($0) (\(account))" } ?? account):")
                let here = assignments.filter { $0.account == account }
                for set in Array(NSOrderedSet(array: here.map(\.permissionSet))) as? [String] ?? [] {
                    let holders = here.filter { $0.permissionSet == set }
                    let flag = switch holders.first?.fullAdministrator {
                    case true?: " [full administrator]"
                    case nil: " [whether it makes them administrators is not known]"
                    case false?: ""
                    }
                    lines.append("- \(set)\(flag): " + holders.compactMap(\.principal).sorted().joined(separator: ", "))
                    shown += 1
                }
            }
            if shown >= 150 { lines.append("More accounts in the structured result.") }
            if stopped { lines.append("Stopped after \(calls) requests with more to read, so some assignments are missing: filter by inAccount, permissionSet or principal.") }
            if groupsCut { lines.append("The user is in more groups than were read, so assignments through the rest are missing.") }
            if !unreadInline.isEmpty { lines.append("The inline policies of \(unreadInline.joined(separator: ", ")) could not be read, so whether they make their holders administrators is not known.") }
            let unjudged = Set(assignments.filter { $0.fullAdministrator == nil }.map(\.permissionSet))
            if !unjudged.isEmpty, unreadInline.isEmpty, notes.allSatisfy({ !$0.hasPrefix("Whether permission sets") }) {
                lines.append("Whether \(unjudged.sorted().joined(separator: ", ")) make their holders administrators was not read, as the lookup reached its \(Self.budget) requests.")
            }
            lines += notes
            lines.append("A group's members are not listed: ask with principal for one user's access, their groups' included. Customer managed policies and permission boundaries in permission sets are not judged.")
            struct Found: Encodable { let assignments: [Assignment]; let account: String; let region: String; let instance: String; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Found(assignments: assignments, account: sso.account.id, region: sso.region, instance: instanceArn,
                                                       complete: !stopped && !groupsCut && unjudged.isEmpty))
        }
    }

    // MARK: credential-hygiene

    /// Weak and stale credentials, from the account's credential report.
    struct CredentialHygiene: ServiceOperation {
        struct Input: Decodable, Sendable { let days: Int?, account: String? }
        static let name = "credential-hygiene"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Weak and stale credentials in an account, from its credential report: whether root has MFA and access keys, console users without MFA, other users without it, active access keys older than a number of days or unused for as long, and console passwords unused as long; saying how old the report is, as AWS reuses one up to four hours old."
        static let input = JSONSchema.object([
            "days": .integer("How old a key, or how long unused, counts as stale. 90 when left out.", minimum: 30, maximum: 365), "account": AWS.accountInput,
        ])

        struct User: Encodable { let name: String, arn: String?, console: Bool, mfa: Bool, findings: [String] }

        static func date(_ value: String?) -> Date? {
            guard let value, !["N/A", "no_information", "not_supported", ""].contains(value) else { return nil }
            return ISO8601DateFormatter().date(from: value) ?? ServiceAlert.time(value)
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let days = input.days ?? 90
            guard (30...365).contains(days) else { throw ServiceError.input("Give days from 30 to 365.") }
            let (account, signed) = try await AWS.account(input.account, on: service)
            let iam = try Target(client: signed, account: account, region: "us-east-1", service: .iam).at(.iam)
            let report = try await CredentialReport.report(iam)
            let column = Dictionary(report.columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            for needed in ["user", "password_enabled", "mfa_active", "access_key_1_active", "access_key_1_last_rotated", "access_key_1_last_used_date"] where column[needed] == nil {
                throw ServiceError.unreadable
            }
            let now = Date(), stale = now.addingTimeInterval(-Double(days) * 86_400)
            func value(_ row: [String], _ name: String) -> String? { column[name].flatMap { $0 < row.count ? row[$0] : nil } }
            func ago(_ date: Date) -> String { "\(Int(now.timeIntervalSince(date) / 86_400)) days ago" }

            // A field the report gives as neither true nor false is not known, never taken as false.
            func flag(_ row: [String], _ name: String) -> Bool? { ["true": true, "false": false][value(row, name) ?? ""] }
            /// Whether a date field was given but could not be read, rather than left empty as N/A.
            func garbled(_ row: [String], _ name: String) -> Bool { Self.date(value(row, name)) == nil && !["N/A", "no_information", "not_supported", ""].contains(value(row, name) ?? "") }

            var root: [String] = [], users: [User] = [], unknown: [String] = []
            for row in report.rows {
                guard let name = value(row, "user") else { continue }
                let mfaKnown = flag(row, "mfa_active"), mfa = mfaKnown == true
                var keys: [String] = [], keysUnknown: [String] = []
                for key in ["1", "2"] {
                    let active = flag(row, "access_key_\(key)_active")
                    guard active != false else { continue }
                    guard active == true else { keysUnknown.append("whether access key \(key) is active"); continue }
                    let rotated = Self.date(value(row, "access_key_\(key)_last_rotated")), used = Self.date(value(row, "access_key_\(key)_last_used_date"))
                    var said: [String] = []
                    if let rotated, rotated < stale { said.append("made \(ago(rotated))") }
                    if let used { if used < stale { said.append("last used \(ago(used))") } }
                    else if let rotated, rotated < stale { said.append("never used") }
                    if garbled(row, "access_key_\(key)_last_rotated") || garbled(row, "access_key_\(key)_last_used_date") { keysUnknown.append("access key \(key)'s age or last use") }
                    keys.append("active access key \(key)" + (said.isEmpty ? "" : " (\(said.joined(separator: ", ")))"))
                }
                if name == "<root_account>" {
                    root.append(mfaKnown.map { $0 ? "root has MFA on" : "root has no MFA" } ?? "whether root has MFA is not known")
                    root.append(!keys.isEmpty ? "root has \(keys.joined(separator: " and ")): delete root's keys"
                                : keysUnknown.isEmpty ? "root has no active access keys" : "whether root has active access keys is not known")
                    if let used = Self.date(value(row, "password_last_used")) { root.append("root's password last used \(AWS.iso(used))") }
                    if !keysUnknown.isEmpty || mfaKnown == nil { unknown.append("root") }
                    continue
                }
                let consoleKnown = flag(row, "password_enabled"), console = consoleKnown == true
                var findings: [String] = []
                if console, mfaKnown == false { findings.append("console password without MFA") }
                if !console, mfaKnown == false, !keys.isEmpty { findings.append("access keys without MFA") }
                findings += keys.filter { $0.contains("(") }
                let unread = (mfaKnown == nil ? ["whether MFA is on"] : []) + (consoleKnown == nil ? ["whether it has a console password"] : []) + keysUnknown
                if !unread.isEmpty { findings.append("not known: " + unread.joined(separator: ", ")); unknown.append(name) }
                if console {
                    let created = Self.date(value(row, "user_creation_time"))
                    if let used = Self.date(value(row, "password_last_used")) { if used < stale { findings.append("console password last used \(ago(used))") } }
                    else if let created, created < stale { findings.append("console password never used") }
                }
                users.append(User(name: name, arn: value(row, "arn"), console: console, mfa: mfa, findings: findings))
            }
            let noMFAConsole = users.filter { $0.findings.contains("console password without MFA") }
            let noMFAKeys = users.filter { !$0.console && !$0.mfa && $0.findings.contains("access keys without MFA") }
            let staleKeys = users.filter { $0.findings.contains { $0.hasPrefix("active access key") } }
            let stalePasswords = users.filter { $0.findings.contains { $0.hasPrefix("console password last used") || $0 == "console password never used" } }
            func list(_ users: [User], _ detail: (User) -> String) -> [String] {
                users.prefix(50).map { "- " + detail($0) } + (users.count > 50 ? ["\(users.count - 50) more in the structured result."] : [])
            }
            var lines = ["In \(iam.named), \(users.count) IAM users; stale means \(days) days."]
            lines.append(root.isEmpty ? "Root: not in the report." : "Root: " + root.joined(separator: "; ") + ".")
            lines.append("Console users without MFA (\(noMFAConsole.count)):")
            lines += list(noMFAConsole) { $0.name }
            lines.append("Users with access keys and no MFA, without a console password (\(noMFAKeys.count)):")
            lines += list(noMFAKeys) { $0.name }
            lines.append("Active access keys older than \(days) days or unused for as long (\(staleKeys.count) users):")
            lines += list(staleKeys) { user in "\(user.name): " + user.findings.filter { $0.hasPrefix("active access key") }.joined(separator: "; ") }
            lines.append("Console passwords unused for \(days) days (\(stalePasswords.count)):")
            lines += list(stalePasswords) { user in "\(user.name): " + user.findings.filter { $0.hasPrefix("console password") && $0 != "console password without MFA" }.joined(separator: "; ") }
            var notice = "From the credential report made \(report.made ?? "at an unknown time")"
            if let made = report.made.flatMap(ServiceAlert.time) { notice += ", \(Int(now.timeIntervalSince(made) / 60)) minutes ago" }
            notice += "; AWS reuses a report up to four hours old, so users and keys made or changed since may be missing or out of date."
            lines.append(notice)
            if !unknown.isEmpty { lines.append("The report's fields for \(unknown.prefix(20).joined(separator: ", "))\(unknown.count > 20 ? " and more" : "") could not all be read, so they are in no list above for what was not read: \(users.filter { unknown.contains($0.name) }.prefix(10).map { "\($0.name): \($0.findings.last ?? "")" }.joined(separator: "; ")).") }
            if report.broken > 0 { lines.append("\(report.broken) rows could not be split into the report's columns and are left out, so these lists may be missing users.") }
            lines.append("Not covered: people who sign in through IAM Identity Center or another identity provider, whose MFA is set there.")
            struct Found: Encodable { let root: [String]; let users: [User]; let account: String; let reportMade: String?; let days: Int; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Found(root: root, users: users.filter { !$0.findings.isEmpty }, account: account.id, reportMade: report.made, days: days,
                                                       complete: report.broken == 0 && unknown.isEmpty))
        }
    }

    // MARK: Inspector and Macie

    struct InspectorFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let severities: [String]?, limit: Int?, region: String?, account: String? }
        static let name = "inspector-findings"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Amazon Inspector's active findings, critical and high unless asked, most severe first: vulnerable packages and network reachability on instances, container images and Lambda functions, with the resource, its account and region, and whether an exploit and a fix are known; saying when more matched than were read, or when Inspector is off."
        static let input = JSONSchema.object([
            "severities": .array(.string("A severity.", oneOf: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNTRIAGED"]), "Severities. Critical and high when left out."),
            "limit": .integer("How many findings, at most. 25 when left out.", minimum: 1, maximum: 100), "region": AWS.regionInput, "account": AWS.accountInput,
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let severities = try (input.severities ?? ["CRITICAL", "HIGH"]).map { try ServiceInput.oneOf($0, ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNTRIAGED"], "severity") }
            let limit = try AWS.limit(input.limit, default: 25, maximum: 100)
            let target = try await AWS.target(.inspector2, region: input.region, account: input.account, on: service)
            struct Finding: Encodable { let arn: String, account: String?, region: String?, severity: String?, title: String?, type: String?, resource: String?, resourceType: String?, vulnerability: String?, exploitAvailable: String?, fixAvailable: String?, lastObserved: String? }
            var findings: [Finding] = [], token: String?, pages = 0, unreadable = 0
            do {
                repeat {
                    var body: [String: Any] = ["filterCriteria": ["severity": severities.map { ["comparison": "EQUALS", "value": $0] },
                                                                  "findingStatus": [["comparison": "EQUALS", "value": "ACTIVE"]]],
                                               "maxResults": 100, "sortCriteria": ["field": "SEVERITY", "sortOrder": "DESC"]]
                    if let token { body["nextToken"] = token }
                    let answer = try await AWS.read("Inspector's findings", needs: ["inspector2:ListFindings"]) { try await AWS.call(target, ["findings", "list"], body: body) }
                    guard case .object = answer, answer["findings"].map({ if case .array = $0 { true } else { false } }) != false else { throw ServiceError.unreadable }
                    pages += 1
                    findings += AWS.items(answer["findings"]).compactMap { json in
                        guard let arn = AWS.text(json["findingArn"]) else { unreadable += 1; return nil }
                        let resource = AWS.items(json["resources"]).first
                        return Finding(arn: arn, account: AWS.text(json["awsAccountId"]), region: AWS.text(resource?["region"]), severity: AWS.text(json["severity"]),
                                       title: AWS.text(json["title"]), type: AWS.text(json["type"]), resource: AWS.text(resource?["id"]), resourceType: AWS.text(resource?["type"]),
                                       vulnerability: AWS.text(json["packageVulnerabilityDetails"]?["vulnerabilityId"]), exploitAvailable: AWS.text(json["exploitAvailable"]),
                                       fixAvailable: AWS.text(json["fixAvailable"]), lastObserved: AWS.text(json["lastObservedAt"]))
                    }
                    token = AWS.text(answer["nextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                } while token != nil && findings.count < limit && pages < AWS.maximumPages
            } catch let error where AWS.isOff(error) {
                return try ServiceResult(text: "Amazon Inspector is not turned on in \(target.place), so it finds nothing there (AWS said: \(error.localizedDescription)). Other regions were not read.",
                                         structured: AWS.fields(["findings": [String](), "account": target.account.id, "region": target.region]))
            }
            let kept = Array(findings.prefix(limit))
            var lines = kept.isEmpty && unreadable == 0 && token == nil ? ["No active Inspector findings that are \(GoogleCloud.listed(severities)) in \(target.place). Other regions were not read; an account where Inspector is off finds nothing."]
                : kept.isEmpty && unreadable == 0 ? ["Inspector's listing in \(target.place) was not finished after \(pages) pages, none of which held a finding, so whether it has findings is not known: try again, or look in the Inspector console."]
                : kept.map { finding in
                    var line = "\(finding.severity ?? "?") \(finding.title ?? finding.arn)"
                    if let resource = finding.resource { line += " — \(finding.resourceType.map { "\($0) " } ?? "")\(resource)" }
                    if finding.exploitAvailable == "YES" { line += ", exploit known" }
                    if finding.fixAvailable == "YES" { line += ", fix available" }
                    if let account = finding.account, account != target.account.id { line += " in member account \(account)" }
                    return line
                }
            if unreadable > 0 { lines.append("\(unreadable) findings Inspector returned had no finding ARN and could not be read, so what they found is not known.") }
            if !kept.isEmpty, findings.count > kept.count || token != nil { lines.append("More findings matched than the \(kept.count) kept: narrow severities or raise the limit to see the rest.") }
            if !kept.isEmpty || unreadable > 0 { lines.append("Read \(target.place).") }
            struct Found: Encodable { let findings: [Finding]; let unreadable: Int; let account: String; let region: String; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Found(findings: kept, unreadable: unreadable, account: target.account.id, region: target.region,
                                                       complete: token == nil && findings.count <= kept.count && unreadable == 0))
        }
    }

    struct MacieFindings: ServiceOperation {
        struct Input: Decodable, Sendable { let limit: Int?, region: String?, account: String? }
        static let name = "macie-findings"
        static let jobs: Set<ToolJob> = [.audit]
        /// The most pages of finding IDs one lookup reads.
        static let pages = 5
        static let summary = "Amazon Macie's sensitive data findings that are not archived, newest first: which bucket and object hold what kind of sensitive data, such as credentials or personal information, and how much; saying when more matched than were read, or when Macie is off."
        static let input = JSONSchema.object([
            "limit": .integer("How many findings, at most. 25 when left out.", minimum: 1, maximum: 50), "region": AWS.regionInput, "account": AWS.accountInput,
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = try AWS.limit(input.limit, default: 25, maximum: 50)
            let target = try await AWS.target(.macie2, region: input.region, account: input.account, on: service)
            // A page may come back empty with a token for more: the listing is followed, within a bound, and only one
            // read to its end says there are none.
            var ids: [String] = [], token: String?, pages = 0
            do {
                repeat {
                    var body: [String: Any] = ["findingCriteria": ["criterion": ["category": ["eq": ["CLASSIFICATION"]], "archived": ["eq": ["false"]]]],
                                               "maxResults": limit - ids.count, "sortCriteria": ["attributeName": "updatedAt", "orderBy": "DESC"]]
                    if let token { body["nextToken"] = token }
                    let listed = try await AWS.read("Macie's findings", needs: ["macie2:ListFindings"]) { try await AWS.call(target, ["findings"], body: body) }
                    guard case .object = listed, listed["findingIds"].map({ if case .array = $0 { true } else { false } }) != false else { throw ServiceError.unreadable }
                    let listedIDs = AWS.items(listed["findingIds"])
                    let page = listedIDs.compactMap(\.text)
                    guard page.count == listedIDs.count else { throw ServiceError.unreadable }
                    ids += page
                    pages += 1
                    token = AWS.text(listed["nextToken"]).flatMap { $0.isEmpty ? nil : $0 }
                } while token != nil && ids.count < limit && pages < Self.pages
            } catch let error where AWS.isOff(error) {
                return try ServiceResult(text: "Amazon Macie is not turned on in \(target.place), so it finds nothing there (AWS said: \(error.localizedDescription)). Other regions were not read.",
                                         structured: AWS.fields(["findings": [String](), "account": target.account.id, "region": target.region]))
            }
            ids = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
            let more = token != nil || ids.count > limit
            ids = Array(ids.prefix(limit))
            struct Finding: Encodable { let id: String, account: String?, region: String?, severity: String?, type: String?, bucket: String?, object: String?, sensitive: [String], count: Int?, updatedAt: String? }
            var findings: [Finding] = []
            if !ids.isEmpty {
                let described = try await AWS.read("Macie's findings", needs: ["macie2:GetFindings"]) { try await AWS.call(target, ["findings", "describe"], body: ["findingIds": ids]) }
                guard case .array(let items)? = described["findings"] else { throw ServiceError.unreadable }
                findings = items.compactMap { json in
                    guard let id = AWS.text(json["id"]) else { return nil }
                    let sensitive = AWS.items(json["classificationDetails"]?["result"]?["sensitiveData"]).flatMap { category in
                        AWS.items(category["detections"]).compactMap { detection in
                            AWS.text(detection["type"]).map { "\($0) ×\(AWS.text(detection["count"]) ?? "?")" }
                        }
                    }
                    return Finding(id: id, account: AWS.text(json["accountId"]), region: AWS.text(json["region"]), severity: AWS.text(json["severity"]?["description"]),
                                   type: AWS.text(json["type"]), bucket: AWS.text(json["resourcesAffected"]?["s3Bucket"]?["name"]),
                                   object: AWS.text(json["resourcesAffected"]?["s3Object"]?["key"]), sensitive: sensitive,
                                   count: AWS.number(json["count"]).map { Int($0) }, updatedAt: AWS.text(json["updatedAt"]))
                }.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            }
            // Only a listing that came back empty says there are none; a finding listed whose details did not come back is said.
            let missing = Set(ids).subtracting(findings.map(\.id)).sorted()
            var lines = ids.isEmpty && !more ? ["No sensitive data findings that are not archived in \(target.place). Other regions were not read; Macie finds only in the buckets its discovery jobs and automated discovery cover."]
                : ids.isEmpty ? ["Macie's listing in \(target.place) was not finished after \(pages) pages, none of which held a finding, so whether it has findings is not known: try again, or look in the Macie console."]
                : findings.map { finding in
                    var line = "\(finding.updatedAt ?? "?") \(finding.severity ?? "?") \(finding.type ?? "?"): \(finding.bucket ?? "?")\(finding.object.map { "/\($0)" } ?? "")"
                    if !finding.sensitive.isEmpty { line += " — \(finding.sensitive.prefix(5).joined(separator: ", "))" }
                    if let account = finding.account, account != target.account.id { line += " in member account \(account)" }
                    return line
                }
            if !missing.isEmpty {
                lines.append("\(missing.count) of the \(ids.count) findings Macie listed came back without their details, so what they found is not known: read them again, or in the Macie console.")
            }
            if more, !ids.isEmpty { lines.append("More findings matched than the \(ids.count) listed: raise the limit to see the rest.") }
            if !ids.isEmpty { lines.append("Read \(target.place).") }
            struct Found: Encodable { let findings: [Finding]; let missingDetails: [String]; let account: String; let region: String; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Found(findings: findings, missingDetails: missing, account: target.account.id, region: target.region,
                                                                                           complete: !more && missing.isEmpty))
        }
    }
}
