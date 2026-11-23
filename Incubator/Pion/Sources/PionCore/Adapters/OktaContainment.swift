import Foundation
import NoodleCore
import NoodleToolConnections

/// Okta Containment: acting on one org to contain an incident, signed in through an Okta app of its own as an admin of
/// its own with a custom role of only the permissions its operations take, kept apart from Okta Audit's so the audit
/// sign-in stays read-only. Everything that cuts off or restores access, removes a factor, a group, a role, a grant or a token,
/// waits for the champion's approval, and each says how it is undone.
///
/// Okta takes no condition on a change, such as an ETag, so what Pion read before acting may have changed by the time
/// it acts: each result says when it read the user, and that another admin may have changed them since.
extension Okta {
    public static let containment = ToolDefinition(
        id: "59479ac0-7231-48fb-bb60-91ab2407c575", name: "Okta Containment",
        summary: "Suspend or deactivate a user, clear their sessions and OAuth tokens, reset their sign-in factors, expire their password, remove them from a group, revoke an admin role, their apps' grants or an API token.",
        defaultInstructions: """
        Use Okta Containment to contain an account in one Okta org. Find the user with Okta Audit first, then read them \
        here with user, which lists their status, admin roles with each assignment's ID, groups, sign-in factors with \
        their IDs and how many app grants they hold: record it as evidence before acting. Give each user by their full \
        Okta ID (00u…) or full login; Pion never acts on a short name, on the admin signed in to this connection, \
        or on a super administrator unless allowSuperAdmin is set because the champion confirmed it. suspend stops sign-in \
        but leaves sessions already open: clear-sessions ends them and revokes the OAuth tokens Okta issued the user, \
        though not the sessions apps keep for themselves. A typical containment is suspend, clear-sessions, \
        revoke-app-grants and, if the factors may be the attacker's, reset-factors. expire-password does not stop a \
        stolen password on its own, as whoever signs in first with it chooses the new one: pair it with suspend. It \
        never makes a temporary password; if the user needs one, the champion issues it in the Okta Admin Console. deactivate deprovisions the user from every app and may destroy their data there, so it runs \
        only with confirmDeprovision and is rarely the right first step. remove-from-group and revoke-admin-role act only \
        on memberships and roles the user holds directly, never through an app or a group rule. revoke-api-token ends a \
        token for good. All of these, unsuspend included, as restoring access can let an attacker back in, are held for \
        the champion's approval: give the exact user, and in --approval-reason why, the expected effect and how to undo \
        it, with the Investigation as --approval-conversation. Each result says what changed step by step, what did not \
        and how to recover it. Run check-access when something is refused, and tell the champion exactly what it says \
        to add to the admin's role.
        """,
        iconName: "okta",
        configuration: .connection(.init(endpointTemplate: "https://{domain}/api/v1", fields: fields,
                                  oauth: oauth(scopes: containmentScopes), oauthClientField: "clientID", oauthHostField: "domain",
                                  adapter: "okta-containment")),
        setup: containmentSetup)

    /// The scopes its operations take, each of which also reads what it covers: users, their lifecycle, sessions,
    /// factors, password and grants, and the signed-in admin; group memberships; admin roles; API tokens.
    static let containmentScopes = ["okta.users.manage", "okta.users.read.self", "okta.groups.manage", "okta.roles.manage", "okta.apiTokens.manage"]

    /// The custom role's permissions, by Okta's names, with what each lets this tool do.
    static let containmentPermissions: [(permission: String, use: String)] = [
        ("okta.users.read", "read users"), ("okta.groups.read", "read groups"), ("okta.iam.read", "see who is a super administrator and read admin roles"),
        ("okta.users.lifecycle.suspend", "suspend"), ("okta.users.lifecycle.unsuspend", "unsuspend"), ("okta.users.lifecycle.deactivate", "deactivate"),
        ("okta.users.lifecycle.clearSessions", "clear-sessions"), ("okta.users.credentials.resetFactors", "reset-factors and delete-factor"),
        ("okta.users.credentials.expirePassword", "expire-password"), ("okta.users.groupMembership.manage", "remove-from-group"),
        ("okta.users.apitokens.clear", "revoke-api-token"),
    ]

    static let containmentSetup = appSteps("Pion Containment", scopes: containmentScopes) + [
        "Okta allows a request only when both the app's scopes and the signed-in admin's role allow it, so the role is what limits this tool. Keep an admin for Pion Containment alone, such as pion-containment@example.com, apart from Okta Audit's.",
        "Under **Security › Administrators › Roles**, create a role such as **Pion Containment** with only these permissions: \(containmentPermissions.map { "`\($0.permission)`" }.joined(separator: ", ")). Leave out any whose action you do not want agents to have.",
        "Under **Security › Administrators › Resources**, make a resource set of all users and all groups, and assign the role with it to that admin. Never make it a super or organization administrator. Revoking admin roles and users' app grants has no custom-role permission, so those two are refused unless you choose to give more.",
        "Give your org's domain, such as `acme.okta.com`, and the app's **Client ID**. Choose **Add & Connect** and sign in as that admin. Then ask an agent to run check-access.",
    ]

    public static let containmentAdapter = OperationAdapter(operations: [
        ContainmentUser(), Suspend(), Unsuspend(), Deactivate(), ClearSessions(), ResetFactors(), DeleteFactor(), ExpirePassword(),
        RemoveFromGroup(), RevokeAdminRole(), RevokeAppGrants(), RevokeAPIToken(), ContainmentCheckAccess(),
    ], simultaneousRequests: 4)

    // MARK: Who is acted on

    /// The user an action is for, as read just before it: never a short name, never the signed-in admin, and never a
    /// super administrator unless asked.
    struct Target {
        let user: User, roles: [Role]?, readAt: String
        var login: String { user.profile?.login ?? user.id }
        var named: String { "\(login) (\(user.id))" }
    }

    static func target(_ value: String, allowSuperAdmin: Bool?, on service: ServiceClient) async throws -> Target {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isID = (try? userID(value)) != nil
        let isLogin = value.count <= 100 && value.contains("@") && !value.contains(where: { $0.isWhitespace || "/?#\\\"".contains($0) })
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        guard isID || isLogin else {
            throw ServiceError.input("Nothing was changed: give the user's full Okta ID (00u and 17 more letters and digits) or full login, such as name@example.com. Pion does not act on a short name, which Okta resolves loosely.")
        }
        let user = try await read(.users) { try await get(service, ["users", value], as: User.self) }
        guard user.id == value || user.profile?.login?.lowercased() == value.lowercased() else {
            throw ServiceError.input("Nothing was changed: Okta resolved \(value) to \(user.profile?.login ?? "?") (\(user.id)), not exactly the user given.")
        }
        _ = try userID(user.id)
        // The admin the sign-in is for, as Okta reads it from the access token.
        let me = try await read(.signedIn) { try await get(service, ["users", "me"], as: User.self) }
        guard me.id != user.id else {
            throw ServiceError.input("Nothing was changed: \(value) is the admin signed in to this connection, and Pion does not act on its own sign-in. Contain them in the Admin Console, and sign Okta Containment in as another admin.")
        }
        var roles: [Role]?
        do { roles = try await get(service, ["users", user.id, "roles"], as: [Role].self) } catch {
            guard allowSuperAdmin == true else {
                throw ServiceError.input("Nothing was changed: whether \(user.profile?.login ?? user.id) is a super administrator could not be read (\(error.localizedDescription)). Give the containment admin okta.iam.read and its Okta app okta.roles.manage, as check-access says, or set allowSuperAdmin once the champion confirms acting on a super administrator is intended.")
            }
        }
        if roles?.contains(where: { $0.type == "SUPER_ADMIN" }) == true, allowSuperAdmin != true {
            throw ServiceError.input("Nothing was changed: \(user.profile?.login ?? user.id) is a super administrator. Act on them only when the champion confirms, with allowSuperAdmin set; the containment admin's role may not allow it either.")
        }
        return Target(user: user, roles: roles, readAt: iso(Date()))
    }

    /// One step of an action, as its result reports it.
    struct Step: Codable { let action: String; let done: Bool; let detail: String }

    struct Outcome: Encodable {
        let user: String?, login: String?, readAt: String?, steps: [Step], recovery: String, details: [String: String]
    }

    /// What an action came to: each step, done or not, how to recover, and when the user was read.
    static func outcome(_ target: Target?, steps: [Step], recovery: String, details: [String: String] = [:], note: String? = nil) throws -> ServiceResult {
        // Nothing done is a failure the bot sees as one; part done is a result saying which part.
        if !steps.contains(where: \.done), let failed = steps.first(where: { !$0.done }) {
            throw ServiceError.input("Nothing was changed. " + failed.detail)
        }
        var lines = steps.map { ($0.done ? "✓ " : "✗ ") + $0.detail }
        if let note { lines.append(note) }
        lines.append(recovery)
        if let target {
            lines.append("\(target.named) was read at \(target.readAt). Okta takes no condition on a change, so another admin may have changed them between that read and this change.")
        }
        return try ServiceResult(text: lines.joined(separator: "\n"),
                                 structured: Outcome(user: target?.user.id, login: target?.login, readAt: target?.readAt, steps: steps, recovery: recovery, details: details))
    }

    /// Runs changes in turn, stopping at the first that fails, and says which were made, which failed and which were not
    /// tried.
    static func inTurn(_ changes: [(action: String, describe: String, run: () async throws -> Void)]) async -> (steps: [Step], failed: Bool) {
        var steps: [Step] = [], failed = false
        for change in changes {
            if failed { steps.append(Step(action: change.action, done: false, detail: "Not tried, after the failure above: \(change.describe).")); continue }
            do {
                try await change.run()
                steps.append(Step(action: change.action, done: true, detail: change.describe.prefix(1).uppercased() + change.describe.dropFirst() + "."))
            } catch {
                failed = true
                steps.append(Step(action: change.action, done: false, detail: "Failed to \(change.describe): \(error.localizedDescription)"))
            }
        }
        return (steps, failed)
    }

    /// The values once each, in the order first given.
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    struct UserInput: Decodable, Sendable { let user: String; let allowSuperAdmin: Bool? }
    static let userField = JSONSchema.string("The user's full Okta ID (00u…) or full login.")
    static let superAdminField = JSONSchema.boolean("Act even though the user is a super administrator. Only when the champion has confirmed it.")
    static let userSchema = JSONSchema.object(["user": userField, "allowSuperAdmin": superAdminField], required: ["user"])

    // MARK: Reading

    struct ContainmentUser: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user"
        static let summary = "A user's state before acting: status, last sign-in, admin roles with each assignment's ID and whether held through a group, groups with their IDs and types, sign-in factors with their IDs, and how many apps they granted access. It changes nothing."
        static let input = JSONSchema.object(["user": Okta.userField], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try await Okta.resolve(input.user, on: service)
            struct Group: Codable { struct Profile: Codable { let name: String? }; let id: String; let type: String?; let profile: Profile? }
            struct Factor: Codable { let id: String; let factorType: String?; let provider: String?; let status: String? }
            var lines = [UserSummary(user).sentence + "."], gaps: [String] = []
            let roles: [Role]? = try? await Okta.get(service, ["users", user.id, "roles"], as: [Role].self)
            if let roles {
                lines.append(roles.isEmpty ? "No admin roles." : "Admin roles: " + roles.map {
                    "\($0.label ?? $0.type ?? "?") [assignment \($0.id ?? "?")]\($0.assignmentType == "GROUP" ? " through a group" : "")"
                }.joined(separator: ", ") + ".")
            } else { gaps.append("admin roles") }
            var groups: Listing<Group>?
            do { groups = try await Okta.list(service, ["users", user.id, "groups"], query: ["limit": "200"], as: Group.self) } catch { gaps.append("groups") }
            if let groups {
                lines.append(groups.value.isEmpty ? "No groups." : "Groups: " + groups.value.map {
                    "\($0.profile?.name ?? "?") [\($0.id)]\($0.type == "OKTA_GROUP" ? "" : " (\($0.type ?? "?"), not changeable here)")"
                }.joined(separator: ", ") + "." + Okta.stopped(groups, "groups"))
            }
            let factors: [Factor]? = try? await Okta.get(service, ["users", user.id, "factors"], as: [Factor].self)
            if let factors {
                lines.append(factors.isEmpty ? "No sign-in factors." : "Factors: " + factors.map { "\($0.factorType ?? "?") \($0.status ?? "") [\($0.id)]" }.joined(separator: ", ") + ".")
            } else { gaps.append("factors") }
            var grants: Listing<UserGrants.Grant>?
            do { grants = try await Okta.list(service, ["users", user.id, "grants"], query: ["limit": "200"], as: UserGrants.Grant.self) } catch { gaps.append("grants") }
            if let grants {
                let clients = Set(grants.value.compactMap(\.clientId))
                lines.append("\(grants.value.count) app grant\(grants.value.count == 1 ? "" : "s") to \(clients.count) app\(clients.count == 1 ? "" : "s")\(grants.complete ? "" : ", more not read").")
            }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: ", ")); check-access says what the admin lacks.") }
            lines.append("Read at \(Okta.iso(Date())).")
            struct Kept: Encodable {
                let user: UserSummary; let roles: [Role]?; let groups: [Group]?; let factors: [Factor]?; let grants: Int?; let couldNotRead: [String]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(user: UserSummary(user), roles: roles, groups: groups?.value, factors: factors,
                                                      grants: grants?.value.count, couldNotRead: gaps))
        }
    }

    // MARK: Lifecycle

    struct Suspend: ServiceOperation {
        typealias Input = UserInput
        static let name = "suspend"
        static let recovery = "Recovery: unsuspend restores sign-in, with the user's groups and apps as they were; sessions ended meanwhile are not restored. Suspending does not end sessions already open: clear-sessions does."
        static let summary = "Suspend an active user, so they cannot sign in to Okta. \(recovery)"
        static let input = Okta.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            guard target.user.status != "SUSPENDED" else { throw ServiceError.input("Nothing was changed: \(target.named) is already suspended.") }
            guard target.user.status != "DEPROVISIONED" else { throw ServiceError.input("Nothing was changed: \(target.named) is deactivated, which already stops sign-in.") }
            let (steps, _) = await Okta.inTurn([("suspend", "suspend \(target.named), who was \(target.user.status ?? "of unknown status")", {
                _ = try await Okta.exchange(service, ["users", target.user.id, "lifecycle", "suspend"], method: "POST")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct Unsuspend: ServiceOperation {
        typealias Input = UserInput
        static let name = "unsuspend"
        static let recovery = "Recovery: suspend again. Restoring access can let an attacker back in, so before it reset their factors and password and revoke their app grants, as the champion decides."
        static let summary = "Restore a suspended user's sign-in. Held like the rest, as it gives access back. \(recovery)"
        static let input = Okta.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            guard target.user.status == "SUSPENDED" else { throw ServiceError.input("Nothing was changed: \(target.named) is \(target.user.status ?? "of unknown status"), not suspended.") }
            let (steps, _) = await Okta.inTurn([("unsuspend", "unsuspend \(target.named)", {
                _ = try await Okta.exchange(service, ["users", target.user.id, "lifecycle", "unsuspend"], method: "POST")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct Deactivate: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let allowSuperAdmin: Bool?; let confirmDeprovision: Bool? }
        static let name = "deactivate"
        static let recovery = "Recovery: there is no simple undo. Okta deprovisions the user from every app, which may delete their data there; reactivating needs a new activation, and their app access and data must be restored by hand. Prefer suspend."
        static let summary = "Deactivate a user, only with confirmDeprovision set: it ends their sign-in and deprovisions them from every app. \(recovery)"
        static let input = JSONSchema.object(["user": Okta.userField, "allowSuperAdmin": Okta.superAdminField,
                                              "confirmDeprovision": .boolean("Must be true: confirms the champion wants the user deprovisioned from every app.")],
                                             required: ["user", "confirmDeprovision"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard input.confirmDeprovision == true else {
                throw ServiceError.input("Nothing was changed: deactivate runs only with confirmDeprovision set to true, as it deprovisions the user from every app. Suspend instead unless the champion asked for this.")
            }
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            guard target.user.status != "DEPROVISIONED" else { throw ServiceError.input("Nothing was changed: \(target.named) is already deactivated.") }
            let (steps, _) = await Okta.inTurn([("deactivate", "deactivate \(target.named), who was \(target.user.status ?? "of unknown status")", {
                _ = try await Okta.exchange(service, ["users", target.user.id, "lifecycle", "deactivate"], query: ["sendEmail": "false"], method: "POST")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery,
                                    note: "Okta may finish deprovisioning in the background; read the user again to see it done.")
        }
    }

    struct ClearSessions: ServiceOperation {
        typealias Input = UserInput
        static let name = "clear-sessions"
        static let recovery = "Recovery: nothing to restore; the user signs in afresh, and OAuth apps need a new sign-in and re-consent. Sessions apps keep for themselves are not ended by Okta: end those in each app."
        static let summary = "End every Okta session of a user, revoke the OAuth and OpenID Connect tokens Okta issued them and forget their remembered devices. \(recovery)"
        static let input = Okta.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            let (steps, _) = await Okta.inTurn([("clear-sessions", "end every Okta session of \(target.named), revoke the OAuth tokens Okta issued them and forget their remembered devices", {
                _ = try await Okta.exchange(service, ["users", target.user.id, "sessions"], query: ["oauthTokens": "true", "forgetDevices": "true"], method: "DELETE")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    // MARK: Factors and password

    struct ResetFactors: ServiceOperation {
        typealias Input = UserInput
        static let name = "reset-factors"
        static let recovery = "Recovery: the user must re-enroll every MFA factor at their next sign-in, so make sure it is them, as whoever signs in next enrolls."
        static let summary = "Reset all of a user's sign-in factors, so an attacker's push, phone or key no longer works, listing those removed. \(recovery)"
        static let input = Okta.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            struct Factor: Decodable { let id: String; let factorType: String?; let provider: String? }
            let factors = try await Okta.read(.users) { try await Okta.get(service, ["users", target.user.id, "factors"], as: [Factor].self) }
            guard !factors.isEmpty else { throw ServiceError.input("Nothing was changed: \(target.named) has no sign-in factors enrolled.") }
            let named = factors.map { "\($0.factorType ?? "?") (\($0.provider ?? "?")) [\($0.id)]" }.joined(separator: ", ")
            let (steps, _) = await Okta.inTurn([("reset-factors", "reset every sign-in factor of \(target.named): \(named)", {
                _ = try await Okta.exchange(service, ["users", target.user.id, "lifecycle", "reset_factors"], method: "POST")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery, details: ["factors": named])
        }
    }

    struct DeleteFactor: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let factor: String; let allowSuperAdmin: Bool? }
        static let name = "delete-factor"
        static let recovery = "Recovery: the user must enroll that factor again."
        static let summary = "Remove one of a user's sign-in factors, by its ID from user, such as a phone an attacker enrolled. \(recovery)"
        static let input = JSONSchema.object(["user": Okta.userField, "factor": .string("The factor's ID, as user lists it."), "allowSuperAdmin": Okta.superAdminField],
                                             required: ["user", "factor"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let factor = try Okta.id(input.factor, "the factor")
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            struct Factor: Decodable { let id: String; let factorType: String?; let provider: String? }
            let factors = try await Okta.read(.users) { try await Okta.get(service, ["users", target.user.id, "factors"], as: [Factor].self) }
            guard let found = factors.first(where: { $0.id == factor }) else {
                throw ServiceError.input("Nothing was changed: \(target.named) has no factor \(factor); user lists theirs.")
            }
            let (steps, _) = await Okta.inTurn([("delete-factor", "remove \(found.factorType ?? "the") factor (\(found.provider ?? "?")) [\(factor)] of \(target.named)", {
                _ = try await Okta.exchange(service, ["users", target.user.id, "factors", factor], method: "DELETE")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery, details: ["factor": factor])
        }
    }

    /// Forces a password change at the next sign-in, and nothing more: Pion never asks Okta for a temporary password,
    /// as one would land in the tool's result and the conversation, usable by anyone who reads it. An admin who needs
    /// one issues it in the Admin Console. Okta's answer is not read.
    struct ExpirePassword: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let allowSuperAdmin: Bool? }
        static let name = "expire-password"
        static let recovery = "Recovery: the user must change their password at their next sign-in. Expiry alone does not stop a stolen password, as whoever signs in first with it chooses the new one: suspend or clear sessions too. If the user needs a temporary password, an admin issues one in the Okta Admin Console; Pion never makes one."
        static let summary = "Expire a user's password, so it must be changed at their next sign-in. \(recovery)"
        static let input = Okta.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            let (steps, _) = await Okta.inTurn([("expire-password", "expire the password of \(target.named), to be changed at the next sign-in", {
                _ = try await Okta.exchange(service, ["users", target.user.id, "lifecycle", "expire_password"], method: "POST")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    // MARK: Groups, roles, grants and tokens

    struct RemoveFromGroup: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let groups: [String]; let allowSuperAdmin: Bool? }
        static let name = "remove-from-group"
        static let recovery = "Recovery: re-add the user to each group by hand; a group rule may add them back by itself, so check the group's rules."
        static let summary = "Remove a user from one or more Okta groups, by their IDs from user, ending the apps and roles each gave; checks every group first and reports each removal. \(recovery)"
        static let input = JSONSchema.object(["user": Okta.userField, "groups": .array(.string("A group's ID, 00g…."), "Between 1 and 20 groups."),
                                              "allowSuperAdmin": Okta.superAdminField], required: ["user", "groups"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let groups = try ServiceInput.list(input.groups, limit: 20, Okta.groupID)
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            struct Group: Decodable { struct Profile: Decodable { let name: String? }; let id: String; let type: String?; let profile: Profile? }
            let held = try await Okta.read(.groups) {
                try await Okta.list(service, ["users", target.user.id, "groups"], query: ["limit": "200"], as: Group.self)
            }
            // Every group is checked before any is changed.
            var refused: [String] = [], named: [String: String] = [:]
            for id in Okta.unique(groups) {
                guard let group = held.value.first(where: { $0.id == id }) else {
                    refused.append("\(id): \(held.complete ? "not one of the user's groups" : "not among the user's groups read")"); continue
                }
                guard group.type == "OKTA_GROUP" else { refused.append("\(group.profile?.name ?? id): an \(group.type ?? "unknown") group, whose members Okta takes from an app or itself"); continue }
                named[id] = group.profile?.name ?? id
            }
            guard refused.isEmpty else { throw ServiceError.input("Nothing was changed: " + refused.joined(separator: "; ") + ".") }
            let order = Okta.unique(groups)
            let (steps, failed) = await Okta.inTurn(order.map { id in
                ("remove-from-group", "remove \(target.named) from \(named[id] ?? id) [\(id)]", {
                    _ = try await Okta.exchange(service, ["groups", id, "users", target.user.id], method: "DELETE")
                })
            })
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery,
                                    note: failed ? "Only part of the change was made: the steps above say which groups the user left." : nil)
        }
    }

    struct RevokeAdminRole: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let assignments: [String]; let allowSuperAdmin: Bool? }
        static let name = "revoke-admin-role"
        static let recovery = "Recovery: re-assign each role by hand in Security › Administrators."
        static let summary = "Revoke one or more admin roles a user holds directly, by their assignment IDs from user; roles held through a group are refused, as they are the group's. Okta lets only a super administrator do this. \(recovery)"
        static let input = JSONSchema.object(["user": Okta.userField, "assignments": .array(.string("A role assignment's ID, as user lists it."), "Between 1 and 20 assignments."),
                                              "allowSuperAdmin": Okta.superAdminField], required: ["user", "assignments"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let wanted = Okta.unique(try ServiceInput.list(input.assignments, limit: 20) { try Okta.id($0, length: 1...64, "the role assignment") })
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            guard let roles = target.roles else {
                throw ServiceError.input("Nothing was changed: \(target.named)'s admin roles could not be read, so which to revoke cannot be checked; check-access says what the admin lacks.")
            }
            var refused: [String] = []
            for id in wanted {
                guard let role = roles.first(where: { $0.id == id }) else { refused.append("\(id): not one of the user's role assignments"); continue }
                if role.assignmentType == "GROUP" { refused.append("\(role.label ?? id): held through a group; remove it from the group, or the user from the group, instead") }
            }
            guard refused.isEmpty else { throw ServiceError.input("Nothing was changed: " + refused.joined(separator: "; ") + ".") }
            let (steps, failed) = await Okta.inTurn(wanted.map { id in
                let role = roles.first { $0.id == id }
                return ("revoke-admin-role", "revoke \(role?.label ?? role?.type ?? "the role") [\(id)] from \(target.named)", {
                    _ = try await Okta.exchange(service, ["users", target.user.id, "roles", id], method: "DELETE")
                })
            })
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery,
                                    note: failed ? "Only part of the change was made: the steps above say which roles were revoked." : nil)
        }
    }

    struct RevokeAppGrants: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let grant: String?; let allowSuperAdmin: Bool? }
        static let name = "revoke-app-grants"
        static let recovery = "Recovery: the user must consent to each app again; an admin-granted consent must be granted again by an admin."
        static let summary = "Revoke every OAuth grant a user gave apps, or one by its ID from Okta Audit's user-grants, so the apps can no longer act for them. \(recovery)"
        static let input = JSONSchema.object(["user": Okta.userField, "grant": .string("Only this grant's ID. Every grant when left out."),
                                              "allowSuperAdmin": Okta.superAdminField], required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let grant = try input.grant.map { try Okta.id($0, "the grant") }
            let target = try await Okta.target(input.user, allowSuperAdmin: input.allowSuperAdmin, on: service)
            let held = try await Okta.read(.users) {
                try await Okta.list(service, ["users", target.user.id, "grants"], query: ["limit": "200"], as: UserGrants.Grant.self)
            }
            if let grant, !held.value.contains(where: { $0.id == grant }), held.complete {
                throw ServiceError.input("Nothing was changed: \(target.named) holds no grant \(grant).")
            }
            guard grant != nil || !held.value.isEmpty || !held.complete else { throw ServiceError.input("Nothing was changed: \(target.named) has granted no apps access.") }
            let clients = Set(held.value.filter { grant == nil || $0.id == grant }.compactMap(\.clientId)).sorted()
            let what = grant.map { "revoke grant \($0) of \(target.named)" }
                ?? "revoke every app grant of \(target.named): \(held.value.count)\(held.complete ? "" : " or more") grants to \(clients.joined(separator: ", "))"
            let (steps, _) = await Okta.inTurn([("revoke-app-grants", what, {
                _ = try await Okta.exchange(service, ["users", target.user.id, "grants"] + (grant.map { [$0] } ?? []), method: "DELETE")
            })])
            return try Okta.outcome(target, steps: steps, recovery: Self.recovery, details: ["clients": clients.joined(separator: ",")])
        }
    }

    struct RevokeAPIToken: ServiceOperation {
        struct Input: Decodable, Sendable { let token: String }
        static let name = "revoke-api-token"
        static let recovery = "Recovery: none. A revoked token is gone for good; whatever used it needs a new token made by an admin."
        static let summary = "Revoke one API token, by its ID from Okta Audit's api-tokens, saying whose it was. This connection signs in through OAuth, not with an API token. \(recovery)"
        static let input = JSONSchema.object(["token": .string("The API token's ID, 00T….")], required: ["token"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try Okta.tokenID(input.token)
            let token = try await Okta.read(.tokens) { try await Okta.get(service, ["api-tokens", id], as: APITokens.Token.self) }
            let owner = token.userId.map { "made by \($0)" } ?? "of unknown maker"
            let (steps, _) = await Okta.inTurn([("revoke-api-token", "revoke API token \(token.name ?? id) [\(id)], \(owner)", {
                _ = try await Okta.exchange(service, ["api-tokens", id], method: "DELETE")
            })])
            return try Okta.outcome(nil, steps: steps, recovery: Self.recovery, details: ["token": id, "owner": token.userId ?? ""],
                                    note: "Read at \(Okta.iso(Date())). Okta takes no condition on a change, so the token may have changed between that read and this.")
        }
    }

    // MARK: Access

    /// Which permissions, any of them, let each operation run, by Okta's names; standard roles are judged apart.
    static let containmentNeeds: [(operation: String, any: [String])] = [
        ("user", ["okta.users.read", "okta.users.manage"]),
        ("super administrator check and revoke-admin-role's read", ["okta.iam.read"]),
        ("suspend", ["okta.users.lifecycle.suspend", "okta.users.lifecycle.manage", "okta.users.manage"]),
        ("unsuspend", ["okta.users.lifecycle.unsuspend", "okta.users.lifecycle.manage", "okta.users.manage"]),
        ("deactivate", ["okta.users.lifecycle.deactivate", "okta.users.lifecycle.manage", "okta.users.manage"]),
        ("clear-sessions", ["okta.users.lifecycle.clearSessions", "okta.users.lifecycle.manage", "okta.users.manage"]),
        ("reset-factors and delete-factor", ["okta.users.credentials.resetFactors", "okta.users.credentials.manage", "okta.users.manage"]),
        ("expire-password", ["okta.users.credentials.expirePassword", "okta.users.credentials.manage", "okta.users.manage"]),
        ("remove-from-group", ["okta.users.groupMembership.manage", "okta.groups.members.manage", "okta.groups.manage", "okta.users.manage"]),
        ("revoke-api-token", ["okta.users.apitokens.clear", "okta.users.apitokens.manage"]),
    ]

    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let summary = "Reads the admin roles of the signed-in admin and says which containment operations they allow, what permission to add for the rest, and when they allow far more; and which scopes the sign-in holds. It changes nothing."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (me, roles) = try await Okta.read(.admins) { try await Okta.signedIn(service) }
            var lines = ["· Signed in as \(me.profile?.login ?? me.id), who holds \(roles.isEmpty ? "no admin role" : roles.map { $0.label ?? $0.type ?? "?" }.joined(separator: ", "))."]
            let types = Set(roles.compactMap(\.type))
            var held = Set<String>(), unread: [String] = []
            for role in roles where role.type == "CUSTOM" {
                guard let custom = role.role else { continue }
                do { held.formUnion(try await Okta.permissions(custom, service)) } catch { unread.append("\(role.label ?? custom): \(error.localizedDescription)") }
            }
            if types.contains("SUPER_ADMIN") {
                lines.append("⚠ The admin is a super administrator: every operation works, and whatever its scopes allow besides is possible with this sign-in. Sign Okta Containment in as an admin of its own with only the custom role its Setup Steps list.")
            } else {
                if types.contains("ORG_ADMIN") {
                    lines.append("⚠ The admin is an organization administrator, which allows most of these and much more besides; a custom role with only the listed permissions is safer.")
                }
                for need in Okta.containmentNeeds {
                    if types.contains("ORG_ADMIN") || need.any.contains(where: held.contains) { lines.append("✓ \(need.operation)") }
                    else { lines.append("✗ \(need.operation): add \(need.any[0]) to the admin's custom role.") }
                }
                lines.append("✗ revoke-admin-role: Okta lets only a super administrator revoke admin roles, which this setup does not give; hand it to a super administrator.")
                lines.append(types.contains("ORG_ADMIN") ? "· revoke-app-grants: may work for an organization administrator; Okta refuses it if not."
                    : "✗ revoke-app-grants: no custom-role permission covers users' app grants, so Okta refuses it to this admin; hand it to an organization or super administrator.")
                let broad = held.filter { ["okta.users.manage", "okta.groups.manage", "okta.apps.manage", "okta.policies.manage", "okta.authzServers.manage", "okta.users.credentials.manage"].contains($0) }
                if !broad.isEmpty { lines.append("⚠ The custom role holds broad permissions besides these: \(broad.sorted().joined(separator: ", ")); narrow it to the ones listed.") }
                for line in unread { lines.append("· A custom role's permissions could not be read, so it counts as none: \(line)") }
                lines.append("· The custom role's resource set decides which users and groups these apply to; Okta refuses users outside it, and lets only a super administrator act on another admin.")
            }
            lines.append(Okta.scopesLine(Okta.containmentScopes, service))
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
