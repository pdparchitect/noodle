import CryptoKit
import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// GitHub Containment: responding in one organisation, through a private GitHub App of its own holding only the write
/// permissions its actions take, with a device sign-in of its own, kept apart from Detection's so Detection's App stays
/// read-only. Every action waits for the champion's approval, and each says what happens and how it is undone.
///
/// Before each action Pion reads what undoing it takes, such as a member's role, the repositories and permissions of an
/// outside collaborator, a deploy key's public key or the Actions settings it replaces, and keeps it in its undo record,
/// bound to the connection and the organisation, before anything is sent. The undo operations act only from such a
/// record. A change is reported done only when a read afterwards shows it.
///
/// Left out, as GitHub's API cannot do them or they cannot be undone: removing self-hosted runners, suspending or
/// removing another App's installation (only an owner can, in the web interface), deleting webhooks and making
/// repositories private.
extension GitHub {
    public static let containment = ToolDefinition(
        id: "6945f40b-93aa-4cd5-85ad-3a7868546ce0", name: "GitHub Containment",
        summary: "Remove a member or outside collaborator, block a user, demote an owner, take someone off a team, cancel an invitation, revoke a fine-grained token or SAML authorization, delete a deploy key, disable a webhook or Actions, cancel a workflow run and report a leaked token in a GitHub organisation, each with its undo recorded.",
        defaultInstructions: """
        Use GitHub Containment to respond in a GitHub organisation. Find the target with GitHub Detection first and \
        record it as evidence. remove-member removes a member, who loses every team and repository; \
        remove-outside-collaborator removes an outside collaborator from every repository; block-user removes them \
        first if they are a member or collaborator, then blocks them; demote-owner makes an owner a member; \
        remove-from-team takes someone off one team; cancel-invitation cancels a pending invitation; \
        revoke-fine-grained-token ends a fine-grained token's access to the organisation; revoke-sso-credential ends a \
        credential's SAML authorization (Enterprise Cloud); delete-deploy-key deletes a repository's deploy key; \
        disable-webhook stops a webhook delivering; disable-actions stops GitHub Actions in a repository or the whole \
        organisation; cancel-workflow-run cancels a running workflow; report-leaked-token sends a leaked GitHub token \
        to GitHub, which revokes it and tells its owner, without signing in and without Pion keeping it. Before each, \
        Pion reads and keeps what undoing it takes, in an undo record whose ID the result gives: reinstate-member, \
        restore-collaborator, unblock-user, restore-owner, restore-team-membership, restore-deploy-key, \
        enable-webhook and enable-actions undo from that record, and undo-records lists them. Revoking a token or \
        authorization, cancelling an invitation or run and reporting a token cannot be undone. All of these are held \
        for the champion's approval: give the exact target, and in --approval-reason why, the expected effect and \
        how to undo it, with the Investigation as --approval-conversation. check-access and undo-records read \
        without approval. Pion refuses a malformed value, a repository of another owner, the signed-in owner \
        themselves and the last owner. A result Pion could not verify is never reported done. Run check-access when \
        something is refused, and tell the champion exactly what it says to change.
        """,
        iconName: "github",
        configuration: .connection(.init(endpointTemplate: "https://\(host)", fields: fields, oauth: oauth,
                                         oauthClientField: "clientID", adapter: "github-containment")),
        setup: containmentSetup)

    static let containmentSetup = appSteps("Pion Containment", permissions: containmentPermissions) + [
        "Organization **Administration: Read and write** is broad: it can change the organisation's settings. Pion needs it only to turn Actions off across the organisation and to revoke SAML SSO credentials; leave it out if agents should do neither, and those two actions are refused.",
    ]
        + ["Keep this App apart from Pion Detection's, so Detection's stays read-only. Revoking SAML authorizations needs GitHub Enterprise Cloud with SAML single sign-on; report-leaked-token sends the token to GitHub without signing in."]

    public static let containmentAdapter = OperationAdapter(operations: operations, job: .containment, simultaneousRequests: 2)

    // MARK: What it needs

    static let membersWrite = Permission(section: "Organization", name: "Members", key: "members", write: true)
    static let blockingWrite = Permission(section: "Organization", name: "Blocking users", key: "organization_user_blocking", write: true)
    static let orgWebhooksWrite = Permission(section: "Organization", name: "Webhooks", key: "organization_hooks", write: true)
    static let tokensWrite = Permission(section: "Organization", name: "Personal access tokens", key: "organization_personal_access_tokens", write: true)
    static let orgAdministrationWrite = Permission(section: "Organization", name: "Administration", key: "organization_administration", write: true)
    static let repoAdministrationWrite = Permission(section: "Repository", name: "Administration", key: "administration", write: true)
    static let actionsWrite = Permission(section: "Repository", name: "Actions", key: "actions", write: true)

    /// What Containment's App holds: the write permissions its actions take, each of which also reads what it covers.
    static let containmentPermissions = [actionsWrite, repoAdministrationWrite, metadataRead,
                                         orgAdministrationWrite, blockingWrite, membersWrite, tokensWrite, orgWebhooksWrite]

    static let membershipNeed = Need(title: "Organisation membership", permission: membersWrite, role: owner)
    static let invitationsNeed = Need(title: "Invitations", permission: membersWrite, role: owner)
    static let blockingNeed = Need(title: "Blocking users", permission: blockingWrite, role: owner)
    static let teamNeed = Need(title: "Team membership", permission: membersWrite, role: "an organisation owner or the team's maintainer")
    static let collaboratorNeed = Need(title: "Repository collaborators", permission: repoAdministrationWrite, role: owner)
    static let tokenRevokeNeed = Need(title: "Fine-grained tokens", permission: tokensWrite, role: owner)
    static let deployKeyNeed = Need(title: "Deploy keys", permission: repoAdministrationWrite, role: "an organisation owner or the repository's admin")
    static let hookNeed = Need(title: "Organisation webhooks", permission: orgWebhooksWrite, role: owner)
    static let ssoRevokeNeed = Need(title: "SAML credential authorizations", permission: orgAdministrationWrite, role: owner,
                                    plan: "credential authorizations exist only on GitHub Enterprise Cloud with SAML single sign-on")
    static let orgActionsNeed = Need(title: "The organisation's Actions permissions", permission: orgAdministrationWrite, role: owner)
    static let repoActionsNeed = Need(title: "A repository's Actions permissions", permission: repoAdministrationWrite, role: "an organisation owner or the repository's admin")
    static let runsNeed = Need(title: "Workflow runs", permission: actionsWrite, role: "someone who can write to the repository")

    /// How long to wait between a change GitHub finishes later, such as cancelling a run, and reading it back.
    @TaskLocal static var pauses: [Double] = [1, 2, 3]
    @TaskLocal static var pause: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    /// How report-leaked-token reaches GitHub: with no credentials, as GitHub refuses a signed-in report, only at
    /// api.github.com, and no redirect followed. Tests answer in its place.
    @TaskLocal static var anonymous: any ServiceAccess = ToolConnectionAccess.anonymous(URL(string: "https://\(host)")!, timeout: 20)

    /// What a change's request was, for a result that could not be verified.
    static func requested(_ method: String, _ path: [String], _ details: String) -> String {
        "Request: \(method) /\(path.joined(separator: "/")) (\(details))."
    }
}

// MARK: - Pion's undo records

extension GitHub {
    /// What one action did and what undoing it takes, kept before the action is sent.
    struct UndoRecord: Codable, Equatable, Sendable {
        /// A repository an outside collaborator reached, with the permission to give back.
        struct Grant: Codable, Equatable, Sendable { let repo: String; let permission: String }
        let id: String
        let action: String
        let target: String
        let created: Date
        /// sent, done, unverified or undone.
        var state: String
        /// The operation that undoes it from this record; nil when nothing can.
        let undo: String?
        let recorded: [String: String]
        var grants: [Grant] = []
        var undone: Date? = nil
    }

    struct UndoBook: Sendable {
        var file: URL? = nil
        var records: [String: [UndoRecord]] = [:]
    }
    static let undoBook = Mutex(UndoBook())
    /// The most records kept for one connection; the oldest go first.
    static let mostRecords = 500

    /// Keeps Pion's undo records of what GitHub Containment did in `file`, reading what it already holds; nil keeps them
    /// in memory.
    public static func keepContainmentRecords(at file: URL?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([String: [UndoRecord]].self, from: $0) } ?? [:]
        undoBook.withLock { $0 = UndoBook(file: file, records: saved) }
    }

    static func recordKey(_ service: ServiceClient) throws -> String {
        guard let connection = service.account else {
            throw ServiceError.input("Nothing was changed: Pion cannot tell which connection this is, so it can keep no undo record, and acts on nothing.")
        }
        return "\(connection.uuidString.lowercased())@\(try org(service).lowercased())"
    }

    static func newRecordID() -> String { "gh-" + UUID().uuidString.prefix(8).lowercased() }

    static func changeRecords(_ service: ServiceClient, _ change: (inout [UndoRecord]) -> Void) throws {
        let key = try recordKey(service)
        try undoBook.withLock { book in
            var records = book.records[key] ?? []
            change(&records)
            if records.count > mostRecords { records.removeFirst(records.count - mostRecords) }
            var changed = book.records
            changed[key] = records.isEmpty ? nil : records
            if let file = book.file {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(changed).write(to: file, options: .atomic)
            }
            book.records = changed
        }
    }

    static func keep(_ service: ServiceClient, _ record: UndoRecord) throws {
        try changeRecords(service) { records in
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.append(record) }
        }
    }

    static func undoRecords(_ service: ServiceClient) throws -> [UndoRecord] {
        let key = try recordKey(service)
        return undoBook.withLock { $0.records[key] ?? [] }
    }

    /// The record `id` names, of `action`, not yet undone, for `undo` to act from.
    static func undoable(_ raw: String, action: String, by undo: String, _ service: ServiceClient) throws -> UndoRecord {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let record = try undoRecords(service).first(where: { $0.id == id }) else {
            throw ServiceError.input("Nothing was changed: Pion has no undo record \(id) for this connection; undo-records lists them.")
        }
        guard record.action == action else {
            throw ServiceError.input("Nothing was changed: record \(id) is of \(record.action), which \(record.undo ?? "nothing") undoes, not \(undo).")
        }
        if let undone = record.undone { throw ServiceError.input("Nothing was changed: record \(id) was already undone at \(iso(undone)).") }
        guard record.state == "done" || record.state == "unverified" else {
            throw ServiceError.input("Nothing was changed: record \(id) is of a request GitHub did not finish (\(record.state)).")
        }
        return record
    }

    static func markUndone(_ service: ServiceClient, _ record: UndoRecord) {
        var record = record
        record.state = "undone"
        record.undone = Date()
        try? keep(service, record)
    }

    /// Keeps `record` before anything is sent, sends the change, and reads it back with `verify`. A request GitHub
    /// refused changed nothing, so its record goes; one GitHub could not answer may have been done, so its record stays.
    static func perform(_ service: ServiceClient, _ record: UndoRecord, need: Need, method: String, path: [String], body: Data? = nil,
                        verify: () async throws -> Bool) async throws -> UndoRecord {
        var record = record
        do { try keep(service, record) } catch {
            throw ServiceError.input("Nothing was changed: Pion could not keep its undo record (\(error.localizedDescription)), so it sends nothing.")
        }
        let request = requested(method, path, record.target)
        do { _ = try await read(need) { try await send(service, path, method: method, body: body) } } catch {
            if case ServiceError.status(let status, _) = error, status >= 500 {
                record.state = "unverified"
                try? keep(service, record)
                throw ServiceError.input("GitHub could not answer the request to \(record.action) \(record.target) (\(error.localizedDescription)), so whether it was done is unknown; read it before trying again. Undo record \(record.id) is kept.\n\(request)")
            }
            try? changeRecords(service) { $0.removeAll { $0.id == record.id } }
            throw ServiceError.input("GitHub refused to \(record.action) \(record.target): \(error.localizedDescription) Nothing was changed.\n\(request)")
        }
        record.state = ((try? await verify()) ?? false) ? "done" : "unverified"
        try? keep(service, record)
        return record
    }

    /// What an action did, said for the champion, with its record; an action not read back is not reported done.
    static func outcome(_ record: UndoRecord, done: String, unverified: String, recovery: String) throws -> ServiceResult {
        guard record.state == "done" else {
            throw ServiceError.input("GitHub accepted the request, but \(unverified), so it is not reported done; read it again before relying on it. Undo record \(record.id) is kept.\n\(recovery)")
        }
        struct Kept: Encodable { let done: Bool; let record: UndoRecord; let recovery: String }
        return try ServiceResult(text: "\(done)\nUndo record \(record.id).\n\(recovery)", structured: Kept(done: true, record: record, recovery: recovery))
    }

    // MARK: Reads before acting

    /// A user's membership of the organisation, or nil when they are neither a member nor invited.
    static func membership(_ user: String, _ service: ServiceClient) async throws -> Membership? {
        let path = try orgPath(service, "memberships", user)
        let answer = try await read(membershipNeed) { try await send(service, path, returning: [404]) }
        return answer.response.statusCode == 404 ? nil : try decode(answer.data)
    }

    /// Refuses the signed-in person and the organisation's last owner; their membership, or nil for a non-member.
    static func removable(_ user: String, _ service: ServiceClient) async throws -> Membership? {
        let me = try await signer(service)
        guard me.login.lowercased() != user.lowercased() else {
            throw ServiceError.input("Nothing was changed: \(user) is the person this connection is signed in as.")
        }
        guard let membership = try await membership(user, service) else { return nil }
        if membership.role == "admin", membership.state == "active", try await ownerCount(service) <= 1 {
            throw ServiceError.input("Nothing was changed: \(user) is the organisation's only owner.")
        }
        return membership
    }

    static func ownerCount(_ service: ServiceClient) async throws -> Int {
        try await read(membershipNeed) { try await list(service, try orgPath(service, "members"), query: ["role": "admin"], as: Person.self).items.count }
    }

    static func isOutsideCollaborator(_ user: String, _ service: ServiceClient) async throws -> Bool {
        let found = try await read(membershipNeed) { try await list(service, try orgPath(service, "outside_collaborators"), as: Person.self) }
        if found.items.contains(where: { $0.login.lowercased() == user.lowercased() }) { return true }
        if found.more { throw ServiceError.input("Nothing was changed: the organisation has more outside collaborators than Pion reads, so whether \(user) is one could not be told.") }
        return false
    }

    static func isBlocked(_ user: String, _ service: ServiceClient) async throws -> Bool {
        let path = try orgPath(service, "blocks", user)
        return try await read(blockingNeed) { try await send(service, path, returning: [404]) }.response.statusCode != 404
    }

    /// The repositories, of the `cap` most recently pushed, a user reaches as a collaborator, with the permission to give
    /// back: what removing an outside collaborator takes away. Read access to a public repository is everyone's, so it is
    /// left out.
    static func grants(of user: String, cap: Int, _ service: ServiceClient) async throws -> (grants: [UndoRecord.Grant], read: Int, total: Int, more: Bool, failed: [String]) {
        let repos = try await repositories(service, pages: (cap + 99) / 100)
        let checked = Array(repos.items.prefix(cap))
        struct Access: Decodable, Sendable { let permission: String?; let role_name: String? }
        let answers = await each(checked) { repo -> Access? in
            let path = try repoPath(repo.name, service, "collaborators", user, "permission")
            let answer = try await read(collaboratorNeed) { try await send(service, path, returning: [404]) }
            return answer.response.statusCode == 404 ? nil : try decode(answer.data, as: Access.self)
        }
        var found: [UndoRecord.Grant] = [], failed: [String] = []
        for (repo, answer) in answers {
            switch answer {
            case .success(let access):
                guard let access, access.permission != "none", let role = access.role_name ?? access.permission else { continue }
                if !repo.isPrivate, ["read", "pull"].contains(role) { continue }
                found.append(UndoRecord.Grant(repo: repo.name, permission: ["read": "pull", "write": "push"][role] ?? role))
            case .failure(let error): failed.append("\(repo.name): \(error.localizedDescription)")
            }
        }
        return (found, checked.count, repos.items.count, repos.more || repos.items.count > checked.count, failed)
    }

    static func grantsLine(_ grants: [UndoRecord.Grant]) -> String {
        grants.isEmpty ? "no repositories" : grants.map { "\($0.repo) (\($0.permission))" }.joined(separator: ", ")
    }

    // MARK: Removals both remove-member and block-user make

    static let memberRecovery = "Undo: reinstate-member with this record, within three months, invites them back with GitHub's reinstate role, which restores their role, teams, repository access and forks once they accept; it needs a free seat."

    static func removeMember(_ user: String, _ membership: Membership, _ service: ServiceClient) async throws -> UndoRecord {
        let record = UndoRecord(id: newRecordID(), action: RemoveMember.name, target: user, created: Date(), state: "sent", undo: ReinstateMember.name,
                                recorded: ["login": user, "userID": membership.user?.id.map(String.init) ?? "", "role": membership.role ?? "", "state": membership.state ?? ""])
        return try await perform(service, record, need: membershipNeed, method: "DELETE", path: try orgPath(service, "memberships", user)) {
            try await GitHub.membership(user, service) == nil
        }
    }

    static let collaboratorRecovery = "Undo: restore-collaborator with this record invites them back to each recorded repository with its recorded permission; they must accept each invitation."

    static func removeCollaborator(_ user: String, cap: Int, _ service: ServiceClient) async throws -> (record: UndoRecord, note: String) {
        let swept = try await grants(of: user, cap: cap, service)
        let note = "Repositories they reached, of the \(swept.read) most recently pushed read: \(grantsLine(swept.grants))."
            + (swept.more ? " The organisation has \(swept.total > swept.read ? "\(swept.total)\(swept.total >= maximumPages * 100 ? " or more" : "")" : "more") repositories; access to those not read is not recorded, so restore-collaborator cannot give it back." : "")
            + (swept.failed.isEmpty ? "" : " Could not be read, so not recorded: \(swept.failed.prefix(5).joined(separator: "; ")).")
        var record = UndoRecord(id: newRecordID(), action: RemoveOutsideCollaborator.name, target: user, created: Date(), state: "sent", undo: RestoreCollaborator.name,
                                recorded: ["login": user, "repositoriesRead": String(swept.read), "complete": String(!swept.more && swept.failed.isEmpty)])
        record.grants = swept.grants
        let done = try await perform(service, record, need: membershipNeed, method: "DELETE", path: try orgPath(service, "outside_collaborators", user)) {
            try await !GitHub.isOutsideCollaborator(user, service)
        }
        return (done, note)
    }
}

// MARK: - Members and collaborators

extension GitHub {
    static let userField = JSONSchema.string("The user's GitHub login, such as mallory.")
    static let recordField = JSONSchema.string("The undo record's ID, as the action's result gave it, such as gh-1a2b3c4d.")

    struct RemoveMember: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "remove-member"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Remove a member from the organisation, or cancel their pending invitation: they lose every team and every repository the organisation gave them, their forks of its private repositories are deleted, and GitHub emails them. Pion records their role and user ID first. \(GitHub.memberRecovery) Refused for the signed-in person and the last owner. Members provisioned by SCIM or Enterprise Managed Users are removed at the identity provider instead."
        static let input = JSONSchema.object(["user": GitHub.userField], required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try GitHub.login(input.user)
            guard let membership = try await GitHub.removable(user, service) else {
                throw ServiceError.input("Nothing was changed: \(user) is neither a member of the organisation nor invited to it. remove-outside-collaborator removes an outside collaborator.")
            }
            let record = try await GitHub.removeMember(user, membership, service)
            return try GitHub.outcome(record, done: "Removed \(user), who was \(membership.state == "pending" ? "invited as" : "a") \(membership.role == "admin" ? "owner" : "member"), from the organisation: their membership no longer reads back.",
                                      unverified: "\(user)'s membership still reads back", recovery: GitHub.memberRecovery)
        }
    }

    struct ReinstateMember: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "reinstate-member"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo remove-member, from its undo record: invite the person back with GitHub's reinstate role, which, within three months of their removal, gives back their role, teams, repository access and forks once they accept. It needs a free seat. Someone who was only invited is invited again with their recorded role. Held, as it gives access back."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: RemoveMember.name, by: Self.name, service)
            guard let userID = Int(record.recorded["userID"] ?? "") else {
                throw ServiceError.input("Nothing was changed: record \(record.id) holds no user ID for \(record.target); invite them again in the organisation's Settings › People.")
            }
            let role = record.recorded["state"] == "pending" ? (record.recorded["role"] == "admin" ? "admin" : "direct_member") : "reinstate"
            let path = try GitHub.orgPath(service, "invitations")
            struct Invitation: Decodable { let id: Int? }
            let invitation: Invitation
            do {
                invitation = try GitHub.decode(try await GitHub.read(GitHub.invitationsNeed) {
                    try await GitHub.send(service, path, method: "POST", body: try GitHub.json(["invitee_id": userID, "role": role]))
                }.data)
            } catch {
                throw ServiceError.input("GitHub refused to invite \(record.target) back: \(error.localizedDescription) More than three months after removal, or without a free seat, GitHub cannot reinstate; invite them in Settings › People.\n\(GitHub.requested("POST", path, "invitee \(userID), role \(role)"))")
            }
            GitHub.markUndone(service, record)
            let text = "GitHub invited \(record.target) back\(invitation.id.map { " (invitation \($0))" } ?? "") with the \(role) role. Until they accept, they have no access; cancel-invitation withdraws it."
            return try ServiceResult(text: text, structured: ["record": record.id, "invitation": invitation.id.map(String.init) ?? "", "role": role])
        }
    }

    struct RemoveOutsideCollaborator: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let repos: Int? }
        static let name = "remove-outside-collaborator"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Remove an outside collaborator from every repository of the organisation. Pion first records the repositories they reach and their permission on each, reading the most recently pushed repositories up to a limit, and says when there were more. \(GitHub.collaboratorRecovery)"
        static let input = JSONSchema.object(["user": GitHub.userField,
                                              "repos": .integer("How many repositories, most recently pushed first, to read for their access before removing them (100 when left out).", minimum: 1, maximum: 300)],
                                             required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try GitHub.login(input.user)
            let cap = input.repos ?? 100
            guard (1...300).contains(cap) else { throw ServiceError.input("Nothing was changed: read between 1 and 300 repositories.") }
            guard try await GitHub.isOutsideCollaborator(user, service) else {
                throw ServiceError.input("Nothing was changed: \(user) is not an outside collaborator of the organisation. remove-member removes a member.")
            }
            let (record, note) = try await GitHub.removeCollaborator(user, cap: cap, service)
            return try GitHub.outcome(record, done: "Removed outside collaborator \(user) from every repository of the organisation: they are no longer listed. \(note)",
                                      unverified: "\(user) is still listed as an outside collaborator", recovery: GitHub.collaboratorRecovery)
        }
    }

    struct RestoreCollaborator: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "restore-collaborator"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo remove-outside-collaborator, from its undo record: invite the person back to each recorded repository with its recorded permission. They must accept each invitation; GitHub sends at most 50 a repository a day. Held, as it gives access back."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: RemoveOutsideCollaborator.name, by: Self.name, service)
            let user = try GitHub.login(record.target)
            guard !record.grants.isEmpty else { throw ServiceError.input("Nothing was changed: record \(record.id) holds no repositories \(user) reached.") }
            var restored: [String] = [], failed: [String] = []
            for grant in record.grants {
                do {
                    let path = try GitHub.repoPath(grant.repo, service, "collaborators", user)
                    let answer = try await GitHub.read(GitHub.collaboratorNeed) {
                        try await GitHub.send(service, path, method: "PUT", body: try GitHub.json(["permission": grant.permission]))
                    }
                    restored.append("\(grant.repo) (\(grant.permission), \(answer.response.statusCode == 201 ? "invited" : "added"))")
                } catch { failed.append("\(grant.repo): \(error.localizedDescription)") }
            }
            if failed.isEmpty { GitHub.markUndone(service, record) }
            let text = (restored.isEmpty ? "" : "Asked GitHub to give \(user) back: \(restored.joined(separator: ", ")). An invited collaborator has no access until they accept.")
                + (failed.isEmpty ? "" : "\nNot restored, so record \(record.id) stays open: \(failed.joined(separator: "; "))")
            if restored.isEmpty { throw ServiceError.input("Nothing was restored for \(user): \(failed.joined(separator: "; "))") }
            return try ServiceResult(text: text, structured: ["record": record.id, "restored": restored.joined(separator: ", "), "failed": failed.joined(separator: "; ")])
        }
    }

    struct CancelInvitation: ServiceOperation {
        struct Input: Decodable, Sendable { let invitation: Int }
        static let name = "cancel-invitation"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "It cannot be undone as such: invite them again in Settings › People with the role and teams the record keeps."
        static let summary = "Cancel a pending invitation to the organisation, by its ID, so it can no longer be accepted; GitHub notifies the invitee. Pion records the invitee, role and teams first. \(recovery)"
        static let input = JSONSchema.object(["invitation": .integer("The invitation's ID.", minimum: 1)], required: ["invitation"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Invitation: Decodable { let id: Int; let login: String?; let email: String?; let role: String?; let inviter: Person? }
            struct Team: Decodable { let id: Int?; let slug: String? }
            let pending = try await GitHub.read(GitHub.invitationsNeed) { try await GitHub.list(service, try GitHub.orgPath(service, "invitations"), as: Invitation.self) }
            guard let invitation = pending.items.first(where: { $0.id == input.invitation }) else {
                throw ServiceError.input("Nothing was changed: the organisation has no pending invitation \(input.invitation)\(pending.more ? " among those Pion reads" : "").")
            }
            let teams = (try? await GitHub.list(service, try GitHub.orgPath(service, "invitations", String(invitation.id), "teams"), pages: 1, as: Team.self).items) ?? []
            let who = invitation.login ?? invitation.email ?? "invitee \(invitation.id)"
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: who, created: Date(), state: "sent", undo: nil,
                                    recorded: ["invitation": String(invitation.id), "login": invitation.login ?? "", "email": invitation.email ?? "", "role": invitation.role ?? "",
                                               "teams": teams.compactMap(\.slug).joined(separator: ","), "inviter": invitation.inviter?.login ?? ""])
            let done = try await GitHub.perform(service, record, need: GitHub.invitationsNeed, method: "DELETE", path: try GitHub.orgPath(service, "invitations", String(invitation.id))) {
                try await !GitHub.list(service, try GitHub.orgPath(service, "invitations"), as: Invitation.self).items.contains { $0.id == invitation.id }
            }
            return try GitHub.outcome(done, done: "Cancelled invitation \(invitation.id) of \(who) as \(invitation.role ?? "a member")\(teams.isEmpty ? "" : " to \(teams.compactMap(\.slug).joined(separator: ", "))"): it is no longer pending.",
                                      unverified: "invitation \(invitation.id) is still pending", recovery: Self.recovery)
        }
    }

    struct BlockUser: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let repos: Int? }
        static let name = "block-user"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Undo: unblock-user with this record lifts the block. Giving back their membership or repository access is a separate step: reinstate-member or restore-collaborator with the removal's record."
        static let summary = "Block a user from the organisation, so they cannot be added to it, comment, open issues or pull requests, or fork its repositories. If they are a member or outside collaborator, this one approval first removes them, recording their role or their repositories and permissions as remove-member and remove-outside-collaborator do, then blocks them. Blocking also cancels their invitations and takes away their stars, watches and assignments, which unblocking does not restore. \(recovery) Refused for the signed-in person and the last owner."
        static let input = JSONSchema.object(["user": GitHub.userField,
                                              "repos": .integer("For an outside collaborator: how many repositories to read for their access first (100 when left out).", minimum: 1, maximum: 300)],
                                             required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try GitHub.login(input.user)
            let cap = input.repos ?? 100
            guard (1...300).contains(cap) else { throw ServiceError.input("Nothing was changed: read between 1 and 300 repositories.") }
            if try await GitHub.isBlocked(user, service) { throw ServiceError.input("Nothing was changed: \(user) is already blocked from the organisation.") }
            let membership = try await GitHub.removable(user, service)
            let collaborator = membership == nil ? try await GitHub.isOutsideCollaborator(user, service) : false
            var lines: [String] = [], removal: UndoRecord?
            if let membership {
                let removed = try await GitHub.removeMember(user, membership, service)
                guard removed.state == "done" else {
                    throw ServiceError.input("GitHub accepted removing \(user) from the organisation, but their membership still reads back, so they were not blocked. Undo record \(removed.id) is kept.\n\(GitHub.memberRecovery)")
                }
                removal = removed
                lines.append("First removed \(user), who was \(membership.role == "admin" ? "an owner" : "a member"), from the organisation; undo record \(removed.id). \(GitHub.memberRecovery)")
            } else if collaborator {
                let (removed, note) = try await GitHub.removeCollaborator(user, cap: cap, service)
                guard removed.state == "done" else {
                    throw ServiceError.input("GitHub accepted removing outside collaborator \(user), but they are still listed, so they were not blocked. Undo record \(removed.id) is kept.\n\(GitHub.collaboratorRecovery)")
                }
                removal = removed
                lines.append("First removed outside collaborator \(user) from every repository; undo record \(removed.id). \(note) \(GitHub.collaboratorRecovery)")
            }
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: user, created: Date(), state: "sent", undo: UnblockUser.name,
                                    recorded: ["login": user, "removed": membership != nil ? "member" : collaborator ? "outside collaborator" : "", "removalRecord": removal?.id ?? ""])
            let done: UndoRecord
            do {
                done = try await GitHub.perform(service, record, need: GitHub.blockingNeed, method: "PUT", path: try GitHub.orgPath(service, "blocks", user)) {
                    try await GitHub.isBlocked(user, service)
                }
            } catch {
                guard let removal else { throw error }
                throw ServiceError.input("\(lines.joined(separator: "\n"))\nThen blocking failed: \(error.localizedDescription) \(user) is removed but not blocked; undo record \(removal.id) gives their access back.")
            }
            lines.append("Blocked \(user) from the organisation: the block reads back.")
            return try GitHub.outcome(done, done: lines.joined(separator: "\n"), unverified: "the block on \(user) does not read back", recovery: Self.recovery)
        }
    }

    struct UnblockUser: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "unblock-user"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo block-user, from its undo record: lift the block, so the user can again interact with the organisation's repositories. Their stars, watches and assignments do not come back, and their membership or repository access is given back separately, with reinstate-member or restore-collaborator. Held, as it gives access back."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: BlockUser.name, by: Self.name, service)
            let user = try GitHub.login(record.target)
            guard try await GitHub.isBlocked(user, service) else {
                GitHub.markUndone(service, record)
                throw ServiceError.input("Nothing was changed: \(user) is not blocked; Pion marks record \(record.id) undone.")
            }
            let path = try GitHub.orgPath(service, "blocks", user)
            do { _ = try await GitHub.read(GitHub.blockingNeed) { try await GitHub.send(service, path, method: "DELETE") } }
            catch { throw ServiceError.input("GitHub refused to unblock \(user): \(error.localizedDescription)\n\(GitHub.requested("DELETE", path, user))") }
            guard try await !GitHub.isBlocked(user, service) else { throw ServiceError.input("GitHub accepted unblocking \(user), but the block still reads back, so it is not reported done.") }
            GitHub.markUndone(service, record)
            let removal = record.recorded["removalRecord"].flatMap { $0.isEmpty ? nil : $0 }
            return try ServiceResult(text: "Unblocked \(user): the block no longer reads back." + (removal.map { " Their \(record.recorded["removed"] ?? "access") is not given back by this: undo record \($0) does that." } ?? ""),
                                     structured: ["record": record.id, "user": user])
        }
    }

    struct DemoteOwner: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "demote-owner"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Undo: restore-owner with this record makes them an owner again; GitHub emails them when it does."
        static let summary = "Make an organisation owner an ordinary member, taking away their power over its settings, members, Apps and every repository; they keep what their teams and the base permission give. GitHub does not email them. \(recovery) Refused for the signed-in person and the last owner."
        static let input = JSONSchema.object(["user": GitHub.userField], required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try GitHub.login(input.user)
            guard let membership = try await GitHub.removable(user, service), membership.state == "active" else {
                throw ServiceError.input("Nothing was changed: \(user) is not an active member of the organisation.")
            }
            guard membership.role == "admin" else { throw ServiceError.input("Nothing was changed: \(user) is a \(membership.role ?? "member"), not an owner.") }
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: user, created: Date(), state: "sent", undo: RestoreOwner.name,
                                    recorded: ["login": user, "role": "admin"])
            let done = try await GitHub.perform(service, record, need: GitHub.membershipNeed, method: "PUT", path: try GitHub.orgPath(service, "memberships", user),
                                                body: try GitHub.json(["role": "member"])) {
                try await GitHub.membership(user, service)?.role == "member"
            }
            return try GitHub.outcome(done, done: "\(user) is now a member, no longer an owner: the role reads back.", unverified: "\(user)'s role does not read back as member", recovery: Self.recovery)
        }
    }

    struct RestoreOwner: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "restore-owner"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo demote-owner, from its undo record: make the person an organisation owner again. GitHub emails them. Held, as it gives access back."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: DemoteOwner.name, by: Self.name, service)
            let user = try GitHub.login(record.target)
            let path = try GitHub.orgPath(service, "memberships", user)
            do { _ = try await GitHub.read(GitHub.membershipNeed) { try await GitHub.send(service, path, method: "PUT", body: try GitHub.json(["role": "admin"])) } }
            catch { throw ServiceError.input("GitHub refused to make \(user) an owner again: \(error.localizedDescription)\n\(GitHub.requested("PUT", path, "role admin"))") }
            guard try await GitHub.membership(user, service)?.role == "admin" else {
                throw ServiceError.input("GitHub accepted making \(user) an owner again, but the role does not read back as owner, so it is not reported done.")
            }
            GitHub.markUndone(service, record)
            return try ServiceResult(text: "\(user) is an owner of the organisation again: the role reads back.", structured: ["record": record.id, "user": user, "role": "admin"])
        }
    }

    struct RemoveFromTeam: ServiceOperation {
        struct Input: Decodable, Sendable { let team: String; let user: String }
        static let name = "remove-from-team"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Undo: restore-team-membership with this record adds them back with the role they had."
        static let summary = "Take someone off one team, so they lose the repositories and permissions it gives them; they stay in the organisation. Pion records whether they were a member or maintainer first. Teams synced from an identity provider refuse it. \(recovery)"
        static let input = JSONSchema.object(["team": .string("The team's slug, such as platform-admins, as teams gives it."), "user": GitHub.userField], required: ["team", "user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let team = try GitHub.slug(input.team), user = try GitHub.login(input.user)
            let path = try GitHub.orgPath(service, "teams", team, "memberships", user)
            let answer = try await GitHub.read(GitHub.teamNeed) { try await GitHub.send(service, path, returning: [404]) }
            guard answer.response.statusCode != 404 else { throw ServiceError.input("Nothing was changed: \(user) is not on team \(team), or the team does not exist.") }
            let membership: Membership = try GitHub.decode(answer.data)
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "\(user) on team \(team)", created: Date(), state: "sent", undo: RestoreTeamMembership.name,
                                    recorded: ["login": user, "team": team, "role": membership.role ?? "member", "state": membership.state ?? ""])
            let done = try await GitHub.perform(service, record, need: GitHub.teamNeed, method: "DELETE", path: path) {
                try await GitHub.send(service, path, returning: [404]).response.statusCode == 404
            }
            return try GitHub.outcome(done, done: "Took \(user), a team \(membership.role ?? "member"), off team \(team): the membership no longer reads back.",
                                      unverified: "\(user)'s membership of \(team) still reads back", recovery: Self.recovery)
        }
    }

    struct RestoreTeamMembership: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "restore-team-membership"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo remove-from-team, from its undo record: add the person back to the team with the role they had. Someone no longer in the organisation is invited to it instead. Held, as it gives access back."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: RemoveFromTeam.name, by: Self.name, service)
            let user = try GitHub.login(record.recorded["login"] ?? ""), team = try GitHub.slug(record.recorded["team"] ?? "")
            let role = record.recorded["role"] == "maintainer" ? "maintainer" : "member"
            let path = try GitHub.orgPath(service, "teams", team, "memberships", user)
            let membership: Membership
            do { membership = try GitHub.decode(try await GitHub.read(GitHub.teamNeed) { try await GitHub.send(service, path, method: "PUT", body: try GitHub.json(["role": role])) }.data) }
            catch { throw ServiceError.input("GitHub refused to add \(user) back to \(team): \(error.localizedDescription)\n\(GitHub.requested("PUT", path, "role \(role)"))") }
            GitHub.markUndone(service, record)
            return try ServiceResult(text: "Added \(user) back to team \(team) as \(membership.role ?? role)\(membership.state == "pending" ? "; they are not in the organisation, so GitHub invited them, and they join when they accept" : "").",
                                     structured: ["record": record.id, "user": user, "team": team, "role": membership.role ?? role, "state": membership.state ?? ""])
        }
    }
}

// MARK: - Tokens, keys and credentials

extension GitHub {
    struct RevokeFineGrainedToken: ServiceOperation {
        struct Input: Decodable, Sendable { let token: Int }
        static let name = "revoke-fine-grained-token"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "It cannot be undone: the token's owner must ask for access again, which an owner approves if the organisation requires approval."
        static let summary = "End a fine-grained personal access token's access to the organisation, by the ID fine-grained-tokens gives. GitHub emails its owner; the token still reads public resources, and SSH keys it made keep working. \(recovery)"
        static let input = JSONSchema.object(["token": .integer("The token's ID, as fine-grained-tokens gives it.", minimum: 1)], required: ["token"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let path = try GitHub.orgPath(service, "personal-access-tokens")
            let held = try await GitHub.read(GitHub.tokenRevokeNeed) { try await GitHub.list(service, path, as: FineGrainedToken.self) }
            guard let token = held.items.first(where: { $0.id == input.token }) else {
                throw ServiceError.input("Nothing was changed: no fine-grained token \(input.token) has access to the organisation\(held.more ? " among those Pion reads" : "").")
            }
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "token \(token.id) (\(token.token_name ?? "unnamed") of \(token.owner?.login ?? "?"))",
                                    created: Date(), state: "sent", undo: nil,
                                    recorded: ["token": String(token.id), "name": token.token_name ?? "", "owner": token.owner?.login ?? "", "expires": token.token_expires_at ?? "never"])
            let done = try await GitHub.perform(service, record, need: GitHub.tokenRevokeNeed, method: "POST", path: path + [String(token.id)],
                                                body: try GitHub.json(["action": "revoke"])) {
                try await !GitHub.list(service, path, as: FineGrainedToken.self).items.contains { $0.id == token.id }
            }
            return try GitHub.outcome(done, done: "Revoked \(record.target)'s access to the organisation: it is no longer listed.", unverified: "the token is still listed", recovery: Self.recovery)
        }
    }

    struct DeleteDeployKey: ServiceOperation {
        struct Input: Decodable, Sendable { let repo: String; let key: Int }
        static let name = "delete-deploy-key"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Undo: restore-deploy-key with this record adds the same public key back, with its title and read-only setting, under a new ID; the private key is never GitHub's or Pion's to give back."
        static let summary = "Delete a deploy key from one of the organisation's repositories, so whoever holds its private key can no longer reach the repository with it. Pion records the public key, its title and whether it was read-only first. \(recovery)"
        static let input = JSONSchema.object(["repo": .string("The repository, by name or as organisation/name."), "key": .integer("The deploy key's ID, as deploy-keys gives it.", minimum: 1)],
                                             required: ["repo", "key"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let repo = try GitHub.repository(input.repo, service)
            let path = try GitHub.repoPath(repo, service, "keys", String(input.key))
            let key: DeployKey
            do { key = try await GitHub.read(GitHub.deployKeyNeed) { try await GitHub.get(service, path, as: DeployKey.self) } }
            catch ServiceError.notFound { throw ServiceError.input("Nothing was changed: \(repo) has no deploy key \(input.key).") }
            guard let publicKey = key.key, !publicKey.isEmpty else { throw ServiceError.input("Nothing was changed: GitHub did not give deploy key \(input.key)'s public key, so it could not be restored.") }
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "deploy key \(key.id) (\(key.title ?? "untitled")) of \(repo)", created: Date(), state: "sent",
                                    undo: RestoreDeployKey.name,
                                    recorded: ["repo": repo, "key": publicKey, "title": key.title ?? "", "readOnly": String(key.read_only ?? true), "id": String(key.id)])
            let done = try await GitHub.perform(service, record, need: GitHub.deployKeyNeed, method: "DELETE", path: path) {
                try await GitHub.send(service, path, returning: [404]).response.statusCode == 404
            }
            return try GitHub.outcome(done, done: "Deleted \(record.target), which \(key.read_only == false ? "could write" : "could read"): it no longer reads back.", unverified: "the key still reads back", recovery: Self.recovery)
        }
    }

    struct RestoreDeployKey: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "restore-deploy-key"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo delete-deploy-key, from its undo record: add the same public key back to the repository with its title and read-only setting, under a new ID. Refused when the organisation no longer allows deploy keys. Held, as it gives access back."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: DeleteDeployKey.name, by: Self.name, service)
            let repo = try GitHub.repository(record.recorded["repo"] ?? "", service)
            guard let key = record.recorded["key"], !key.isEmpty else { throw ServiceError.input("Nothing was changed: record \(record.id) holds no public key.") }
            let readOnly = record.recorded["readOnly"] != "false"
            let path = try GitHub.repoPath(repo, service, "keys")
            let made: DeployKey
            do {
                made = try GitHub.decode(try await GitHub.read(GitHub.deployKeyNeed) {
                    try await GitHub.send(service, path, method: "POST", body: try GitHub.json(["title": record.recorded["title"] ?? "", "key": key, "read_only": readOnly]))
                }.data)
            } catch { throw ServiceError.input("GitHub refused to add the deploy key back to \(repo): \(error.localizedDescription)\n\(GitHub.requested("POST", path, record.target))") }
            GitHub.markUndone(service, record)
            return try ServiceResult(text: "Added the deploy key back to \(repo) as key \(made.id), \(readOnly ? "read-only" : "able to write"), titled \(made.title ?? record.recorded["title"] ?? "").",
                                     structured: ["record": record.id, "repo": repo, "key": String(made.id), "readOnly": String(readOnly)])
        }
    }

    struct RevokeSSOCredential: ServiceOperation {
        struct Input: Decodable, Sendable { let credential: Int }
        static let name = "revoke-sso-credential"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "It cannot be undone by Pion: the person authorizes the credential for single sign-on again, if they still may."
        static let summary = "End a credential's SAML single sign-on authorization for the organisation, by the ID credential-authorizations gives, so the token, SSH key or App token no longer reaches the organisation's resources; the credential itself is not deleted. Only GitHub Enterprise Cloud with SAML single sign-on. \(recovery)"
        static let input = JSONSchema.object(["credential": .integer("The credential's ID, as credential-authorizations gives it.", minimum: 1)], required: ["credential"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let path = try GitHub.orgPath(service, "credential-authorizations")
            let held = try await GitHub.read(GitHub.ssoRevokeNeed) { try await GitHub.list(service, path, as: CredentialAuthorization.self) }
            guard let credential = held.items.first(where: { $0.credential_id == input.credential }) else {
                throw ServiceError.input("Nothing was changed: no credential \(input.credential) is authorized for the organisation's single sign-on\(held.more ? " among those Pion reads" : "").")
            }
            let me = try? await GitHub.signer(service)
            if let me, credential.login?.lowercased() == me.login.lowercased(), credential.credential_type?.lowercased().contains("app") == true {
                throw ServiceError.input("Nothing was changed: credential \(input.credential) may be this connection's own sign-in.")
            }
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "\(credential.credential_type ?? "credential") \(credential.credential_id) of \(credential.login ?? "?")",
                                    created: Date(), state: "sent", undo: nil,
                                    recorded: ["credential": String(credential.credential_id), "login": credential.login ?? "", "type": credential.credential_type ?? "", "lastEight": credential.token_last_eight ?? ""])
            let done = try await GitHub.perform(service, record, need: GitHub.ssoRevokeNeed, method: "DELETE", path: path + [String(credential.credential_id)]) {
                try await !GitHub.list(service, path, as: CredentialAuthorization.self).items.contains { $0.credential_id == credential.credential_id }
            }
            return try GitHub.outcome(done, done: "Ended the single sign-on authorization of \(record.target): it is no longer listed.", unverified: "the authorization is still listed", recovery: Self.recovery)
        }
    }

    /// The kinds of GitHub token GitHub's revocation takes, by their prefixes.
    static let leakedTokenKinds = [("github_pat_", "fine-grained personal access token"), ("ghp_", "classic personal access token"), ("gho_", "OAuth app token"),
                                   ("ghu_", "GitHub App user token"), ("ghr_", "GitHub App refresh token")]

    /// A short SHA-256 fingerprint of a token, so a record can name it without holding it.
    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    struct ReportLeakedToken: ServiceOperation {
        struct Input: Decodable, Sendable { let token: String }
        static let name = "report-leaked-token"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "It cannot be undone: the token's owner makes a new one."
        static let summary = "Send a leaked GitHub token, of anyone, to GitHub's credential revocation, which revokes it and notifies its owner: a classic or fine-grained personal access token, an OAuth app token, or a GitHub App user or refresh token. It is sent without signing in, as GitHub refuses a signed-in report, only to api.github.com. Pion never keeps or repeats the token: its record holds only the kind and a short SHA-256 fingerprint. The token itself is this action's input, so it stays in the approval request, which keeps a declined or expired request for 7 days. GitHub takes 60 such reports an hour from one address. \(recovery)"
        static let input = JSONSchema.object(["token": .string("The leaked token, whole, such as ghp_….")], required: ["token"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let token = input.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = GitHub.leakedTokenKinds.first(where: { token.hasPrefix($0.0) }), (token.count - kind.0.count) >= 20, token.count <= 300,
                  token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw ServiceError.input("Nothing was sent: that is not a GitHub token GitHub's revocation takes; give the whole token, starting \(GitHub.leakedTokenKinds.map(\.0).joined(separator: ", ")).")
            }
            let fingerprint = GitHub.fingerprint(token)
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "\(kind.1) \(kind.0)… (SHA-256 \(fingerprint))", created: Date(), state: "sent", undo: nil,
                                    recorded: ["prefix": kind.0, "kind": kind.1, "sha256": fingerprint])
            do { try GitHub.keep(service, record) } catch {
                throw ServiceError.input("Nothing was sent: Pion could not keep its record of the report (\(error.localizedDescription)).")
            }
            // Signed out, at api.github.com only: the connection's sign-in never goes with it.
            let anonymous = ServiceClient(base: URL(string: "https://\(GitHub.host)")!, access: GitHub.anonymous)
            func scrub(_ text: String) -> String { text.replacingOccurrences(of: token, with: "[the token]") }
            do {
                _ = try await anonymous.exchange(["credentials", "revoke"], method: "POST", body: try GitHub.json(["credentials": [token]]), headers: GitHub.headers)
            } catch {
                try? GitHub.changeRecords(service) { $0.removeAll { $0.id == record.id } }
                throw ServiceError.input(scrub("GitHub did not take the report of the \(kind.1) (SHA-256 \(fingerprint)): \(error.localizedDescription) Nothing was revoked."))
            }
            var sent = record
            sent.state = "done"
            try? GitHub.keep(service, sent)
            let text = "GitHub accepted the report of a \(kind.1) (SHA-256 \(fingerprint)): it revokes the token and notifies its owner. Pion cannot confirm the revocation itself, as it never uses the token.\nRecord \(sent.id).\n\(Self.recovery)"
            struct Kept: Encodable { let done: Bool; let record: UndoRecord; let recovery: String }
            return try ServiceResult(text: text, structured: Kept(done: true, record: sent, recovery: Self.recovery))
        }
    }
}

// MARK: - Webhooks and Actions

extension GitHub {
    static let hookRecovery = "Undo: enable-webhook with this record turns it on again. GitHub's documentation warns that updating a webhook may remove its secret; Pion sends only active and checks whether the secret is still set, and says so if it is not."

    /// Turns a hook on or off, sending only `active`, and says whether its secret survived.
    static func setHook(_ id: Int, active: Bool, secretBefore: Bool, _ service: ServiceClient) async throws -> (verified: Bool, secretLost: Bool) {
        let path = try orgPath(service, "hooks", String(id))
        _ = try await read(hookNeed) { try await send(service, path, method: "PATCH", body: try json(["active": active])) }
        let after = try? await get(service, path, as: Hook.self)
        return (after?.active == active, secretBefore && after != nil && after?.config?.secret == nil)
    }

    struct DisableWebhook: ServiceOperation {
        struct Input: Decodable, Sendable { let hook: Int }
        static let name = "disable-webhook"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Stop one of the organisation's webhooks delivering events, by the ID webhooks gives, such as one sending to an address an attacker added; the hook and its settings are kept. Pion records its events, content type and whether it had a secret first. \(GitHub.hookRecovery)"
        static let input = JSONSchema.object(["hook": .integer("The webhook's ID, as webhooks gives it.", minimum: 1)], required: ["hook"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let path = try GitHub.orgPath(service, "hooks", String(input.hook))
            let hook: Hook
            do { hook = try await GitHub.read(GitHub.hookNeed) { try await GitHub.get(service, path, as: Hook.self) } }
            catch ServiceError.notFound { throw ServiceError.input("Nothing was changed: the organisation has no webhook \(input.hook) this sign-in can see.") }
            guard hook.active != false else { throw ServiceError.input("Nothing was changed: webhook \(input.hook) is already inactive.") }
            let secret = hook.config?.secret != nil
            var record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "webhook \(hook.id) to \(GitHub.host(of: hook.config?.url))", created: Date(), state: "sent",
                                    undo: EnableWebhook.name,
                                    recorded: ["hook": String(hook.id), "host": GitHub.host(of: hook.config?.url), "events": (hook.events ?? []).joined(separator: ","),
                                               "contentType": hook.config?.content_type ?? "", "secret": String(secret)])
            do { try GitHub.keep(service, record) } catch {
                throw ServiceError.input("Nothing was changed: Pion could not keep its undo record (\(error.localizedDescription)), so it sends nothing.")
            }
            let result: (verified: Bool, secretLost: Bool)
            do { result = try await GitHub.setHook(hook.id, active: false, secretBefore: secret, service) } catch {
                try? GitHub.changeRecords(service) { $0.removeAll { $0.id == record.id } }
                throw ServiceError.input("GitHub refused to disable \(record.target): \(error.localizedDescription) Nothing was changed.\n\(GitHub.requested("PATCH", path, "active false"))")
            }
            record.state = result.verified ? "done" : "unverified"
            try? GitHub.keep(service, record)
            let lost = result.secretLost ? "\n⚠ The hook no longer reads back with a secret: GitHub removed it with the update. Before turning it on again, set a new secret in the hook's settings and in the receiver." : ""
            return try GitHub.outcome(record, done: "Disabled \(record.target): it reads back inactive and delivers nothing until turned on again.\(lost)",
                                      unverified: "the hook does not read back inactive\(lost)", recovery: GitHub.hookRecovery)
        }
    }

    struct EnableWebhook: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "enable-webhook"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo disable-webhook, from its undo record: turn the webhook on again, sending only active, and check its secret is still set. Events missed while it was off are not sent again. Held, as it starts sending the organisation's events out again."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: DisableWebhook.name, by: Self.name, service)
            guard let id = Int(record.recorded["hook"] ?? "") else { throw ServiceError.input("Nothing was changed: record \(record.id) holds no webhook ID.") }
            let result: (verified: Bool, secretLost: Bool)
            do { result = try await GitHub.setHook(id, active: true, secretBefore: record.recorded["secret"] == "true", service) }
            catch { throw ServiceError.input("GitHub refused to turn \(record.target) on again: \(error.localizedDescription)") }
            guard result.verified else { throw ServiceError.input("GitHub accepted turning \(record.target) on again, but it does not read back active, so it is not reported done.") }
            GitHub.markUndone(service, record)
            let lost = result.secretLost ? " ⚠ It had a secret and no longer reads back with one: set a new secret in the hook's settings and in the receiver, as deliveries are now unsigned." : ""
            return try ServiceResult(text: "Turned \(record.target) on again: it reads back active.\(lost)", structured: ["record": record.id, "hook": String(id), "secretLost": String(result.secretLost)])
        }
    }

    struct RepoActions: Codable, Sendable { let enabled: Bool?; let allowed_actions: String?; let sha_pinning_required: Bool? }
    struct OrgActions: Codable, Sendable { let enabled_repositories: String?; let allowed_actions: String?; let sha_pinning_required: Bool? }
    struct ActionsRepository: Decodable, Sendable { let id: Int }

    struct DisableActions: ServiceOperation {
        struct Input: Decodable, Sendable { let repo: String? }
        static let name = "disable-actions"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Undo: enable-actions with this record puts back the settings recorded. Workflows that did not run meanwhile are not run again."
        static let summary = "Stop GitHub Actions in one repository, or, with no repository given, in every repository of the organisation, so no workflow runs, such as one leaking secrets or mining; runs under way are not cancelled (cancel-workflow-run does that). Pion records the settings it replaces first, and for the organisation which repositories were allowed. \(recovery)"
        static let input = JSONSchema.object(["repo": .string("One repository, by name or as organisation/name. The whole organisation when left out.")])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            if let given = input.repo {
                let repo = try GitHub.repository(given, service)
                let path = try GitHub.repoPath(repo, service, "actions", "permissions")
                let before = try await GitHub.read(GitHub.repoActionsNeed) { try await GitHub.get(service, path, as: RepoActions.self) }
                guard before.enabled != false else { throw ServiceError.input("Nothing was changed: Actions are already off in \(repo).") }
                var recorded = ["scope": "repository", "repo": repo, "enabled": "true"]
                recorded["allowedActions"] = before.allowed_actions
                recorded["shaPinningRequired"] = before.sha_pinning_required.map { String($0) }
                let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "Actions in \(repo)", created: Date(), state: "sent", undo: EnableActions.name, recorded: recorded)
                let done = try await GitHub.perform(service, record, need: GitHub.repoActionsNeed, method: "PUT", path: path, body: try GitHub.json(["enabled": false])) {
                    try await GitHub.get(service, path, as: RepoActions.self).enabled == false
                }
                return try GitHub.outcome(done, done: "Turned Actions off in \(repo): it reads back off. It allowed \(before.allowed_actions ?? "?") actions before.", unverified: "Actions do not read back off in \(repo)", recovery: Self.recovery)
            }
            let path = try GitHub.orgPath(service, "actions", "permissions")
            let before = try await GitHub.read(GitHub.orgActionsNeed) { try await GitHub.get(service, path, as: OrgActions.self) }
            guard before.enabled_repositories != "none" else { throw ServiceError.input("Nothing was changed: Actions are already off for every repository of the organisation.") }
            var recorded = ["scope": "organization", "enabledRepositories": before.enabled_repositories ?? "all"]
            recorded["allowedActions"] = before.allowed_actions
            recorded["shaPinningRequired"] = before.sha_pinning_required.map { String($0) }
            if before.enabled_repositories == "selected" {
                let selected = try await GitHub.read(GitHub.orgActionsNeed) {
                    try await GitHub.list(service, path + ["repositories"], key: "repositories", as: ActionsRepository.self)
                }
                guard !selected.more else { throw ServiceError.input("Nothing was changed: more repositories are allowed Actions than Pion reads, so they could not all be recorded to give back.") }
                recorded["selectedRepositoryIDs"] = selected.items.map { String($0.id) }.joined(separator: ",")
            }
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "Actions in every repository of the organisation", created: Date(), state: "sent",
                                    undo: EnableActions.name, recorded: recorded)
            let done = try await GitHub.perform(service, record, need: GitHub.orgActionsNeed, method: "PUT", path: path, body: try GitHub.json(["enabled_repositories": "none"])) {
                try await GitHub.get(service, path, as: OrgActions.self).enabled_repositories == "none"
            }
            return try GitHub.outcome(done, done: "Turned Actions off for every repository of the organisation: it reads back as none. Before, they ran in \(before.enabled_repositories ?? "?") repositories, allowing \(before.allowed_actions ?? "?") actions.",
                                      unverified: "the organisation's Actions do not read back off", recovery: Self.recovery)
        }
    }

    struct EnableActions: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String }
        static let name = "enable-actions"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Undo disable-actions, from its undo record: put back the Actions settings it recorded, for the repository or the organisation, with the repositories that were allowed. Held, as workflows start running again."
        static let input = JSONSchema.object(["record": GitHub.recordField], required: ["record"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let record = try GitHub.undoable(input.record, action: DisableActions.name, by: Self.name, service)
            var body: [String: Any] = [:]
            if let allowed = record.recorded["allowedActions"], !allowed.isEmpty { body["allowed_actions"] = allowed }
            if let pinning = record.recorded["shaPinningRequired"] { body["sha_pinning_required"] = pinning == "true" }
            if record.recorded["scope"] == "repository" {
                let repo = try GitHub.repository(record.recorded["repo"] ?? "", service)
                let path = try GitHub.repoPath(repo, service, "actions", "permissions")
                body["enabled"] = true
                do { _ = try await GitHub.read(GitHub.repoActionsNeed) { try await GitHub.send(service, path, method: "PUT", body: try GitHub.json(body)) } }
                catch { throw ServiceError.input("GitHub refused to turn Actions on again in \(repo): \(error.localizedDescription)\n\(GitHub.requested("PUT", path, "enabled true"))") }
                guard try await GitHub.get(service, path, as: RepoActions.self).enabled == true else {
                    throw ServiceError.input("GitHub accepted turning Actions on again in \(repo), but they do not read back on, so it is not reported done.")
                }
                GitHub.markUndone(service, record)
                return try ServiceResult(text: "Turned Actions on again in \(repo), allowing \(record.recorded["allowedActions"] ?? "the actions it allowed before"): it reads back on.", structured: ["record": record.id, "repo": repo])
            }
            let enabled = record.recorded["enabledRepositories"] ?? "all"
            let path = try GitHub.orgPath(service, "actions", "permissions")
            body["enabled_repositories"] = enabled
            do {
                _ = try await GitHub.read(GitHub.orgActionsNeed) { try await GitHub.send(service, path, method: "PUT", body: try GitHub.json(body)) }
                if enabled == "selected" {
                    let ids = (record.recorded["selectedRepositoryIDs"] ?? "").split(separator: ",").compactMap { Int($0) }
                    _ = try await GitHub.read(GitHub.orgActionsNeed) {
                        try await GitHub.send(service, path + ["repositories"], method: "PUT", body: try GitHub.json(["selected_repository_ids": ids]))
                    }
                }
            } catch { throw ServiceError.input("GitHub refused to put the organisation's Actions settings back: \(error.localizedDescription)\n\(GitHub.requested("PUT", path, "enabled_repositories \(enabled)"))") }
            guard try await GitHub.get(service, path, as: OrgActions.self).enabled_repositories == enabled else {
                throw ServiceError.input("GitHub accepted putting the organisation's Actions settings back, but they do not read back as \(enabled), so it is not reported done.")
            }
            GitHub.markUndone(service, record)
            return try ServiceResult(text: "Put the organisation's Actions settings back: Actions run in \(enabled) repositories again, allowing \(record.recorded["allowedActions"] ?? "the actions allowed before").",
                                     structured: ["record": record.id, "enabledRepositories": enabled])
        }
    }

    struct CancelWorkflowRun: ServiceOperation {
        struct Input: Decodable, Sendable { let repo: String; let run: Int }
        static let name = "cancel-workflow-run"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "It cannot be undone; the workflow can be run again from the run's page, as a new run."
        static let summary = "Cancel a queued or running workflow run in one of the organisation's repositories, such as one exfiltrating secrets. Steps set to run always may still run while it stops. \(recovery)"
        static let input = JSONSchema.object(["repo": .string("The repository, by name or as organisation/name."), "run": .integer("The workflow run's ID.", minimum: 1)],
                                             required: ["repo", "run"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Run: Decodable { let id: Int; let name: String?; let status: String?; let conclusion: String?; let head_branch: String?; let event: String?; let actor: Person? }
            let repo = try GitHub.repository(input.repo, service)
            let path = try GitHub.repoPath(repo, service, "actions", "runs", String(input.run))
            let run: Run
            do { run = try await GitHub.read(GitHub.runsNeed) { try await GitHub.get(service, path, as: Run.self) } }
            catch ServiceError.notFound { throw ServiceError.input("Nothing was changed: \(repo) has no workflow run \(input.run).") }
            guard run.status != "completed" else { throw ServiceError.input("Nothing was changed: run \(run.id) has already finished (\(run.conclusion ?? "no conclusion given")).") }
            let record = UndoRecord(id: GitHub.newRecordID(), action: Self.name, target: "run \(run.id) (\(run.name ?? "workflow")) of \(repo)", created: Date(), state: "sent", undo: nil,
                                    recorded: ["repo": repo, "run": String(run.id), "workflow": run.name ?? "", "branch": run.head_branch ?? "", "event": run.event ?? "", "actor": run.actor?.login ?? "", "status": run.status ?? ""])
            let done = try await GitHub.perform(service, record, need: GitHub.runsNeed, method: "POST", path: path + ["cancel"]) {
                for wait in GitHub.pauses {
                    await GitHub.pause(wait)
                    if let now = try? await GitHub.get(service, path, as: Run.self), now.status == "completed" { return now.conclusion == "cancelled" }
                }
                return false
            }
            return try GitHub.outcome(done, done: "Cancelled \(record.target), started by \(run.actor?.login ?? "?") on \(run.head_branch ?? "?"): it reads back cancelled.",
                                      unverified: "the run has not read back cancelled yet; GitHub may still be stopping it", recovery: Self.recovery)
        }
    }
}

// MARK: - Reads

extension GitHub {
    struct UndoRecords: ServiceOperation {
        struct Input: Decodable, Sendable { let record: String? }
        static let name = "undo-records"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Pion's records of what GitHub Containment did through this connection, newest first, each with what it recorded and the operation that undoes it, or one by its ID. It changes nothing."
        static let input = JSONSchema.object(["record": .string("One record's ID. All when left out.")])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var records = try GitHub.undoRecords(service).reversed().map { $0 }
            if let id = input.record?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                records = records.filter { $0.id == id }
                if records.isEmpty { throw ServiceError.input("Pion has no undo record \(id) for this connection.") }
            }
            let lines = records.isEmpty ? ["GitHub Containment has done nothing through this connection."] : records.prefix(50).map { record in
                let kept = record.recorded.filter { !$0.value.isEmpty && $0.key != "key" }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                return "\(record.id) \(GitHub.iso(record.created)) \(record.action) \(record.target): \(record.state)"
                    + (record.undone.map { " at \(GitHub.iso($0))" } ?? "")
                    + "; \(record.undo.map { record.undone == nil ? "undo with \($0)" : "undone" } ?? "cannot be undone")"
                    + (kept.isEmpty ? "" : ". Recorded: \(kept)")
                    + (record.grants.isEmpty ? "" : ". Repositories: \(GitHub.grantsLine(record.grants))")
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["records": Array(records.prefix(200))])
        }
    }

    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Says who signed in and whether they are an owner, as the actions need, how the App is installed and which of the permissions the actions take it lacks, and tries what the actions read first. It sends only reads."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try GitHub.api(service)
            let org = try GitHub.org(service)
            var lines = ["· Organisation \(org), reached at https://\(GitHub.host) and nowhere else; report-leaked-token alone goes there without signing in."]
            lines += await GitHub.signerLines(service, wantOwner: "removing people, blocking, webhooks, tokens and the organisation's Actions settings need an owner")
            lines += await GitHub.installationLines(service, wanted: GitHub.containmentPermissions)
            let one: [String: String?] = ["per_page": "1"]
            lines.append(await GitHub.probe(GitHub.membershipNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "members"), query: one, as: [Person].self) })
            lines.append(await GitHub.probe(GitHub.invitationsNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "invitations"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.blockingNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "blocks"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.hookNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "hooks"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.tokenRevokeNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "personal-access-tokens"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.orgActionsNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "actions", "permissions"), as: [String: CellValue].self) })
            var first: Repository?
            lines.append(await GitHub.probe(GitHub.reposNeed) { first = try await GitHub.get(service, try GitHub.orgPath(service, "repos"), query: ["per_page": "1", "sort": "pushed"], as: [Repository].self).first })
            if let first {
                lines.append(await GitHub.probe(GitHub.deployKeyNeed) { _ = try await GitHub.get(service, try GitHub.repoPath(first.name, service, "keys"), query: one, as: [CellValue].self) })
                lines.append(await GitHub.probe(GitHub.repoActionsNeed) { _ = try await GitHub.get(service, try GitHub.repoPath(first.name, service, "actions", "permissions"), as: [String: CellValue].self) })
                lines.append(await GitHub.probe(GitHub.runsNeed) { _ = try await GitHub.get(service, try GitHub.repoPath(first.name, service, "actions", "runs"), query: one, as: [String: CellValue].self) })
            }
            lines.append(await GitHub.probe(GitHub.ssoRevokeNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "credential-authorizations"), query: one, as: [CellValue].self) })
            lines.append("· The actions' changes are not tried: check-access sends none, so an action refused for want of a permission or role says which.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
