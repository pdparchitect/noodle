import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Entra ID Containment: acting on one tenant to contain an incident, signed in through an app registration of
/// its own as an admin of its own with only the roles its operations take, kept apart from Detection's so the detection sign-in
/// stays read-only. Everything that cuts off or restores access, removes a sign-in method, a role or an app's
/// credential, or changes what Identity Protection says of a user, waits for the champion's approval, and each says how
/// it is undone.
///
/// Microsoft Graph takes no condition on these changes, such as an ETag, so what Pion read before acting may have
/// changed by the time it acts: each result says when it read what it acted on, and that another admin may have changed
/// it since. It removes only an app's secrets, each by its keyId alone, never its certificates.
extension Entra {
    public static let containment = ToolDefinition(
        id: "df933b80-f68d-4122-967b-7ee61f62b80d", name: "Microsoft Entra ID Containment",
        summary: "Disable or restore a user's sign-in, revoke their sessions, delete their sign-in methods, remove a directory role, remove an app's client secret, and confirm a user compromised or dismiss their risk.",
        defaultInstructions: """
        Use Microsoft Entra ID Containment to contain an account in one Microsoft tenant. Find the user with Microsoft \
        Entra ID Detection first, then read them here with user, which lists whether they can sign in, their active and \
        eligible directory roles with each assignment's ID, their sign-in methods with their IDs, Identity Protection's \
        risk and whether they are a Global Administrator: record it as evidence before acting. Give each user by their \
        object ID (a GUID) or full user principal name; Pion never acts on the admin signed in to this connection, or on \
        a Global Administrator unless allowGlobalAdmin is set because the champion confirmed it. disable-sign-in stops new \
        sign-ins but leaves sessions open: revoke-sessions invalidates their refresh tokens and session cookies, though \
        access tokens already issued last until they expire, usually within an hour. A typical containment is \
        disable-sign-in, revoke-sessions, confirm-compromised and, if the methods may be the attacker's, \
        delete-sign-in-methods. A user synced from on-premises Active Directory is disabled there, not here. \
        remove-directory-role removes active role assignments and eligibility in Privileged Identity Management the user \
        holds directly, never through a group. remove-app-credential removes one client secret from an app registration or \
        enterprise app by its keyId from Detection's app-credentials; it refuses a certificate, which Graph removes only with \
        proof Pion does not hold, and says how the champion removes it in the portal. All of these, enable-sign-in and \
        dismiss-user-risk included, as restoring access or hiding risk can let an attacker back in, are held for the \
        champion's approval: give the exact user, and in --approval-reason why, the expected effect and how to undo it, \
        with the Investigation as --approval-conversation. Each result says what changed step by step, what did not and \
        how to recover it. Run check-access when something is refused, and tell the champion exactly what it says to add.
        """,
        iconName: "entra",
        configuration: .connection(.init(endpointTemplate: "https://graph.microsoft.com/v1.0", fields: fields,
                                         oauth: oauth(scopes: containmentScopes), oauthClientField: "clientID", oauthPathField: "tenant", oauthPathExcludes: generic,
                                         adapter: "entra-containment")),
        setup: containmentSetup)

    /// The delegated permissions its operations take, each the narrowest Graph has: reading users; disabling and
    /// enabling them; revoking their sessions; their sign-in methods; directory roles and eligibility; apps' credentials;
    /// risky users; and the members of groups that hold Global Administrator.
    static let containmentScopes = ["User.Read.All", "User.EnableDisableAccount.All", "User.RevokeSessions.All", "UserAuthenticationMethod.ReadWrite.All",
                                    "RoleManagement.ReadWrite.Directory", "Application.ReadWrite.All", "IdentityRiskyUser.ReadWrite.All", "GroupMember.Read.All"]

    /// The admin roles that let the signed-in admin run each operation, by name, the narrowest first.
    static let containmentRoles: [(operation: String, any: [String])] = [
        ("disable-sign-in, enable-sign-in and revoke-sessions", ["Privileged Authentication Administrator", "User Administrator"]),
        ("delete-sign-in-methods", ["Privileged Authentication Administrator", "Authentication Administrator"]),
        ("remove-directory-role", ["Privileged Role Administrator"]),
        ("remove-app-credential", ["Cloud Application Administrator", "Application Administrator"]),
        ("confirm-compromised and dismiss-user-risk", ["Security Operator", "Security Administrator"]),
    ]

    static let containmentSetup = appSteps("Pion Containment", scopes: containmentScopes) + [
        "Microsoft allows a request only when both the app's permissions and the signed-in admin's role allow it, so the roles are what limit this tool. Keep an admin for Pion Containment alone, such as pion-containment@contoso.com, apart from Pion Detection's.",
        "Give that admin only these roles, leaving out any whose action you do not want agents to have: **Privileged Authentication Administrator** (disable, enable and revoke sessions for any user, and delete their sign-in methods), **Privileged Role Administrator** (remove directory roles), **Cloud Application Administrator** (remove apps' client secrets) and **Security Operator** (confirm or dismiss a user's risk). Better, make them eligible in Privileged Identity Management and activate them when containing. Never make the admin a Global Administrator.",
        "Confirming or dismissing risk needs Microsoft Entra ID P2. Give the **Directory (tenant) ID** and the app's **Application (client) ID**. Choose **Add & Connect** and sign in as that admin. Then ask an agent to run check-access.",
    ]

    public static let containmentAdapter = OperationAdapter(operations: operations, job: .containment, simultaneousRequests: 4)

    // MARK: What it needs

    static let usersNeed = Need(title: "Users", scope: "User.Read.All", role: "any admin role, such as Privileged Authentication Administrator")
    static let accountNeed = Need(title: "Enabling or disabling sign-in", scope: "User.EnableDisableAccount.All",
                                  role: "Privileged Authentication Administrator, or User Administrator for a user without admin roles")
    static let sessionsNeed = Need(title: "Revoking sessions", scope: "User.RevokeSessions.All",
                                   role: "Privileged Authentication Administrator, or User Administrator for a user without admin roles")
    static let methodsNeed = Need(title: "Sign-in methods", scope: "UserAuthenticationMethod.ReadWrite.All",
                                  role: "Privileged Authentication Administrator, or Authentication Administrator for a user without admin roles")
    static let rolesNeed = Need(title: "Directory roles", scope: "RoleManagement.ReadWrite.Directory", role: "Privileged Role Administrator")
    static let eligibleNeed = Need(title: "Eligible roles in Privileged Identity Management", scope: "RoleManagement.ReadWrite.Directory",
                                   role: "Privileged Role Administrator", licence: "Microsoft Entra ID P2")
    static let appsNeed = Need(title: "Apps' secrets", scope: "Application.ReadWrite.All", role: "Cloud Application Administrator or Application Administrator")
    static let riskNeed = Need(title: "Risky users", scope: "IdentityRiskyUser.ReadWrite.All", role: "Security Operator or Security Administrator",
                               licence: "Microsoft Entra ID P2")
    static let groupsNeed = Need(title: "Group members", scope: "GroupMember.Read.All", role: "any admin role")

    // MARK: Who is acted on

    struct User: Codable, Sendable {
        let id: String, userPrincipalName: String?, displayName: String?, accountEnabled: Bool?, userType: String?, createdDateTime: String?
        let onPremisesSyncEnabled: Bool?
    }
    static let userSelect = "id,userPrincipalName,displayName,accountEnabled,userType,createdDateTime,onPremisesSyncEnabled"

    /// The user an action is for, as read just before it: never the signed-in admin, and never a Global Administrator
    /// unless asked.
    struct Target {
        let user: User, globalAdministrator: Bool?, readAt: String
        var named: String { "\(user.userPrincipalName ?? user.id) (\(user.id))" }
    }

    /// Whether `user` holds Global Administrator, actively or eligible to activate it, directly or through a group;
    /// nil, with why, when that is not known for certain.
    ///
    /// Each assignment is judged by its principalId, never by whether Graph expanded who it is: one naming the user is
    /// true whatever else is missing. One naming a group is true when the group's members, all read, include the user.
    /// One whose principal is missing, of no type, or not the one the assignment names could be a group, so unless
    /// another makes it true, the answer is unknown, as it is when a group's members could not all be read.
    static func isGlobalAdministrator(_ user: String, _ service: ServiceClient) async -> (Bool?, String?) {
        let user = user.lowercased()
        /// What the holders of one listing say: true, false, or unknown with why.
        func holds(_ holders: [(principalId: String?, principal: DirectoryObject?)]) async -> (Bool?, String?) {
            var unknown: String?
            for holder in holders {
                guard let id = (holder.principalId ?? holder.principal?.id)?.lowercased() else {
                    unknown = unknown ?? "an assignment of the role names no principal"; continue
                }
                if id == user { return (true, nil) }
                let kind = holder.principal?.id.lowercased() == id ? Graph.kind(holder.principal?.type) : nil
                switch kind {
                case "user", "servicePrincipal":
                    continue
                case "group":
                    // A group that can hold a role holds no other groups, so its own members are all who hold it through it.
                    do {
                        let members = try await read(groupsNeed) {
                            try await list(service, ["groups", try guid(id, "the group"), "members"], query: ["$select": "id"], as: DirectoryObject.self)
                        }
                        if members.value.contains(where: { $0.id.lowercased() == user }) { return (true, nil) }
                        if !members.complete { unknown = unknown ?? "not every member of the group \(holder.principal?.displayName ?? id) was read" }
                    } catch {
                        unknown = unknown ?? "the members of the group \(holder.principal?.displayName ?? id) could not be read (\(error.localizedDescription))"
                    }
                default:
                    unknown = unknown ?? "Graph did not say what the holder \(id) is, so it may be a group the user is in"
                }
            }
            return unknown.map { (nil, $0) } ?? (false, nil)
        }
        let filter = "roleDefinitionId eq '\(globalAdministrator)'"
        let active: Listing<Assignment>
        do {
            active = try await read(rolesNeed) {
                try await list(service, ["roleManagement", "directory", "roleAssignments"], query: ["$filter": filter, "$expand": "principal"], as: Assignment.self)
            }
        } catch {
            return (nil, fix(for: error, rolesNeed) ?? error.localizedDescription)
        }
        let (activeHolds, activeWhy) = await holds(active.value.map { ($0.principalId, $0.principal) })
        if activeHolds == true { return (true, nil) }
        var why = activeWhy ?? (active.complete ? nil : "not every Global Administrator was read")
        do {
            let eligible = try await list(service, ["roleManagement", "directory", "roleEligibilitySchedules"], query: ["$filter": filter, "$expand": "principal"],
                                          as: Eligibility.self)
            let (eligibleHolds, eligibleWhy) = await holds(eligible.value.map { ($0.principalId, $0.principal) })
            if eligibleHolds == true { return (true, nil) }
            why = why ?? eligibleWhy ?? (eligible.complete ? nil : "not everyone eligible for Global Administrator was read")
        } catch let error where unlicensed(error) {
            // Without Privileged Identity Management's licence, nobody can be made eligible.
        } catch {
            why = why ?? (fix(for: error, eligibleNeed) ?? error.localizedDescription)
        }
        return why.map { (nil, $0) } ?? (false, nil)
    }

    static func target(_ value: String, allowGlobalAdmin: Bool?, on service: ServiceClient) async throws -> Target {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let given = try? Entra.user(value) else {
            throw ServiceError.input("Nothing was changed: give the user's object ID (a GUID) or full user principal name, such as name@contoso.com; give a guest by object ID.")
        }
        let user = try await read(usersNeed) { try await get(service, ["users", given], query: ["$select": userSelect], as: User.self) }
        guard user.id.lowercased() == given.lowercased() || user.userPrincipalName?.lowercased() == given.lowercased() else {
            throw ServiceError.input("Nothing was changed: Graph resolved \(value) to \(user.userPrincipalName ?? "?") (\(user.id)), not exactly the user given.")
        }
        _ = try guid(user.id, "the user")
        let me = try await read(.signedIn) { try await Entra.me(service) }
        guard me.id.lowercased() != user.id.lowercased() else {
            throw ServiceError.input("Nothing was changed: \(value) is the admin signed in to this connection, and Pion does not act on its own sign-in. Contain them in the Microsoft Entra admin center, and sign Microsoft Entra ID Containment in as another admin.")
        }
        let (global, why) = await isGlobalAdministrator(user.id, service)
        if global == nil, allowGlobalAdmin != true {
            throw ServiceError.input("Nothing was changed: whether \(user.userPrincipalName ?? user.id) is a Global Administrator could not be read (\(why ?? "unknown")). Give the containment admin a role that reads directory roles and the app the permissions its Setup Steps list, as check-access says, or set allowGlobalAdmin once the champion confirms acting on a Global Administrator is intended.")
        }
        if global == true, allowGlobalAdmin != true {
            throw ServiceError.input("Nothing was changed: \(user.userPrincipalName ?? user.id) is a Global Administrator, or eligible to become one. Act on them only when the champion confirms, with allowGlobalAdmin set; the containment admin's roles may not allow it either.")
        }
        return Target(user: user, globalAdministrator: global, readAt: iso(Date()))
    }

    typealias Step = Okta.Step

    struct Outcome: Encodable {
        let user: String?, userPrincipalName: String?, readAt: String?, steps: [Step], recovery: String, details: [String: String]
    }

    /// What an action came to: each step, done or not, how to recover, and when what it acted on was read.
    static func outcome(_ target: Target?, steps: [Step], recovery: String, details: [String: String] = [:], note: String? = nil) throws -> ServiceResult {
        // Nothing done is a failure the bot sees as one; part done is a result saying which part.
        if !steps.contains(where: \.done), let failed = steps.first(where: { !$0.done }) {
            throw ServiceError.input("Nothing was changed. " + failed.detail)
        }
        var lines = steps.map { ($0.done ? "✓ " : "✗ ") + $0.detail }
        if let note { lines.append(note) }
        lines.append(recovery)
        if let target {
            lines.append("\(target.named) was read at \(target.readAt). Microsoft Graph takes no condition on this change, so another admin may have changed them between that read and this change.")
        }
        return try ServiceResult(text: lines.joined(separator: "\n"),
                                 structured: Outcome(user: target?.user.id, userPrincipalName: target?.user.userPrincipalName, readAt: target?.readAt,
                                                     steps: steps, recovery: recovery, details: details))
    }

    struct UserInput: Decodable, Sendable { let user: String; let allowGlobalAdmin: Bool? }
    static let userField = JSONSchema.string("The user's object ID (a GUID) or full user principal name.")
    static let globalAdminField = JSONSchema.boolean("Act even though the user is a Global Administrator. Only when the champion has confirmed it.")
    static let userSchema = JSONSchema.object(["user": userField, "allowGlobalAdmin": globalAdminField], required: ["user"])

    /// An ID Graph gives a role assignment, an eligibility or a sign-in method: letters, digits, hyphens, underscores,
    /// dots and equals signs, nothing that could leave a path.
    static func token(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(value.count), value != ".", value != "..",
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.=").contains) else {
            throw ServiceError.input("Give \(name) exactly as user lists it.")
        }
        return value
    }

    // MARK: Reading

    struct ContainmentUser: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "A user's state before acting: whether they can sign in and are synced from on-premises, their active and eligible directory roles with each assignment's ID, their sign-in methods with their IDs, Identity Protection's risk, and whether they are a Global Administrator. It changes nothing."
        static let input = JSONSchema.object(["user": Entra.userField], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let given = try Entra.user(input.user)
            let user = try await Entra.read(Entra.usersNeed) { try await Entra.get(service, ["users", given], query: ["$select": Entra.userSelect], as: User.self) }
            let id = try Entra.guid(user.id, "the user")
            var lines = ["\(user.displayName ?? user.id) (\(user.userPrincipalName ?? user.id), id \(id)): sign-in \(user.accountEnabled == false ? "disabled" : user.accountEnabled == true ? "enabled" : "state unknown")\(user.userType.map { ", \($0)" } ?? "")\(user.onPremisesSyncEnabled == true ? ", synced from on-premises Active Directory, so it is disabled or enabled there" : "")."]
            var gaps: [String] = []
            struct Role: Encodable { let assignment: String, role: String, scope: String?, eligible: Bool }
            var roles: [Role] = []
            do {
                let (held, complete) = try await Entra.heldRoles(id, service)
                roles += held.map { Role(assignment: $0.assignment.id, role: $0.name, scope: $0.assignment.directoryScopeId, eligible: false) }
                if !complete { gaps.append("some active roles") }
            } catch { gaps.append("active roles (\(error.localizedDescription))") }
            do {
                let (names, _) = try await Entra.roleNames(service)
                let eligible = try await Entra.list(service, ["roleManagement", "directory", "roleEligibilitySchedules"], query: ["$filter": "principalId eq '\(id)'"],
                                                    as: Eligibility.self)
                roles += eligible.value.map { Role(assignment: $0.id, role: $0.roleDefinitionId.flatMap { names[$0.lowercased()] } ?? $0.roleDefinitionId ?? "?",
                                                   scope: $0.directoryScopeId, eligible: true) }
                if !eligible.complete { gaps.append("some eligible roles") }
            } catch let error where Entra.unlicensed(error) {
                lines.append("No eligible roles: the tenant has no licence for Privileged Identity Management.")
            } catch { gaps.append("eligible roles (\(error.localizedDescription))") }
            lines.append(roles.isEmpty ? "No directory roles assigned directly." : "Directory roles: " + roles.map {
                "\($0.role)\($0.eligible ? " (eligible)" : "")\($0.scope == "/" || $0.scope == nil ? "" : " on \($0.scope!)") [\($0.eligible ? "eligibility" : "assignment") \($0.assignment)]"
            }.joined(separator: ", ") + ".")
            var methods: [Method]?
            do {
                let listing = try await Entra.list(service, ["users", id, "authentication", "methods"], query: [:], as: Method.self)
                methods = listing.value
                if !listing.complete { gaps.append("some sign-in methods") }
            } catch { gaps.append("sign-in methods (\(error.localizedDescription))") }
            if let methods {
                lines.append(methods.isEmpty ? "No sign-in methods." : "Sign-in methods: " + methods.map { "\($0.named)\($0.detail.map { " (\($0))" } ?? "") [\($0.id)]" }.joined(separator: ", ") + ".")
            }
            var risk: RiskyUser?
            do {
                risk = try await Entra.get(service, ["identityProtection", "riskyUsers", id], as: RiskyUser.self)
                lines.append("Identity Protection: risk \(risk?.riskLevel ?? "?"), \(risk?.riskState ?? "?")\(risk?.riskLastUpdatedDateTime.map { ", since \($0)" } ?? "").")
            } catch ServiceError.notFound {
                lines.append("Identity Protection lists no risk for them.")
            } catch { gaps.append("Identity Protection's risk (\(Entra.fix(for: error, Entra.riskNeed) ?? error.localizedDescription))") }
            let (global, why) = await Entra.isGlobalAdministrator(id, service)
            lines.append(global == true ? "A Global Administrator, or eligible to become one: acting on them needs allowGlobalAdmin." : global == false ? "Not a Global Administrator."
                : "Whether they are a Global Administrator could not be read: \(why ?? "unknown").")
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")); check-access says what the admin or app lacks.") }
            lines.append("Read at \(Entra.iso(Date())).")
            struct Kept: Encodable { let user: User; let roles: [Role]; let methods: [String: String]?; let riskLevel: String?; let riskState: String?; let globalAdministrator: Bool?; let couldNotRead: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(user: user, roles: roles, methods: methods.map { Dictionary($0.map { ($0.id, $0.named) }, uniquingKeysWith: { first, _ in first }) },
                                                      riskLevel: risk?.riskLevel, riskState: risk?.riskState, globalAdministrator: global, couldNotRead: gaps))
        }
    }

    // MARK: Sign-in

    /// Refuses a user synced from on-premises Active Directory, whose sign-in is set there.
    static func cloudOnly(_ target: Target) throws {
        guard target.user.onPremisesSyncEnabled != true else {
            throw ServiceError.input("Nothing was changed: \(target.named) is synced from on-premises Active Directory, which sets whether they can sign in: disable or enable the account there, then revoke-sessions here.")
        }
    }

    struct DisableSignIn: ServiceOperation {
        typealias Input = UserInput
        static let name = "disable-sign-in"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: enable-sign-in restores sign-in, with the user's groups, roles and apps as they were. Disabling does not end sessions or tokens already issued: revoke-sessions does."
        static let summary = "Disable a user's sign-in (accountEnabled false), so they cannot sign in again. \(recovery)"
        static let input = Entra.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Entra.target(input.user, allowGlobalAdmin: input.allowGlobalAdmin, on: service)
            try Entra.cloudOnly(target)
            guard target.user.accountEnabled != false else { throw ServiceError.input("Nothing was changed: \(target.named)'s sign-in is already disabled.") }
            let (steps, _) = await Okta.inTurn([("disable-sign-in", "disable the sign-in of \(target.named)", {
                _ = try await Entra.read(Entra.accountNeed) { try await Entra.send(service, ["users", target.user.id], method: "PATCH", ["accountEnabled": false]) }
            })])
            return try Entra.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct EnableSignIn: ServiceOperation {
        typealias Input = UserInput
        static let name = "enable-sign-in"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: disable-sign-in again. Restoring sign-in can let an attacker back in, so before it remove sign-in methods you do not trust, have the password reset and revoke sessions, as the champion decides."
        static let summary = "Restore a disabled user's sign-in (accountEnabled true). Held like the rest, as it gives access back. \(recovery)"
        static let input = Entra.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Entra.target(input.user, allowGlobalAdmin: input.allowGlobalAdmin, on: service)
            try Entra.cloudOnly(target)
            guard target.user.accountEnabled == false else { throw ServiceError.input("Nothing was changed: \(target.named)'s sign-in is not disabled.") }
            let (steps, _) = await Okta.inTurn([("enable-sign-in", "enable the sign-in of \(target.named)", {
                _ = try await Entra.read(Entra.accountNeed) { try await Entra.send(service, ["users", target.user.id], method: "PATCH", ["accountEnabled": true]) }
            })])
            return try Entra.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct RevokeSessions: ServiceOperation {
        typealias Input = UserInput
        static let name = "revoke-sessions"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: nothing to restore; the user signs in again everywhere. Their refresh tokens and session cookies are invalidated, but access tokens already issued keep working until they expire, usually within an hour, except in apps that honour Continuous Access Evaluation."
        static let summary = "Revoke all of a user's sign-in sessions (revokeSignInSessions), invalidating their refresh tokens and session cookies so they must sign in again. \(recovery)"
        static let input = Entra.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Entra.target(input.user, allowGlobalAdmin: input.allowGlobalAdmin, on: service)
            let (steps, _) = await Okta.inTurn([("revoke-sessions", "revoke every sign-in session of \(target.named)", {
                struct Answer: Decodable { let value: Bool? }
                let answer = try await Entra.read(Entra.sessionsNeed) { try await Entra.send(service, ["users", target.user.id, "revokeSignInSessions"], method: "POST", nil) }
                guard (try? JSONDecoder().decode(Answer.self, from: answer.data))?.value == true else {
                    throw ServiceError.input("Graph did not say the sessions were revoked")
                }
            })])
            return try Entra.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    // MARK: Sign-in methods

    /// Where Graph deletes each kind of sign-in method, below the user's authentication; the password has none.
    static let methodPaths = ["microsoftAuthenticatorAuthenticationMethod": "microsoftAuthenticatorMethods", "phoneAuthenticationMethod": "phoneMethods",
                              "fido2AuthenticationMethod": "fido2Methods", "softwareOathAuthenticationMethod": "softwareOathMethods",
                              "emailAuthenticationMethod": "emailMethods", "temporaryAccessPassAuthenticationMethod": "temporaryAccessPassMethods",
                              "windowsHelloForBusinessAuthenticationMethod": "windowsHelloForBusinessMethods",
                              "platformCredentialAuthenticationMethod": "platformCredentialMethods"]

    struct DeleteSignInMethods: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let methods: [String]; let allowGlobalAdmin: Bool? }
        static let name = "delete-sign-in-methods"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: the user must register each removed method again; make sure it is them, as whoever signs in next with the password may register their own. The password is not a method this removes: have it reset in the Microsoft Entra admin center."
        static let summary = "Delete one or more of a user's sign-in methods, such as an authenticator or phone an attacker registered, by their IDs from user; checks every one first and reports each deletion. \(recovery)"
        static let input = JSONSchema.object(["user": Entra.userField, "methods": .array(.string("A sign-in method's ID, as user lists it."), "Between 1 and 20 methods."),
                                              "allowGlobalAdmin": Entra.globalAdminField], required: ["user", "methods"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let wanted = Okta.unique(try ServiceInput.list(input.methods, limit: 20) { try Entra.token($0, "the sign-in method") })
            let target = try await Entra.target(input.user, allowGlobalAdmin: input.allowGlobalAdmin, on: service)
            let held = try await Entra.read(Entra.methodsNeed) {
                try await Entra.list(service, ["users", target.user.id, "authentication", "methods"], query: [:], as: Method.self)
            }
            // Every method is checked before any is deleted.
            var refused: [String] = [], found: [(Method, String)] = []
            for id in wanted {
                guard let method = held.value.first(where: { $0.id == id }) else {
                    refused.append("\(id): \(held.complete ? "not one of the user's sign-in methods" : "not among the user's sign-in methods read")"); continue
                }
                guard let path = Entra.methodPaths[method.kind] else { refused.append("\(id): a \(method.named), which this does not delete"); continue }
                found.append((method, path))
            }
            guard refused.isEmpty else { throw ServiceError.input("Nothing was changed: " + refused.joined(separator: "; ") + ".") }
            let (steps, failed) = await Okta.inTurn(found.map { method, path in
                ("delete-sign-in-method", "delete the \(method.named)\(method.detail.map { " (\($0))" } ?? "") [\(method.id)] of \(target.named)", {
                    _ = try await Entra.read(Entra.methodsNeed) { try await Entra.send(service, ["users", target.user.id, "authentication", path, method.id], method: "DELETE", nil) }
                })
            })
            return try Entra.outcome(target, steps: steps, recovery: Self.recovery,
                                     note: failed ? "Only part of the change was made: the steps above say which methods were deleted. Microsoft refuses to delete a default method while others remain; delete the others first." : nil)
        }
    }

    // MARK: Roles

    struct RemoveDirectoryRole: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let assignments: [String]?; let eligibilities: [String]?; let allowGlobalAdmin: Bool? }
        static let name = "remove-directory-role"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: assign each role again in Roles and administrators, or make the user eligible again in Privileged Identity Management; the assignment's ID and schedule are not restored."
        static let summary = "Remove directory roles a user holds directly: active assignments, and eligibility in Privileged Identity Management, by their IDs from user; checks every one first and reports each removal. Roles held through a group are refused, as they are the group's. \(recovery)"
        static let input = JSONSchema.object(["user": Entra.userField,
                                              "assignments": .array(.string("An active role assignment's ID, as user lists it."), "Up to 20 active assignments."),
                                              "eligibilities": .array(.string("An eligibility's ID, as user lists it."), "Up to 20 eligibilities."),
                                              "allowGlobalAdmin": Entra.globalAdminField], required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let active = Okta.unique(try (input.assignments ?? []).map { try Entra.token($0, "the role assignment") })
            let eligible = Okta.unique(try (input.eligibilities ?? []).map { try Entra.token($0, "the eligibility") })
            guard !(active.isEmpty && eligible.isEmpty), active.count + eligible.count <= 20 else {
                throw ServiceError.input("Give between 1 and 20 assignments and eligibilities, as user lists them.")
            }
            let target = try await Entra.target(input.user, allowGlobalAdmin: input.allowGlobalAdmin, on: service)
            let (names, _) = try await Entra.read(Entra.rolesNeed) { try await Entra.roleNames(service) }
            let assignments = active.isEmpty ? nil : try await Entra.read(Entra.rolesNeed) {
                try await Entra.list(service, ["roleManagement", "directory", "roleAssignments"], query: ["$filter": "principalId eq '\(target.user.id)'"], as: Assignment.self)
            }
            let schedules = eligible.isEmpty ? nil : try await Entra.read(Entra.eligibleNeed) {
                try await Entra.list(service, ["roleManagement", "directory", "roleEligibilitySchedules"], query: ["$filter": "principalId eq '\(target.user.id)'"], as: Eligibility.self)
            }
            // Every one is checked before any is removed: it must be the user's own, not a group's.
            var refused: [String] = []
            var changes: [(action: String, describe: String, run: () async throws -> Void)] = []
            for id in active {
                guard let assignment = assignments?.value.first(where: { $0.id == id }), assignment.principalId?.lowercased() == target.user.id.lowercased() else {
                    refused.append("\(id): \(assignments?.complete == false ? "not among the user's active roles read" : "not one of the user's own active role assignments; a role held through a group is the group's")"); continue
                }
                let role = assignment.roleDefinitionId.flatMap { names[$0.lowercased()] } ?? assignment.roleDefinitionId ?? "?"
                changes.append(("remove-directory-role", "remove the active role \(role) [\(id)] from \(target.named)", {
                    _ = try await Entra.read(Entra.rolesNeed) { try await Entra.send(service, ["roleManagement", "directory", "roleAssignments", id], method: "DELETE", nil) }
                }))
            }
            for id in eligible {
                guard let schedule = schedules?.value.first(where: { $0.id == id }), schedule.principalId?.lowercased() == target.user.id.lowercased(),
                      let definition = schedule.roleDefinitionId else {
                    refused.append("\(id): \(schedules?.complete == false ? "not among the user's eligible roles read" : "not one of the user's own eligibilities; one held through a group is the group's")"); continue
                }
                let role = names[definition.lowercased()] ?? definition
                changes.append(("remove-eligible-role", "remove the eligibility for \(role) [\(id)] from \(target.named)", {
                    _ = try await Entra.read(Entra.eligibleNeed) {
                        try await Entra.send(service, ["roleManagement", "directory", "roleEligibilityScheduleRequests"], method: "POST", [
                            "action": "adminRemove", "principalId": target.user.id, "roleDefinitionId": definition,
                            "directoryScopeId": schedule.directoryScopeId ?? "/", "justification": "Removed by Pion while containing an incident, as approved.",
                        ])
                    }
                }))
            }
            guard refused.isEmpty else { throw ServiceError.input("Nothing was changed: " + refused.joined(separator: "; ") + ".") }
            let (steps, failed) = await Okta.inTurn(changes)
            return try Entra.outcome(target, steps: steps, recovery: Self.recovery,
                                     note: failed ? "Only part of the change was made: the steps above say which roles were removed. A role made active for a time in Privileged Identity Management may need removing there." : nil)
        }
    }

    // MARK: Apps

    /// Removes an app's secret by its keyId alone, through removePassword. A certificate it never removes: Graph's
    /// removeKey takes proof signed by one of the app's own keys, which Pion does not hold, and writing the app's list of
    /// certificates back without it would undo a certificate added meanwhile, so the champion removes it in the portal.
    struct RemoveAppCredential: ServiceOperation {
        struct Input: Decodable, Sendable { let app: String; let kind: String; let keyId: String }
        static let name = "remove-app-credential"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: none, as a secret cannot be shown again: whatever used it needs a new one. Pion never adds credentials."
        static let summary = "Remove one client secret from an app registration or enterprise app, by the app's object ID and the secret's keyId from Microsoft Entra ID Detection's app-credentials, saying what it was. A certificate is refused, with the steps to remove it in the Microsoft Entra admin center. \(recovery)"
        static let input = JSONSchema.object(["app": .string("The app's object ID (a GUID), as app-credentials lists it; not its application (client) ID."),
                                              "kind": .string("Whether it is an app registration or an enterprise app.", oneOf: ["application", "servicePrincipal"]),
                                              "keyId": .string("The secret's keyId (a GUID), as app-credentials lists it.")],
                                             required: ["app", "kind", "keyId"])
        static let readOnly = false
        static let destructive = true

        struct Credential: Decodable { let keyId: String?; let displayName: String?; let startDateTime: String?; let endDateTime: String?; let customKeyIdentifier: String? }
        struct App: Decodable { let id: String?; let appId: String?; let displayName: String?; let passwordCredentials: [Credential]?; let keyCredentials: [Credential]? }

        /// Where the champion removes a certificate Pion will not.
        static func portalSteps(_ kind: String, _ name: String, _ id: String, _ appId: String, _ keyId: String) -> String {
            kind == "applications"
                ? "In the Microsoft Entra admin center, open App registrations › All applications, search for application (client) ID \(appId), open \(name), then Certificates & secrets › Certificates; find the certificate whose Certificate ID is \(keyId), choose Delete and confirm."
                : "In the Microsoft Entra admin center, open Enterprise applications › All applications, search for application ID \(appId), open \(name), then Single sign-on › SAML Certificates; if the certificate with key ID \(keyId) is listed, choose Edit, then that certificate's menu › Delete. If it is not listed there, escalate to whoever manages that enterprise app; do not replace its whole list of certificates, which would undo any added meanwhile."
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try Entra.guid(input.app, "the app"), keyId = try Entra.guid(input.keyId, "the credential's keyId")
            let collection = try ServiceInput.oneOf(input.kind, ["application", "servicePrincipal"], "kind") == "application" ? "applications" : "servicePrincipals"
            let path = [collection, id]
            func read() async throws -> App {
                try await Entra.read(Entra.appsNeed) {
                    try await Entra.get(service, path, query: ["$select": "id,appId,displayName,passwordCredentials,keyCredentials"], as: App.self)
                }
            }
            let app = try await read(), readAt = Entra.iso(Date())
            // What is acted on must be the app asked for, and known not to be this connection's own, before anything is sent.
            guard app.id?.lowercased() == id else {
                throw ServiceError.input("Nothing was changed: Graph answered for \(app.id ?? "no app") when asked for \(id).")
            }
            guard let appId = app.appId, Entra.isGUID(appId) else {
                throw ServiceError.input("Nothing was changed: Graph did not give \(id)'s application (client) ID, so whether it is the app this connection signs in through cannot be checked.")
            }
            let name = app.displayName ?? id
            guard appId.lowercased() != service.settings["clientID"]?.lowercased() else {
                throw ServiceError.input("Nothing was changed: \(name) is the app this connection signs in through, and Pion does not act on its own sign-in.")
            }
            func matches(_ credential: Credential) -> Bool { credential.keyId?.lowercased() == keyId }
            if (app.keyCredentials ?? []).contains(where: matches) {
                throw ServiceError.input("Nothing was changed: keyId \(keyId) is a certificate of \(name), which Pion does not remove: Microsoft Graph removes a certificate only with proof signed by one of the app's own keys, which Pion does not hold, and rewriting the app's certificates could undo one added meanwhile. Ask the champion to remove it: \(Self.portalSteps(collection, name, id, appId, keyId))")
            }
            guard let secret = (app.passwordCredentials ?? []).first(where: matches) else {
                throw ServiceError.input("Nothing was changed: \(name) has no secret or certificate with keyId \(keyId); app-credentials lists theirs.")
            }
            let described = "secret\(secret.displayName.map { " \"\($0)\"" } ?? "") [\(keyId)], added \(secret.startDateTime ?? "?"), expiring \(secret.endDateTime ?? "?")"
            let (steps, _) = await Okta.inTurn([("remove-app-credential", "remove the \(described) from \(name)", {
                _ = try await Entra.read(Entra.appsNeed) { try await Entra.send(service, path + ["removePassword"], method: "POST", ["keyId": keyId]) }
            })])
            // Read again, to say whether the secret is gone: only an answer for this very app that lists its secrets says so.
            var note: String?
            if steps.contains(where: \.done) {
                let inconclusive = "Graph accepted the removal, but whether the secret \(keyId) is gone is not known"
                do {
                    let after = try await read()
                    if after.id?.lowercased() != id || after.appId?.lowercased() != appId.lowercased() {
                        note = "⚠ \(inconclusive): read again, Graph answered for \(after.id ?? "no object ID") with application ID \(after.appId ?? "none"), not \(name) (\(id), \(appId)). Read app-credentials again."
                    } else if let secrets = after.passwordCredentials {
                        if secrets.contains(where: matches) {
                            note = "⚠ Read again, \(name) still lists the secret \(keyId): Graph may not have applied the change yet, or someone put it back. Read app-credentials again."
                        } else if secrets.allSatisfy({ $0.keyId.map(Entra.isGUID) == true }) {
                            note = "Read again: the secret \(keyId) is gone."
                        } else {
                            // Absence is known only when every secret listed names itself.
                            note = "⚠ \(inconclusive): read again, \(name) lists a secret without a valid key ID, which could be it. Read app-credentials again."
                        }
                    } else {
                        note = "⚠ \(inconclusive): read again, Graph did not list \(name)'s secrets. Read app-credentials again."
                    }
                } catch {
                    note = "⚠ \(inconclusive): it could not be read again (\(error.localizedDescription)). Read app-credentials again."
                }
            }
            return try Entra.outcome(nil, steps: steps, recovery: Self.recovery, details: ["app": id, "appId": appId, "keyId": keyId],
                                     note: [note, "\(name) was read at \(readAt). Removing a secret takes only its keyId, so no other credential is touched."].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    // MARK: Risk

    static func risk(_ target: Target, _ service: ServiceClient) async throws -> RiskyUser? {
        do { return try await read(riskNeed) { try await get(service, ["identityProtection", "riskyUsers", target.user.id], as: RiskyUser.self) } }
        catch ServiceError.notFound { return nil }
    }

    struct ConfirmCompromised: ServiceOperation {
        typealias Input = UserInput
        static let name = "confirm-compromised"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: dismiss-user-risk clears it. Confirming sets the user's risk to high, which risk-based Conditional Access policies may act on, such as blocking their sign-in or requiring a secure password change."
        static let summary = "Tell Identity Protection a user is compromised, setting their risk to high. Needs Entra ID P2. \(recovery)"
        static let input = Entra.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Entra.target(input.user, allowGlobalAdmin: input.allowGlobalAdmin, on: service)
            let before = try await Entra.risk(target, service)
            guard before?.riskState?.lowercased() != "confirmedcompromised" else { throw ServiceError.input("Nothing was changed: \(target.named) is already confirmed compromised.") }
            let (steps, _) = await Okta.inTurn([("confirm-compromised", "confirm \(target.named) compromised, whose risk was \(before?.riskLevel ?? "none") (\(before?.riskState ?? "not listed"))", {
                _ = try await Entra.read(Entra.riskNeed) { try await Entra.send(service, ["identityProtection", "riskyUsers", "confirmCompromised"], method: "POST", ["userIds": [target.user.id]]) }
            })])
            return try Entra.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct DismissUserRisk: ServiceOperation {
        typealias Input = UserInput
        static let name = "dismiss-user-risk"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: none directly. Dismissing hides the user's risk from Identity Protection, its risk-based policies and the alert watch; confirm-compromised raises it to high again."
        static let summary = "Dismiss a user's risk in Identity Protection. Held like the rest, as it hides risk. Needs Entra ID P2. \(recovery)"
        static let input = Entra.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Entra.target(input.user, allowGlobalAdmin: input.allowGlobalAdmin, on: service)
            let before = try await Entra.risk(target, service)
            guard let before, Entra.atRisk.contains(before.riskState?.lowercased() ?? "") else {
                throw ServiceError.input("Nothing was changed: Identity Protection does not rate \(target.named) at risk, so there is nothing to dismiss.")
            }
            let (steps, _) = await Okta.inTurn([("dismiss-user-risk", "dismiss the \(before.riskLevel ?? "?") risk (\(before.riskState ?? "?")) of \(target.named)", {
                _ = try await Entra.read(Entra.riskNeed) { try await Entra.send(service, ["identityProtection", "riskyUsers", "dismiss"], method: "POST", ["userIds": [target.user.id]]) }
            })])
            return try Entra.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    // MARK: Access

    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Reads the roles of the signed-in admin and says which containment operations they allow, what role to add for the rest, and when they allow far more; which tenant it acts on; tries what the operations read first; and which permissions the app is consented. It changes nothing."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var lines = [await Entra.tenantLine(service)]
            func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ Reading \(need.title.lowercased())" }
                catch { return "✗ Reading \(need.title.lowercased()): " + (Entra.fix(for: error, need) ?? error.localizedDescription) }
            }
            lines.append(await check(Entra.usersNeed) { _ = try await Entra.get(service, ["users"], query: ["$select": "id", "$top": "1"], as: Page<IgnoredItem>.self) })
            lines.append(await check(Entra.rolesNeed) { _ = try await Entra.get(service, ["roleManagement", "directory", "roleAssignments"], query: ["$top": "1"], as: Page<IgnoredItem>.self) })
            lines.append(await check(Entra.riskNeed) { _ = try await Entra.get(service, ["identityProtection", "riskyUsers"], query: ["$top": "1"], as: Page<IgnoredItem>.self) })
            lines.append(await check(Entra.appsNeed) { _ = try await Entra.get(service, ["applications"], query: ["$select": "id", "$top": "1"], as: Page<IgnoredItem>.self) })
            do {
                let me = try await Entra.me(service)
                lines.append(await check(Entra.methodsNeed) { _ = try await Entra.get(service, ["users", me.id, "authentication", "methods"], as: Page<IgnoredItem>.self) })
                let (roles, complete) = try await Entra.heldRoles(me.id, service)
                let names = Set(roles.map(\.name))
                lines.append("· Signed in as \(me.userPrincipalName ?? me.id), who holds \(names.isEmpty ? "no directory role assigned directly" : names.sorted().joined(separator: ", "))\(complete ? "" : ", in what was read"). Roles only eligible in Privileged Identity Management count once activated.")
                if names.contains("Global Administrator") {
                    lines.append("⚠ The admin is a Global Administrator: every operation works, and much more besides. Sign Microsoft Entra ID Containment in as an admin of its own with only the roles its Setup Steps list.")
                } else {
                    for need in Entra.containmentRoles {
                        if let role = need.any.first(where: names.contains) { lines.append("✓ \(need.operation), as \(role)") }
                        else { lines.append("✗ \(need.operation): give the admin \(need.any[0])\(need.any.count > 1 ? " (or \(need.any.dropFirst().joined(separator: " or ")), which allows less)" : "").") }
                    }
                    let broad = names.subtracting(Entra.containmentRoles.flatMap(\.any))
                    if !broad.isEmpty { lines.append("⚠ The admin also holds \(broad.sorted().joined(separator: ", ")), which this tool does not need; take them away unless intended.") }
                    lines.append("· Microsoft lets only a Privileged Authentication Administrator, or a Global Administrator, disable, revoke or change the sign-in methods of a user who holds an admin role; a User or Authentication Administrator may act only on users without one.")
                }
            } catch {
                lines.append("· Who is signed in, and their roles: not read: \(error.localizedDescription)")
            }
            lines += await Entra.consentLines(Entra.containmentScopes, reading: false, service)
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
