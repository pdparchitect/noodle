import Foundation
import NoodleCore
import NoodleToolConnections

/// GitHub: one organisation, read and contained through two private GitHub Apps the organisation registers itself, as
/// Pion ships no clients. GitHub Detection only reads: the audit log, people, teams and security alerts, which its
/// watch follows, and, for an audit, the organisation's settings, members without two-factor authentication, other
/// Apps' installations, webhooks, each repository's secret scanning, push protection and branch rules, deploy keys,
/// fine-grained tokens, Actions settings and SAML credential authorizations. GitHub Containment, a tool of its own with
/// an App and sign-in of its own, acts, each action held for the champion's approval.
///
/// Each App signs in with GitHub's device flow, which needs only the App's Client ID: its browser sign-in needs a client
/// secret a Mac app cannot keep. A GitHub App takes no OAuth scopes; what its token may do is what the App's registered
/// permissions and the signed-in person's own role both allow, and only where the App is installed. User tokens last
/// eight hours and are refreshed without a secret, as the device flow allows.
///
/// Every request goes to api.github.com, under the connection's organisation: an organisation path names it, and a
/// repository path names it as the owner, so a repository of any other owner is refused before anything is sent.
///
/// Both tools' guide is Incubator/Pion/docs/tools/github.md. Change it with the setup steps, permissions or operations here.
public enum GitHub {
    public static let preset = ToolDefinition(
        id: "07d106a4-0e2c-47b1-a743-3c71161e56e4", name: "GitHub Detection",
        summary: "A GitHub organisation's audit log, members, teams and security alerts, and its settings, two-factor gaps, App installations, webhooks, repository security, deploy keys, fine-grained tokens, Actions settings and SAML authorizations, read-only.",
        defaultInstructions: """
        Use GitHub Detection to see what happened in a GitHub organisation and how it is exposed. audit-log searches \
        who did what and when, such as repo.destroy, org.add_member or protected_branch changes (GitHub Enterprise \
        Cloud only); people lists members, owners and outside collaborators; teams lists teams with their members; \
        security-alerts lists open secret scanning, code scanning and Dependabot alerts. The alert watch wakes you for \
        new leaked secrets and high or critical code and dependency alerts, naming security-alerts. For an audit: \
        org-settings reads the two-factor requirement, base repository permission, what members may create and fork, \
        and the code security configurations; members-without-2fa lists members and outside collaborators without \
        two-factor authentication or with an insecure method; app-installations lists other GitHub Apps installed, \
        riskiest first; webhooks lists where the organisation sends events; repo-security reads each repository's \
        secret scanning and push protection and its default branch's rules; deploy-keys lists deploy keys, write keys \
        first; fine-grained-tokens lists fine-grained personal access tokens with access and pending requests; \
        actions-settings reads Actions policy, the default GITHUB_TOKEN permissions and self-hosted runners; \
        credential-authorizations lists credentials authorized for SAML single sign-on (Enterprise Cloud). Most \
        audit reads need the signed-in person to be an organisation owner. When a tool is refused or something seems \
        missing, run check-access and tell the champion exactly what it says to change. Silence is not proof: every \
        result says when it stopped before reading everything. Record each finding as evidence, citing the \
        repository, user and time. These tools only read: recommend removing a member, blocking a user, revoking a \
        token or deleting a deploy key to the champion, or use GitHub Containment, with the target, why, and how to undo it.
        """,
        iconName: "github",
        configuration: .connection(.init(endpointTemplate: "https://\(host)", fields: fields, oauth: oauth,
                                         oauthClientField: "clientID", adapter: "github")),
        setup: setup)

    static let fields = [ToolField(key: "org", title: "Organisation", placeholder: "kestrel-labs", kind: .identifier),
                         ToolField(key: "clientID", title: "Client ID", placeholder: "Iv23liAbCdEfGhIjKlMn", kind: .identifier)]

    /// GitHub's device sign-in, the same for both tools, each through its own App. A GitHub App takes no scopes: its
    /// registered permissions decide what its tokens may do, and GitHub lists none as granted.
    static let oauth = MCPOAuthConfiguration(issuer: URL(string: "https://github.com")!,
                                             authorizationEndpoint: URL(string: "https://github.com/login/oauth/authorize")!,
                                             tokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!, clients: [],
                                             scopes: [], usesResourceIndicator: false,
                                             deviceAuthorizationEndpoint: URL(string: "https://github.com/login/device/code")!)

    /// The setup steps of one tool's App, named `name`, holding `permissions`.
    static func appSteps(_ name: String, permissions: [Permission]) -> [String] {
        let access = permissions.contains(where: \.write) ? "each with the access shown" : "each **Read-only**"
        func listed(_ section: String) -> String {
            permissions.filter { $0.section == section }.map { "\($0.name)\(permissions.contains(where: \.write) ? " (\($0.write ? "Read and write" : "Read-only"))" : "")" }.joined(separator: ", ")
        }
        return [
            "Each GitHub tool signs in through a **private GitHub App** of its own that your organisation registers; Pion ships none. On GitHub, open the organisation's **Settings › Developer settings › GitHub Apps** and choose **New GitHub App**.",
            "Name it **\(name)**, give the organisation's own website as its **Homepage URL**, and leave **Callback URL** empty, as Pion does not use it. Tick **Enable Device Flow**, keep **Expire user authorization tokens** ticked, and untick **Webhook › Active**.",
            "Under **Permissions**, give only these, \(access), and leave every other at **No access**. Repository permissions: \(listed("Repository")). Organization permissions: \(listed("Organization")).",
            "Under **Where can this GitHub App be installed?** choose **Only on this account**, choose **Create GitHub App**, and copy its **Client ID** here. It needs no client secret.",
            "On the App's page choose **Install App** and install it on the organisation, for **All repositories** or only those Pion should reach.",
            "Choose **Add & Connect**: Pion shows a code and opens GitHub, where you enter it. Sign in as an **organisation owner**, as most of what the tool reads or does needs one; security alerts need an owner or a security manager. If the organisation enforces SAML single sign-on, sign in through it first, or the organisation's resources stay hidden. Then ask an agent to run check-access.",
        ]
    }

    static let setup = appSteps("Pion Detection", permissions: detectionPermissions)
        + ["The audit log and SAML credential authorizations need GitHub Enterprise Cloud; secret scanning and code scanning on private repositories need GitHub's paid Secret Protection and Code Security."]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        AuditLog(), People(), Teams(), SecurityAlerts(), CheckAccess(),
        OrgSettings(), MembersWithout2FA(), AppInstallations(), Webhooks(), RepoSecurity(), DeployKeys(), FineGrainedTokens(),
        ActionsSettings(), CredentialAuthorizations(),
        RemoveMember(), ReinstateMember(), RemoveOutsideCollaborator(), RestoreCollaborator(), CancelInvitation(), BlockUser(), UnblockUser(),
        DemoteOwner(), RestoreOwner(), RemoveFromTeam(), RestoreTeamMembership(), RevokeFineGrainedToken(), DeleteDeployKey(), RestoreDeployKey(),
        DisableWebhook(), EnableWebhook(), RevokeSSOCredential(), DisableActions(), EnableActions(), CancelWorkflowRun(), ReportLeakedToken(),
        ContainmentCheckAccess(), UndoRecords(),
    ]

    /// Paced, as teams and the repository reads ask for each team or repository and GitHub limits requests at once.
    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityAlerts(), simultaneousRequests: 8)

    // MARK: Permissions

    /// One permission of a GitHub App, as the App's registration form names it, and as an installation lists it.
    struct Permission: Sendable, Hashable {
        let section: String
        let name: String
        let key: String
        let write: Bool
        var title: String { "\(section) permissions › \(name): \(write ? "Read and write" : "Read-only")" }
    }

    static let orgAdministrationRead = Permission(section: "Organization", name: "Administration", key: "organization_administration", write: false)
    static let membersRead = Permission(section: "Organization", name: "Members", key: "members", write: false)
    static let orgWebhooksRead = Permission(section: "Organization", name: "Webhooks", key: "organization_hooks", write: false)
    static let tokensRead = Permission(section: "Organization", name: "Personal access tokens", key: "organization_personal_access_tokens", write: false)
    static let tokenRequestsRead = Permission(section: "Organization", name: "Personal access token requests", key: "organization_personal_access_token_requests", write: false)
    static let runnersRead = Permission(section: "Organization", name: "Self-hosted runners", key: "organization_self_hosted_runners", write: false)
    static let repoAdministrationRead = Permission(section: "Repository", name: "Administration", key: "administration", write: false)
    static let metadataRead = Permission(section: "Repository", name: "Metadata", key: "metadata", write: false)
    static let secretScanningRead = Permission(section: "Repository", name: "Secret scanning alerts", key: "secret_scanning_alerts", write: false)
    static let codeScanningRead = Permission(section: "Repository", name: "Code scanning alerts", key: "security_events", write: false)
    static let dependabotRead = Permission(section: "Repository", name: "Dependabot alerts", key: "vulnerability_alerts", write: false)

    /// What Detection's App holds: every permission its reads take, each only to read.
    static let detectionPermissions = [repoAdministrationRead, codeScanningRead, dependabotRead, metadataRead, secretScanningRead,
                                       orgAdministrationRead, membersRead, tokenRequestsRead, tokensRead, runnersRead, orgWebhooksRead]

    // MARK: Requests

    static let host = "api.github.com"
    /// The REST API version Pion's requests are written for.
    static let apiVersion = "2022-11-28"
    static let headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": apiVersion]
    /// The most pages of a hundred one listing reads.
    static let maximumPages = 10

    /// The API the connection reaches, or a refusal before anything is sent: https, api.github.com and no path.
    static func api(_ service: ServiceClient) throws {
        guard service.base.scheme?.lowercased() == "https", service.base.host?.lowercased() == host, service.base.port == nil, service.base.user == nil,
              service.base.path.isEmpty || service.base.path == "/" else {
            throw ServiceError.input("Nothing was sent: this connection does not reach https://\(host), which is all Pion reaches for GitHub. Add the tool again in Settings › Tools.")
        }
    }

    /// The connection's organisation, as GitHub names it: letters, digits and hyphens, not starting with one.
    static func org(_ service: ServiceClient) throws -> String {
        let value = try service.setting("org").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...39).contains(value.count), !value.hasPrefix("-"), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw ServiceError.input("Nothing was sent: this connection's organisation is not a GitHub organisation name, such as kestrel-labs. Correct it in Settings › Tools.")
        }
        return value
    }

    static func orgPath(_ service: ServiceClient, _ rest: String...) throws -> [String] { ["orgs", try org(service)] + rest }

    /// A repository of the organisation, given as its name or as owner/name; another owner's is refused.
    static func repository(_ raw: String, _ service: ServiceClient) throws -> String {
        let org = try org(service)
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count) else { throw ServiceError.input("Nothing was sent: give the repository as its name or as \(org)/name.") }
        if parts.count == 2, parts[0].lowercased() != org.lowercased() {
            throw ServiceError.input("Nothing was sent: \(value) belongs to \(parts[0]), not \(org), the organisation this connection is for. Pion reaches no other owner's repositories.")
        }
        let name = parts[parts.count - 1]
        guard (1...100).contains(name.count), name != ".", name != "..",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw ServiceError.input("Nothing was sent: \"\(name)\" is not a repository name.")
        }
        return name
    }

    /// A path under one of the organisation's repositories, with the organisation as its owner.
    static func repoPath(_ name: String, _ service: ServiceClient, _ rest: String...) throws -> [String] {
        ["repos", try org(service), try repository(name, service)] + rest
    }

    /// A GitHub login: letters, digits and hyphens, not starting with one, up to 39.
    static func login(_ raw: String, _ what: String = "the user's login") throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "", options: .anchored)
        guard (1...39).contains(value.count), !value.hasPrefix("-"), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw ServiceError.input("Nothing was sent: \"\(raw)\" is not \(what), such as mallory.")
        }
        return value
    }

    /// A team's slug, as GitHub gives it.
    static func slug(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(value.count), value != ".", value != "..",
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw ServiceError.input("Nothing was sent: \"\(raw)\" is not a team's slug, such as platform-admins.")
        }
        return value
    }

    /// One request to api.github.com, as GitHub's REST API version Pion is written for. Statuses in `returning` come back.
    static func send(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET", body: Data? = nil,
                     returning: Set<Int> = []) async throws -> (data: Data, response: HTTPURLResponse) {
        try api(service)
        return try await service.exchange(path, query: query, method: method, body: body, headers: headers, returning: returning)
    }

    static func get<Answer: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], as answer: Answer.Type = Answer.self) async throws -> Answer {
        try decode(try await send(service, path, query: query).data)
    }

    static func decode<Answer: Decodable>(_ data: Data, as answer: Answer.Type = Answer.self) throws -> Answer {
        do { return try JSONDecoder().decode(Answer.self, from: data) } catch { throw ServiceError.unreadable }
    }

    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    /// A listing read page after page of `size`, up to `pages`, its items under `key` for a listing GitHub wraps in an
    /// object, such as installations; `more` when GitHub said more followed where it stopped.
    struct Listing<Item> {
        var items: [Item] = []
        var more = false
    }

    static func list<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], key: String? = nil,
                                      size: Int = 100, pages: Int = maximumPages, as item: Item.Type = Item.self) async throws -> Listing<Item> {
        var found = Listing<Item>()
        for page in 1...max(1, pages) {
            var asked = query
            asked["per_page"] = String(size)
            asked["page"] = String(page)
            let answer = try await send(service, path, query: asked)
            var data = answer.data
            if let key {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = object[key] as? [Any] else { throw ServiceError.unreadable }
                data = try JSONSerialization.data(withJSONObject: items)
            }
            let items: [Item] = try decode(data)
            found.items += items
            let next = answer.response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") ?? (items.count >= size)
            guard next, items.count >= size else { return found }
            if page == pages { found.more = true }
        }
        return found
    }

    static func plural(_ count: Int, _ word: String) -> String {
        count == 1 ? "1 \(word)" : word.hasSuffix("y") ? "\(count) \(word.dropLast())ies" : "\(count) \(word)s"
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func host(of url: String?) -> String {
        url.flatMap { URLComponents(string: $0)?.host } ?? "an address not given"
    }

    // MARK: Refusals

    static let owner = "an organisation owner"
    static let ownerOrSecurityManager = "an organisation owner or security manager"
    static let member = "a member of the organisation"

    /// What one thing a tool reads or does needs: the App's permission, the signed-in person's role, and, for what
    /// GitHub offers only on some plans, which.
    struct Need: Sendable {
        let title: String
        let permission: Permission
        let role: String
        var plan: String? = nil
    }

    static let auditNeed = Need(title: "The audit log", permission: orgAdministrationRead, role: owner, plan: "the audit log API needs GitHub Enterprise Cloud")
    static let membersNeed = Need(title: "Members and outside collaborators", permission: membersRead, role: member)
    static let teamsNeed = Need(title: "Teams", permission: membersRead, role: member)
    static let twoFactorNeed = Need(title: "Two-factor authentication filters", permission: membersRead, role: owner)
    static let orgNeed = Need(title: "The organisation's settings", permission: orgAdministrationRead, role: owner)
    static let codeSecurityNeed = Need(title: "Code security configurations", permission: orgAdministrationRead, role: ownerOrSecurityManager)
    static let installationsNeed = Need(title: "GitHub App installations", permission: orgAdministrationRead, role: owner)
    static let hooksNeed = Need(title: "Organisation webhooks", permission: orgWebhooksRead, role: owner)
    static let reposNeed = Need(title: "Repositories", permission: metadataRead, role: member)
    static let rulesNeed = Need(title: "Branch rules", permission: metadataRead, role: member)
    static let deployKeysNeed = Need(title: "Deploy keys", permission: repoAdministrationRead, role: "an organisation owner or the repository's admin")
    static let tokensNeed = Need(title: "Fine-grained personal access tokens", permission: tokensRead, role: owner)
    static let tokenRequestsNeed = Need(title: "Fine-grained token requests", permission: tokenRequestsRead, role: owner)
    static let actionsNeed = Need(title: "Actions permissions", permission: orgAdministrationRead, role: owner)
    static let runnersNeed = Need(title: "Self-hosted runners", permission: runnersRead, role: owner)
    static let ssoNeed = Need(title: "SAML credential authorizations", permission: orgAdministrationRead, role: owner,
                              plan: "credential authorizations exist only on GitHub Enterprise Cloud with SAML single sign-on")

    /// What to change when a request was refused; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        let said: String
        switch error {
        case ServiceError.rejected:
            return "GitHub did not accept the sign-in: it was revoked, went unused until its refresh token expired, or the App was deleted, suspended or uninstalled. Connect the tool again in Settings › Tools."
        case ServiceError.notFound:
            guard let plan = need.plan else { return nil }
            return "\(plan); otherwise the App is not installed on the organisation, or the signed-in person is not \(need.role)."
        case ServiceError.forbidden(let reason): said = reason?.lowercased() ?? ""
        case ServiceError.refused(let reason) where reason.lowercased().contains("owner") || reason.lowercased().contains("admin"):
            return "only \(need.role) may do this, and the signed-in person is not one. Connect the tool again signed in as \(need.role)."
        default: return nil
        }
        if said.contains("rate limit") { return "GitHub is rate limiting this sign-in, which has 5,000 requests an hour. Wait for the limit to reset, and read less at once." }
        if said.contains("saml") || said.contains("single sign-on") {
            return "the organisation enforces SAML single sign-on, and this sign-in is not authorised for it. Sign in to GitHub through the organisation's identity provider, then connect the tool again in Settings › Tools."
        }
        if said.contains("not accessible by integration") {
            return "the GitHub App lacks \(need.permission.title). Add it under the App's **Permissions & events**, then approve the new permissions on the organisation's installation (Settings › GitHub Apps › Configure)."
        }
        if let plan = need.plan, said.contains("enterprise") || said.contains("plan") { return "\(plan)." }
        return "the signed-in person may not do this: it needs \(need.role), and the App needs \(need.permission.title). Check both, and connect the tool again signed in as \(need.role) if need be."
    }

    /// A request, with a refusal said as what to change.
    static func read<Result>(_ need: Need, _ body: () async throws -> Result) async throws -> Result {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("GitHub refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows which parts the sign-in reaches.")
        }
    }

    /// One part of the organisation read, or why it could not be.
    static func attempt<Result>(_ need: Need, _ body: () async throws -> Result) async -> (value: Result?, failure: String?) {
        do { return (try await read(need, body), nil) } catch { return (nil, "\(need.title) could not be read: \(error.localizedDescription)") }
    }

    /// One thing tried for check-access: ✓, or ✗ with what to change.
    static func probe(_ need: Need, _ body: () async throws -> Void) async -> String {
        do { try await body(); return "✓ \(need.title)" }
        catch { return "✗ \(need.title): " + (fix(for: error, need) ?? error.localizedDescription) }
    }

    // MARK: Who signed in

    struct Person: Codable, Sendable { let login: String; let id: Int? }
    struct Membership: Codable, Sendable { let state: String?; let role: String?; let user: Person? }

    /// The signed-in person, and their role in the organisation when it could be read.
    static func signer(_ service: ServiceClient) async throws -> (login: String, role: String?) {
        let me: Person = try await get(service, ["user"])
        let membership = try? await get(service, try orgPath(service, "memberships", try login(me.login)), as: Membership.self)
        return (me.login, membership?.state == "active" ? membership?.role : nil)
    }

    /// The installation of this tool's App on the organisation, from those the signed-in person can reach.
    struct Installation: Decodable, Sendable {
        struct Account: Decodable, Sendable { let login: String? }
        let id: Int?, app_slug: String?, account: Account?, repository_selection: String?, permissions: [String: String]?, suspended_at: String?
        let created_at: String?
    }

    /// Says how the App is installed on the organisation, which of `wanted` it lacks, and what it holds besides.
    static func installationLines(_ service: ServiceClient, wanted: [Permission]) async -> [String] {
        let org = (try? org(service))?.lowercased()
        let found: Listing<Installation>
        do { found = try await list(service, ["user", "installations"], key: "installations", pages: 3) }
        catch { return ["· The App's installation could not be read (\(error.localizedDescription)); its permissions were not compared."] }
        guard let installation = found.items.first(where: { $0.account?.login?.lowercased() == org }) else {
            return ["✗ The App is not installed on the organisation, or the signed-in person cannot see its installation: on the App's page choose Install App and install it on the organisation."]
        }
        let held = installation.permissions ?? [:]
        var lines = ["· The App \(installation.app_slug ?? "?") is installed on the organisation for \(installation.repository_selection == "all" ? "all repositories" : "selected repositories")"
                     + (installation.suspended_at.map { ", ⚠ suspended since \($0)" } ?? "")
                     + ", with: \(held.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))."]
        let missing = wanted.filter { want in
            guard let level = held[want.key] else { return true }
            return want.write && level == "read"
        }
        lines.append(missing.isEmpty ? "✓ The installation holds every permission this tool uses."
                     : "✗ The installation lacks: \(missing.map(\.title).joined(separator: "; ")). Add them to the App, then approve them on the installation (Settings › GitHub Apps › Configure).")
        let beyond = held.filter { key, level in
            guard let want = wanted.first(where: { $0.key == key }) else { return true }
            return !want.write && level != "read"
        }
        if !beyond.isEmpty {
            lines.append("⚠ The installation holds more than this tool uses: \(beyond.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")). Take it away in the App's Permissions & events.")
        }
        return lines
    }
}

// MARK: - Investigation reads

extension GitHub {
    struct AuditLog: ServiceOperation {
        struct Input: Decodable, Sendable { let phrase: String?, limit: Int? }
        static let name = "audit-log"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The organisation's audit log, newest first, filtered by a search phrase such as actor:mallory action:repo.destroy created:>=2026-11-13. Needs GitHub Enterprise Cloud and an owner."
        static let input = JSONSchema.object([
            "phrase": .string("An audit log search phrase, such as actor:mallory action:repo.destroy created:>=2026-11-13."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 50
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 events.") }
            var query: [String: String?] = ["include": "all", "order": "desc", "per_page": String(limit)]
            if let phrase = input.phrase?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty {
                guard phrase.count <= 300, !phrase.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw ServiceError.input("Give the search phrase on one line.")
                }
                query["phrase"] = phrase
            }
            struct Location: Codable { let country_code: String? }
            struct Event: Decodable {
                enum Keys: String, CodingKey { case timestamp = "@timestamp", action, actor, actor_ip, user, repo, actor_location }
                let time: String?, action: String?, actor: String?, ip: String?, user: String?, repo: String?, country: String?
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: Keys.self)
                    let stamp = try? container.decodeIfPresent(Double.self, forKey: .timestamp)
                    time = stamp.flatMap { $0 }.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1_000)) }
                    action = try container.decodeIfPresent(String.self, forKey: .action)
                    actor = try container.decodeIfPresent(String.self, forKey: .actor)
                    ip = try container.decodeIfPresent(String.self, forKey: .actor_ip)
                    user = try container.decodeIfPresent(String.self, forKey: .user)
                    repo = try container.decodeIfPresent(String.self, forKey: .repo)
                    country = try container.decodeIfPresent(Location.self, forKey: .actor_location)?.country_code
                }
            }
            struct Kept: Encodable { let time: String?, action: String?, actor: String?, ip: String?, user: String?, repo: String?, country: String? }
            struct Events: Encodable { let events: [Kept] }
            let path = try GitHub.orgPath(service, "audit-log")
            let events = try await GitHub.read(GitHub.auditNeed) { try await GitHub.get(service, path, query: query, as: [Event].self) }.map {
                Kept(time: $0.time, action: $0.action, actor: $0.actor, ip: $0.ip, user: $0.user, repo: $0.repo, country: $0.country)
            }
            let text = events.isEmpty ? "No audit log events match." : events.prefix(30).map { event in
                var line = "\(event.time ?? "?") \(event.action ?? "?")"
                if let actor = event.actor { line += " by \(actor)" }
                if let ip = event.ip { line += " from \(ip)" }
                if let country = event.country { line += " (\(country))" }
                if let repo = event.repo { line += " on \(repo)" }
                if let user = event.user { line += " affecting \(user)" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Events(events: events))
        }
    }

    struct People: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "people"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The organisation's members, which of them are owners, and its outside collaborators."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Person: Codable { let login: String; let site_admin: Bool? }
            struct People: Encodable { let members: [Person]; let owners: [String]; let outsideCollaborators: [Person]; let complete: Bool }
            let (members, owners, outside) = try await GitHub.read(GitHub.membersNeed) {
                (try await GitHub.list(service, try GitHub.orgPath(service, "members"), as: Person.self),
                 // Owners can do anything in the organisation, so an audit of who holds what starts with them.
                 try await GitHub.list(service, try GitHub.orgPath(service, "members"), query: ["role": "admin"], as: Person.self),
                 try await GitHub.list(service, try GitHub.orgPath(service, "outside_collaborators"), as: Person.self))
            }
            let ownerLogins = owners.items.map(\.login)
            var text = "\(GitHub.plural(members.items.count, "member")): \(members.items.map(\.login).joined(separator: ", "))."
                + " \(GitHub.plural(ownerLogins.count, "owner")): \(ownerLogins.isEmpty ? "none listed" : ownerLogins.joined(separator: ", "))."
                + (outside.items.isEmpty ? " No outside collaborators." : " \(GitHub.plural(outside.items.count, "outside collaborator")): \(outside.items.map(\.login).joined(separator: ", ")).")
            let complete = !(members.more || owners.more || outside.more)
            if !complete { text += "\nStopped after \(GitHub.maximumPages) pages of a hundred: there are more than listed." }
            return try ServiceResult(text: text, structured: People(members: members.items, owners: ownerLogins, outsideCollaborators: outside.items, complete: complete))
        }
    }

    /// The organisation's three feeds of security alerts, each across all its repositories, newest first.
    enum AlertKind: String, CaseIterable {
        case secret, code, dependency
        var path: [String] {
            switch self {
            case .secret: ["secret-scanning", "alerts"]
            case .code: ["code-scanning", "alerts"]
            case .dependency: ["dependabot", "alerts"]
            }
        }
        var title: String {
            switch self {
            case .secret: "Secret scanning"
            case .code: "Code scanning"
            case .dependency: "Dependabot"
            }
        }
        var need: Need {
            switch self {
            case .secret: Need(title: "Secret scanning alerts", permission: secretScanningRead, role: ownerOrSecurityManager)
            case .code: Need(title: "Code scanning alerts", permission: codeScanningRead, role: ownerOrSecurityManager)
            case .dependency: Need(title: "Dependabot alerts", permission: dependabotRead, role: ownerOrSecurityManager)
            }
        }
    }

    struct SecurityAlert: Codable {
        struct Repository: Codable { let full_name: String? }
        struct Rule: Codable { let security_severity_level: String?; let description: String? }
        struct Advisory: Codable { let severity: String?; let summary: String? }
        struct Package: Codable { let name: String? }
        struct Dependency: Codable { let package: Package? }
        let number: Int?, created_at: String?, html_url: String?, repository: Repository?
        let secret_type_display_name: String?, validity: String?
        let rule: Rule?
        let security_advisory: Advisory?, dependency: Dependency?
    }

    /// The open alerts of one kind, newest first: a page of a hundred, which reaches back far enough between checks.
    static func openAlerts(_ kind: AlertKind, severity: String? = nil, on service: ServiceClient) async throws -> [SecurityAlert] {
        let path = try orgPath(service) + kind.path
        return try await read(kind.need) {
            try await get(service, path, query: ["state": "open", "severity": severity, "sort": "created", "direction": "desc", "per_page": "100"],
                          as: [SecurityAlert].self)
        }
    }

    /// Reads each feed on its own, so one the organisation has not turned on, or the person cannot read, leaves the
    /// others; only when none answers does it fail.
    static func eachFeed<Item>(_ feeds: [(AlertKind, () async throws -> [Item])]) async throws -> (items: [Item], failures: [String]) {
        var items: [Item] = [], failures: [String] = [], first: Error?
        for (kind, read) in feeds {
            do { items += try await read() } catch {
                first = first ?? error
                failures.append("\(kind.title) could not be read: \(error.localizedDescription)")
            }
        }
        if failures.count == feeds.count, let first { throw first }
        return (items, failures)
    }

    struct SecurityAlerts: ServiceOperation {
        struct Input: Decodable, Sendable { let kind: String?, since: String? }
        static let name = "security-alerts"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Open secret scanning, code scanning and Dependabot alerts across the organisation's repositories, newest first, by kind and time, with the repository, the severity and whether a secret is still valid."
        static let input = JSONSchema.object([
            "kind": .string("Only this kind: secrets found in code, code scanning results or vulnerable dependencies. All three when left out.",
                            oneOf: ["secret", "code", "dependency"]),
            "since": .string("The earliest time each was raised, in ISO 8601."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let kinds = try input.kind.map { [AlertKind(rawValue: try ServiceInput.oneOf($0, ["secret", "code", "dependency"], "kind"))!] }
                ?? AlertKind.allCases
            let since = try input.since.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantPast }
            let (found, failures) = try await GitHub.eachFeed(kinds.map { kind in
                (kind, { try await GitHub.openAlerts(kind, on: service).map { (kind, $0) } })
            })
            let alerts = found.compactMap { kind, alert -> (AlertKind, SecurityAlert, Date)? in
                guard let time = ServiceAlert.time(alert.created_at), time >= since ?? .distantPast else { return nil }
                return (kind, alert, time)
            }.sorted { $0.2 > $1.2 }
            let lines = alerts.prefix(50).map { kind, alert, _ in
                var line = "\(alert.created_at ?? "?") \(kind.title): "
                switch kind {
                case .secret: line += "\(alert.secret_type_display_name ?? "secret")\(alert.validity.map { " (\($0))" } ?? "")"
                case .code: line += "\(alert.rule?.security_severity_level ?? "?") \(alert.rule?.description ?? "finding")"
                case .dependency:
                    line += "\(alert.security_advisory?.severity ?? "?") \(alert.security_advisory?.summary ?? "advisory") in \(alert.dependency?.package?.name ?? "a dependency")"
                }
                return line + " in \(alert.repository?.full_name ?? "?")"
            }
            let text = (lines.isEmpty ? ["No open alerts match."] : lines) + failures
            struct Alerts: Encodable { let alerts: [SecurityAlert] }
            return try ServiceResult(text: text.joined(separator: "\n"), structured: Alerts(alerts: alerts.map(\.1)))
        }
    }

    /// New open alerts: every leaked secret, and code scanning and Dependabot alerts that are high or critical.
    struct NewSecurityAlerts: ServiceTrigger {
        var tool: String { SecurityAlerts.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            let (found, _) = try await GitHub.eachFeed([
                (AlertKind.secret, { try await GitHub.openAlerts(.secret, on: service) }),
                (AlertKind.code, {
                    try await GitHub.openAlerts(.code, severity: "critical", on: service) + GitHub.openAlerts(.code, severity: "high", on: service)
                }),
                (AlertKind.dependency, { try await GitHub.openAlerts(.dependency, severity: "critical,high", on: service) }),
            ])
            var seen = Set<String>()
            return found.compactMap { alert -> ServiceAlert? in
                guard let id = alert.html_url, let time = ServiceAlert.time(alert.created_at), time >= since, seen.insert(id).inserted else { return nil }
                return ServiceAlert(id: id, time: time)
            }.sorted { $0.time > $1.time }
        }
    }

    /// Teams and their members: a team carries access to repositories, so who is in which team says what a member reaches.
    struct Teams: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "teams"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The organisation's teams, with their members and the team each sits within."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Parent: Codable { let slug: String? }
            struct Team: Codable { let slug: String; let name: String?; let privacy: String?; let parent: Parent? }
            struct Member: Codable { let login: String }
            let teams = try await GitHub.read(GitHub.teamsNeed) { try await GitHub.list(service, try GitHub.orgPath(service, "teams"), as: Team.self) }
            let members = try await GitHub.read(GitHub.teamsNeed) {
                try await withThrowingTaskGroup(of: (String, [String]).self) { group in
                    for team in teams.items {
                        let path = try GitHub.orgPath(service, "teams", try GitHub.slug(team.slug), "members")
                        group.addTask { (team.slug, try await GitHub.list(service, path, pages: 3, as: Member.self).items.map(\.login)) }
                    }
                    return try await group.reduce(into: [String: [String]]()) { $0[$1.0] = $1.1 }
                }
            }
            let names = Dictionary(teams.items.map { ($0.slug, $0.name ?? $0.slug) }, uniquingKeysWith: { first, _ in first })
            var text = teams.items.isEmpty ? "The organisation has no teams." : teams.items.map { team in
                let within = team.parent?.slug.map { ", within \(names[$0] ?? $0)" } ?? ""
                let secret = team.privacy == "secret" ? ", secret" : ""
                let held = members[team.slug] ?? []
                return "\(team.name ?? team.slug)\(within)\(secret) (\(held.count)): \(held.isEmpty ? "no members" : held.joined(separator: ", "))"
            }.joined(separator: "\n")
            if teams.more { text += "\nStopped after \(GitHub.maximumPages) pages of teams: there are more than listed." }
            struct Kept: Encodable { let team: Team; let members: [String] }
            return try ServiceResult(text: text, structured: ["teams": teams.items.map { Kept(team: $0, members: members[$0.slug] ?? []) }])
        }
    }
}

// MARK: - Audit reads

extension GitHub {
    struct OrgSettings: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "org-settings"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The organisation's security settings: whether two-factor authentication is required, the base repository permission, what members may create, fork, delete and invite, web commit sign-off, deploy keys, and the code security configurations that set up secret scanning and push protection. GitHub shows most of these only to an owner, and it says which were hidden."
        static let input = JSONSchema.object([:])

        static let fields: [(key: String, title: String, risky: @Sendable (CellValue) -> Bool)] = [
            ("two_factor_requirement_enabled", "Two-factor authentication required", { if case .flag(false) = $0 { true } else { false } }),
            ("default_repository_permission", "Base repository permission for members", { ["write", "admin"].contains($0.shown) }),
            ("members_can_create_repositories", "Members can create repositories", { _ in false }),
            ("members_can_create_public_repositories", "Members can create public repositories", { if case .flag(true) = $0 { true } else { false } }),
            ("members_can_create_private_repositories", "Members can create private repositories", { _ in false }),
            ("members_can_create_internal_repositories", "Members can create internal repositories", { _ in false }),
            ("members_can_fork_private_repositories", "Members can fork private repositories", { if case .flag(true) = $0 { true } else { false } }),
            ("members_can_change_repo_visibility", "Members can change repository visibility", { if case .flag(true) = $0 { true } else { false } }),
            ("members_can_delete_repositories", "Members can delete repositories", { if case .flag(true) = $0 { true } else { false } }),
            ("members_can_invite_outside_collaborators", "Members can invite outside collaborators", { if case .flag(true) = $0 { true } else { false } }),
            ("members_can_create_public_pages", "Members can publish public Pages", { _ in false }),
            ("web_commit_signoff_required", "Web commit sign-off required", { _ in false }),
            ("deploy_keys_enabled_for_repositories", "Deploy keys allowed in repositories", { _ in false }),
        ]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let org = try GitHub.org(service)
            let settings = try await GitHub.read(GitHub.orgNeed) { try await GitHub.get(service, try GitHub.orgPath(service), as: [String: CellValue].self) }
            var lines = ["Organisation \(org)\(settings["name"].map { $0.shown.isEmpty ? "" : " (\($0.shown))" } ?? ""):"]
            var kept: [String: String] = [:], hidden: [String] = []
            for field in Self.fields {
                guard let value = settings[field.key], !(value.shown.isEmpty) else { hidden.append(field.title); continue }
                kept[field.key] = value.shown
                lines.append("\(field.risky(value) ? "⚠" : "·") \(field.title): \(value.shown)")
            }
            if !hidden.isEmpty {
                lines.append("Hidden: \(hidden.joined(separator: "; ")). GitHub gives these only to an organisation owner, so the signed-in person is likely not one; connect the tool again as an owner to read them.")
            }
            struct Configuration: Codable {
                let id: Int?, name: String?, target_type: String?, secret_scanning: String?, secret_scanning_push_protection: String?
                let advanced_security: String?, dependabot_alerts: String?, code_scanning_default_setup: String?, enforcement: String?
            }
            struct Default: Codable { let default_for_new_repos: String?; let configuration: Configuration? }
            let configurations = await GitHub.attempt(GitHub.codeSecurityNeed) {
                try await GitHub.list(service, try GitHub.orgPath(service, "code-security", "configurations"), pages: 2, as: Configuration.self).items
            }
            if let found = configurations.value {
                lines.append(found.isEmpty ? "⚠ No code security configurations: secret scanning and push protection are not set up for the organisation's repositories through one."
                             : "Code security configurations:\n" + found.map { item in
                                 "  \(item.secret_scanning == "enabled" && item.secret_scanning_push_protection == "enabled" ? "·" : "⚠") \(item.name ?? "?") (\(item.target_type ?? "?")): secret scanning \(item.secret_scanning ?? "not given"), push protection \(item.secret_scanning_push_protection ?? "not given"), Dependabot alerts \(item.dependabot_alerts ?? "not given"), code scanning \(item.code_scanning_default_setup ?? "not given")\(item.enforcement == "enforced" ? ", enforced" : "")"
                             }.joined(separator: "\n"))
            } else if let failure = configurations.failure { lines.append(failure) }
            let defaults = await GitHub.attempt(GitHub.codeSecurityNeed) {
                try await GitHub.get(service, try GitHub.orgPath(service, "code-security", "configurations", "defaults"), as: [Default].self)
            }
            if let found = defaults.value {
                lines.append(found.isEmpty ? "⚠ No configuration is applied to new repositories by default."
                             : "Applied to new repositories: " + found.map { "\($0.configuration?.name ?? "?") for \($0.default_for_new_repos ?? "?")" }.joined(separator: "; ") + ".")
            } else if let failure = defaults.failure { lines.append(failure) }
            struct Kept: Encodable { let settings: [String: String]; let hidden: [String]; let configurations: [Configuration]?; let defaults: [Default]? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(settings: kept, hidden: hidden, configurations: configurations.value, defaults: defaults.value))
        }
    }

    struct MembersWithout2FA: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "members-without-2fa"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Members and outside collaborators without two-factor authentication, and those using a method GitHub counts as insecure, such as SMS. GitHub filters these only for an organisation owner."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            // GitHub filters only for an owner; a list read by anyone else must not pass for one of people without 2FA.
            if let signer = try? await GitHub.signer(service), let role = signer.role, role != "admin" {
                throw ServiceError.input("Nothing was read: \(signer.login) is a \(role) of the organisation, and GitHub filters members by two-factor authentication only for an owner. Connect the tool again signed in as an owner.")
            }
            var lines: [String] = [], found: [String: [String]] = [:], failures: [String] = []
            for (kind, title) in [("members", "Members"), ("outside_collaborators", "Outside collaborators")] {
                for (filter, said) in [("2fa_disabled", "without two-factor authentication"), ("2fa_insecure", "with an insecure two-factor method")] {
                    let read = await GitHub.attempt(GitHub.twoFactorNeed) {
                        try await GitHub.list(service, try GitHub.orgPath(service, kind), query: ["filter": filter], as: Person.self)
                    }
                    guard let listing = read.value else { failures.append("\(title) \(said): \(read.failure ?? "not read")"); continue }
                    let logins = listing.items.map(\.login)
                    found["\(kind).\(filter)"] = logins
                    lines.append("\(logins.isEmpty ? "·" : "⚠") \(title) \(said): \(logins.isEmpty ? "none" : "\(logins.count): \(logins.joined(separator: ", "))")\(listing.more ? " (stopped after \(GitHub.maximumPages) pages; there are more)" : "")")
                }
            }
            if lines.isEmpty, let first = failures.first { throw ServiceError.input(first) }
            struct Kept: Encodable { let found: [String: [String]]; let failures: [String] }
            return try ServiceResult(text: (lines + failures).joined(separator: "\n"), structured: Kept(found: found, failures: failures))
        }
    }

    struct AppInstallations: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "app-installations"
        static let jobs: Set<ToolJob> = [.audit]
        static let suspendNote = "GitHub's API cannot suspend or remove another App's installation: an owner does it in the organisation's Settings › GitHub Apps, choosing Configure on the App, then Suspend or Uninstall."
        static let summary = "The GitHub Apps installed on the organisation, riskiest first: those that can write to administration, contents, members, workflows or secrets, across all repositories, with whether each is suspended. \(suspendNote)"
        static let input = JSONSchema.object([:])

        /// Permissions whose write access reaches code, people or the organisation's settings.
        static let weighty: Set<String> = ["administration", "contents", "members", "organization_administration", "workflows", "secrets",
                                           "organization_secrets", "actions", "organization_hooks", "repository_hooks", "organization_user_blocking",
                                           "organization_personal_access_tokens", "environments", "organization_self_hosted_runners"]

        static func risk(_ installation: Installation) -> (score: Int, reasons: [String]) {
            let writes = (installation.permissions ?? [:]).filter { $0.value == "write" || $0.value == "admin" }.keys.sorted()
            let heavy = writes.filter(weighty.contains)
            var reasons = heavy.isEmpty ? [] : ["writes \(heavy.joined(separator: ", "))"]
            if installation.repository_selection == "all" { reasons.append("all repositories") }
            return (heavy.count * 3 + writes.count + (installation.repository_selection == "all" ? 2 : 0), reasons)
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let found = try await GitHub.read(GitHub.installationsNeed) {
                try await GitHub.list(service, try GitHub.orgPath(service, "installations"), key: "installations", as: Installation.self)
            }
            let ranked = found.items.map { ($0, Self.risk($0)) }.sorted { $0.1.score > $1.1.score }
            var lines = ranked.isEmpty ? ["No GitHub Apps are installed on the organisation."] : ranked.map { installation, risk in
                let permissions = (installation.permissions ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                return "\(risk.reasons.isEmpty ? "·" : "⚠") \(installation.app_slug ?? "?") [installation \(installation.id.map(String.init) ?? "?")]: "
                    + "\(installation.repository_selection == "all" ? "all repositories" : "selected repositories")"
                    + (installation.suspended_at.map { ", suspended since \($0)" } ?? "")
                    + (risk.reasons.isEmpty ? "" : " — \(risk.reasons.joined(separator: "; "))")
                    + ". Permissions: \(permissions.isEmpty ? "none" : permissions)."
            }
            if found.more { lines.append("Stopped after \(GitHub.maximumPages) pages: there are more installations.") }
            lines.append(Self.suspendNote)
            struct Kept: Encodable { let id: Int?; let app: String?; let repositories: String?; let suspendedAt: String?; let permissions: [String: String]; let risk: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["installations": ranked.map {
                Kept(id: $0.0.id, app: $0.0.app_slug, repositories: $0.0.repository_selection, suspendedAt: $0.0.suspended_at, permissions: $0.0.permissions ?? [:], risk: $0.1.reasons)
            }])
        }
    }

    struct Hook: Decodable, Sendable {
        struct Config: Decodable, Sendable {
            let url: String?, content_type: String?, insecure_ssl: CellValue?, secret: String?
        }
        let id: Int, name: String?, active: Bool?, events: [String]?, config: Config?, created_at: String?, updated_at: String?

        var problems: [String] {
            var found: [String] = []
            if config?.insecure_ssl.map({ $0.shown == "1" }) == true { found.append("TLS certificates not verified") }
            if config?.url?.lowercased().hasPrefix("http://") == true { found.append("sent over plain HTTP") }
            if config?.secret == nil { found.append("no secret to sign deliveries") }
            if events?.contains("*") == true { found.append("every event") }
            return found
        }
        var line: String {
            "\(problems.isEmpty ? "·" : "⚠") Hook \(id) to \(GitHub.host(of: config?.url)), \(active == false ? "inactive" : "active"), "
                + "events: \((events ?? []).joined(separator: ", "))"
                + (problems.isEmpty ? "" : " — \(problems.joined(separator: "; "))")
        }
    }

    struct Webhooks: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "webhooks"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Where the organisation's webhooks send its events: each hook's host, events and whether it is active, flagging those that skip TLS verification, use plain HTTP, have no secret or send every event. GitHub does not list hooks that OAuth apps made."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let hooks = try await GitHub.read(GitHub.hooksNeed) { try await GitHub.list(service, try GitHub.orgPath(service, "hooks"), as: Hook.self) }
            let ranked = hooks.items.sorted { $0.problems.count > $1.problems.count }
            var lines = ranked.isEmpty ? ["The organisation has no webhooks this sign-in can see."] : ranked.map(\.line)
            if hooks.more { lines.append("Stopped after \(GitHub.maximumPages) pages: there are more hooks.") }
            lines.append("Hooks that OAuth apps made are not listed to anyone through the API.")
            struct Kept: Encodable { let id: Int; let host: String; let active: Bool?; let events: [String]; let problems: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["hooks": ranked.map {
                Kept(id: $0.id, host: GitHub.host(of: $0.config?.url), active: $0.active, events: $0.events ?? [], problems: $0.problems)
            }])
        }
    }

    struct Repository: Decodable, Sendable {
        struct Status: Decodable, Sendable { let status: String? }
        struct Security: Decodable, Sendable {
            let advanced_security: Status?, secret_scanning: Status?, secret_scanning_push_protection: Status?, dependabot_security_updates: Status?
        }
        let name: String, full_name: String?, `private`: Bool?, visibility: String?, archived: Bool?, default_branch: String?, pushed_at: String?
        let security_and_analysis: Security?

        var isPrivate: Bool { `private` == true || visibility == "internal" }
        var secretScanning: String? { security_and_analysis?.secret_scanning?.status }
        var pushProtection: String? { security_and_analysis?.secret_scanning_push_protection?.status }
    }

    /// The organisation's repositories, most recently pushed first.
    static func repositories(_ service: ServiceClient, pages: Int = maximumPages) async throws -> Listing<Repository> {
        try await read(reposNeed) { try await list(service, try orgPath(service, "repos"), query: ["type": "all", "sort": "pushed", "direction": "desc"], pages: pages) }
    }

    /// `body` run for each of `items` at once, each answer or failure kept in order.
    static func each<Item: Sendable, Answer: Sendable>(_ items: [Item], _ body: @escaping @Sendable (Item) async throws -> Answer) async -> [(Item, Result<Answer, Error>)] {
        await withTaskGroup(of: (Int, Result<Answer, Error>).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    do { return (index, .success(try await body(item))) } catch { return (index, .failure(error)) }
                }
            }
            var answers: [Int: Result<Answer, Error>] = [:]
            for await (index, answer) in group { answers[index] = answer }
            return items.indices.map { (items[$0], answers[$0]!) }
        }
    }

    struct RepoSecurity: ServiceOperation {
        struct Input: Decodable, Sendable { let rules: Int? }
        static let name = "repo-security"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Each repository's secret scanning and push protection, led by private and internal repositories without them, and the rules on the default branch of the most recently pushed repositories, led by those with none. Rules come from rulesets; classic branch protection is not read. It reads up to 1,000 repositories and says when it stopped."
        static let input = JSONSchema.object([
            "rules": .integer("How many repositories' default branch rules to read, most recently pushed first (30 when left out; 0 reads none).", minimum: 0, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let cap = input.rules ?? 30
            guard (0...100).contains(cap) else { throw ServiceError.input("Read the rules of between 0 and 100 repositories.") }
            let repos = try await GitHub.repositories(service)
            let live = repos.items.filter { $0.archived != true }
            var lines = ["\(GitHub.plural(repos.items.count, "repository")) read, \(live.count) not archived\(repos.more ? "; stopped after \(GitHub.maximumPages * 100), there are more" : "")."]
            let shown = live.filter { $0.security_and_analysis != nil }
            if shown.isEmpty, !live.isEmpty {
                lines.append("GitHub hid every repository's security settings: it shows them only to an organisation owner, a security manager or the repository's admin.")
            } else {
                let gaps = shown.filter { $0.secretScanning != "enabled" || $0.pushProtection != "enabled" }
                    .sorted { ($0.isPrivate ? 0 : 1, $0.name) < ($1.isPrivate ? 0 : 1, $1.name) }
                lines.append(gaps.isEmpty ? "· Every repository read has secret scanning and push protection on."
                             : "⚠ \(GitHub.plural(gaps.count, "repository")) without secret scanning or push protection, private and internal first:\n" + gaps.prefix(40).map {
                                 "  \($0.name) (\($0.visibility ?? ($0.private == true ? "private" : "public"))): secret scanning \($0.secretScanning ?? "not given"), push protection \($0.pushProtection ?? "not given")"
                             }.joined(separator: "\n") + (gaps.count > 40 ? "\n  … \(gaps.count - 40) more in the structured result." : ""))
                if shown.count < live.count { lines.append("\(live.count - shown.count) repositories' security settings were hidden from this sign-in.") }
            }
            struct Rule: Decodable, Sendable { let type: String? }
            let checked = Array(live.filter { $0.default_branch != nil }.prefix(cap))
            let answers = await GitHub.each(checked) { repo -> [String] in
                let path = try GitHub.repoPath(repo.name, service, "rules", "branches", repo.default_branch ?? "")
                return try await GitHub.read(GitHub.rulesNeed) { try await GitHub.get(service, path, as: [Rule].self) }.compactMap(\.type)
            }
            var rules: [String: [String]] = [:], failed: [String] = []
            for (repo, answer) in answers {
                switch answer {
                case .success(let types): rules[repo.name] = Array(Set(types)).sorted()
                case .failure(let error): failed.append("\(repo.name): \(error.localizedDescription)")
                }
            }
            if cap > 0 {
                let bare = checked.filter { rules[$0.name]?.isEmpty == true }.map { "\($0.name) (\($0.default_branch ?? "?"))" }
                lines.append(bare.isEmpty ? "· Every default branch read has at least one rule."
                             : "⚠ Default branches with no ruleset rules: \(bare.joined(separator: ", ")).")
                let ruled = checked.compactMap { repo in rules[repo.name].flatMap { $0.isEmpty ? nil : "\(repo.name): \($0.joined(separator: ", "))" } }
                if !ruled.isEmpty { lines.append("Rules on default branches:\n" + ruled.map { "  " + $0 }.joined(separator: "\n")) }
                if live.count > checked.count { lines.append("Rules were read for the \(checked.count) most recently pushed repositories of \(live.count); ask for more with rules.") }
                if !failed.isEmpty { lines.append("Rules could not be read for: " + failed.prefix(5).joined(separator: "; ")) }
            }
            struct Kept: Encodable { let name: String; let visibility: String?; let secretScanning: String?; let pushProtection: String?; let rules: [String]? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["repositories": live.prefix(200).map {
                Kept(name: $0.name, visibility: $0.visibility, secretScanning: $0.secretScanning, pushProtection: $0.pushProtection, rules: rules[$0.name])
            }])
        }
    }

    struct DeployKey: Codable, Sendable {
        let id: Int, key: String?, title: String?, read_only: Bool?, created_at: String?, added_by: String?, last_used: String?, verified: Bool?, enabled: Bool?
    }

    struct DeployKeys: ServiceOperation {
        struct Input: Decodable, Sendable { let repo: String?; let repos: Int? }
        static let name = "deploy-keys"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Deploy keys of one repository, or of the most recently pushed repositories, keys that can write first, with who added each and when it was last used. GitHub lists them only repository by repository."
        static let input = JSONSchema.object([
            "repo": .string("One repository, by name or as organisation/name. All, most recently pushed first, when left out."),
            "repos": .integer("How many repositories to read when no repo is given (30 when left out).", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var names: [String], total: Int?
            if let repo = input.repo {
                names = [try GitHub.repository(repo, service)]
            } else {
                let cap = input.repos ?? 30
                guard (1...100).contains(cap) else { throw ServiceError.input("Read between 1 and 100 repositories.") }
                let live = try await GitHub.repositories(service).items.filter { $0.archived != true }
                names = Array(live.prefix(cap).map(\.name))
                total = live.count
            }
            let answers = await GitHub.each(names) { name in
                let path = try GitHub.repoPath(name, service, "keys")
                return try await GitHub.read(GitHub.deployKeysNeed) { try await GitHub.list(service, path, pages: 2, as: DeployKey.self).items }
            }
            var found: [(String, DeployKey)] = [], failed: [String] = []
            for (name, answer) in answers {
                switch answer {
                case .success(let keys): found += keys.map { (name, $0) }
                case .failure(let error): failed.append("\(name): \(error.localizedDescription)")
                }
            }
            if found.isEmpty, failed.count == names.count, let first = failed.first { throw ServiceError.input("Deploy keys could not be read: \(first)") }
            found.sort { ($0.1.read_only == false ? 0 : 1, $0.0) < ($1.1.read_only == false ? 0 : 1, $1.0) }
            var lines = found.isEmpty ? ["No deploy keys in the \(GitHub.plural(names.count - failed.count, "repository")) read."] : found.map { repo, key in
                "\(key.read_only == false ? "⚠ write" : "· read-only") \(repo): \(key.title ?? "untitled") [key \(key.id)], added \(key.created_at ?? "?")\(key.added_by.map { " by \($0)" } ?? ""), last used \(key.last_used ?? "never or not given")\(key.enabled == false ? ", disabled" : "")"
            }
            if let total, total > names.count { lines.append("Read the \(names.count) most recently pushed repositories of \(total); ask for more with repos, or name one with repo.") }
            if !failed.isEmpty { lines.append("Could not be read: " + failed.prefix(5).joined(separator: "; ")) }
            struct Kept: Encodable { let repo: String; let id: Int; let title: String?; let readOnly: Bool?; let addedBy: String?; let lastUsed: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["keys": found.map {
                Kept(repo: $0.0, id: $0.1.id, title: $0.1.title, readOnly: $0.1.read_only, addedBy: $0.1.added_by, lastUsed: $0.1.last_used)
            }])
        }
    }

    struct FineGrainedToken: Decodable, Sendable {
        struct Permissions: Decodable, Sendable { let organization: [String: String]?; let repository: [String: String]? }
        let id: Int, owner: Person?, repository_selection: String?, permissions: Permissions?, access_granted_at: String?, created_at: String?
        let token_expired: Bool?, token_expires_at: String?, token_last_used_at: String?, token_name: String?, reason: String?

        var writes: [String] {
            ((permissions?.organization ?? [:]).merging(permissions?.repository ?? [:]) { $1 }).filter { $0.value == "write" || $0.value == "admin" }.keys.sorted()
        }
        var flags: [String] {
            var found: [String] = []
            if !writes.isEmpty { found.append("writes \(writes.joined(separator: ", "))") }
            if token_expires_at == nil { found.append("never expires") }
            if repository_selection == "all" { found.append("all repositories") }
            if token_expired == true { found.append("expired") }
            return found
        }
        var line: String {
            "\(flags.isEmpty ? "·" : "⚠") \(token_name ?? "unnamed") of \(owner?.login ?? "?") [\(id)]: \(repository_selection ?? "?") repositories, "
                + "expires \(token_expires_at ?? "never"), last used \(token_last_used_at ?? "never or not given")"
                + (flags.isEmpty ? "" : " — \(flags.joined(separator: "; "))")
        }
    }

    struct FineGrainedTokens: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "fine-grained-tokens"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Fine-grained personal access tokens that can reach the organisation, and requests waiting for approval, riskiest first: those that write, never expire or reach every repository. Classic tokens are not listed: only SAML credential authorizations show them, on Enterprise Cloud."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let tokens = await GitHub.attempt(GitHub.tokensNeed) {
                try await GitHub.list(service, try GitHub.orgPath(service, "personal-access-tokens"), as: FineGrainedToken.self)
            }
            let requests = await GitHub.attempt(GitHub.tokenRequestsNeed) {
                try await GitHub.list(service, try GitHub.orgPath(service, "personal-access-token-requests"), as: FineGrainedToken.self)
            }
            if tokens.value == nil, requests.value == nil { throw ServiceError.input([tokens.failure, requests.failure].compactMap { $0 }.joined(separator: "\n")) }
            var lines: [String] = []
            if let found = tokens.value {
                let ranked = found.items.sorted { $0.flags.count > $1.flags.count }
                lines.append(ranked.isEmpty ? "No fine-grained tokens have access to the organisation." : "\(GitHub.plural(ranked.count, "fine-grained token")) with access:\n" + ranked.map { "  " + $0.line }.joined(separator: "\n"))
                if found.more { lines.append("Stopped after \(GitHub.maximumPages) pages: there are more tokens.") }
            } else if let failure = tokens.failure { lines.append(failure) }
            if let found = requests.value {
                lines.append(found.items.isEmpty ? "No requests are waiting." : "\(GitHub.plural(found.items.count, "request")) waiting for approval:\n" + found.items.map { "  " + $0.line + ($0.reason.map { " — reason: \($0)" } ?? "") }.joined(separator: "\n"))
            } else if let failure = requests.failure { lines.append(failure) }
            struct Kept: Encodable { let id: Int; let name: String?; let owner: String?; let expires: String?; let lastUsed: String?; let flags: [String] }
            func kept(_ items: [FineGrainedToken]?) -> [Kept] { (items ?? []).map { Kept(id: $0.id, name: $0.token_name, owner: $0.owner?.login, expires: $0.token_expires_at, lastUsed: $0.token_last_used_at, flags: $0.flags) } }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["tokens": kept(tokens.value?.items), "requests": kept(requests.value?.items)])
        }
    }

    struct ActionsSettings: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "actions-settings"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The organisation's GitHub Actions policy: which repositories may run Actions and which actions they may use, the GITHUB_TOKEN's default permissions and whether workflows may approve pull requests, and its self-hosted runners."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Policy: Codable { let enabled_repositories: String?; let allowed_actions: String?; let sha_pinning_required: Bool? }
            struct Workflow: Codable { let default_workflow_permissions: String?; let can_approve_pull_request_reviews: Bool? }
            struct Label: Codable { let name: String? }
            struct Runner: Codable { let id: Int?; let name: String?; let os: String?; let status: String?; let busy: Bool?; let labels: [Label]? }
            let policy = await GitHub.attempt(GitHub.actionsNeed) { try await GitHub.get(service, try GitHub.orgPath(service, "actions", "permissions"), as: Policy.self) }
            let workflow = await GitHub.attempt(GitHub.actionsNeed) { try await GitHub.get(service, try GitHub.orgPath(service, "actions", "permissions", "workflow"), as: Workflow.self) }
            let runners = await GitHub.attempt(GitHub.runnersNeed) {
                try await GitHub.list(service, try GitHub.orgPath(service, "actions", "runners"), key: "runners", pages: 3, as: Runner.self)
            }
            if policy.value == nil, workflow.value == nil, runners.value == nil {
                throw ServiceError.input([policy.failure, workflow.failure, runners.failure].compactMap { $0 }.joined(separator: "\n"))
            }
            var lines: [String] = []
            if let policy = policy.value {
                let open = policy.enabled_repositories == "all" && policy.allowed_actions == "all"
                lines.append("\(open ? "⚠" : "·") Actions run in \(policy.enabled_repositories ?? "?") repositories, allowing \(policy.allowed_actions ?? "?") actions\(policy.sha_pinning_required == true ? ", pinned to full commit SHAs" : "")\(open ? ": any action from anyone may run" : "").")
            } else if let failure = policy.failure { lines.append(failure) }
            if let workflow = workflow.value {
                lines.append("\(workflow.default_workflow_permissions == "write" ? "⚠" : "·") The GITHUB_TOKEN gets \(workflow.default_workflow_permissions ?? "?") permissions by default.")
                lines.append("\(workflow.can_approve_pull_request_reviews == true ? "⚠" : "·") Workflows \(workflow.can_approve_pull_request_reviews == true ? "may" : "may not") approve pull requests.")
            } else if let failure = workflow.failure { lines.append(failure) }
            if let runners = runners.value {
                lines.append(runners.items.isEmpty ? "· No self-hosted runners at the organisation level." : "⚠ \(GitHub.plural(runners.items.count, "self-hosted runner")), each a machine that runs the workflows sent to it:\n" + runners.items.map {
                    "  \($0.name ?? "?") [\($0.id.map(String.init) ?? "?")]: \($0.os ?? "?"), \($0.status ?? "?")\($0.busy == true ? ", busy" : ""), labels \(($0.labels ?? []).compactMap(\.name).joined(separator: ", "))"
                }.joined(separator: "\n"))
            } else if let failure = runners.failure { lines.append(failure) }
            struct Kept: Encodable { let policy: Policy?; let workflow: Workflow?; let runners: [Runner]? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(policy: policy.value, workflow: workflow.value, runners: runners.value?.items))
        }
    }

    struct CredentialAuthorization: Codable, Sendable {
        let login: String?, credential_id: Int, credential_type: String?, token_last_eight: String?, credential_authorized_at: String?
        let credential_accessed_at: String?, authorized_credential_expires_at: String?, scopes: [String]?, authorized_credential_title: String?
        var line: String {
            "\(credential_type ?? "credential") of \(login ?? "?") [\(credential_id)]\(token_last_eight.map { " ending \($0)" } ?? "")\(authorized_credential_title.map { " \"\($0)\"" } ?? ""): "
                + "authorized \(credential_authorized_at ?? "?"), last used \(credential_accessed_at ?? "never or not given"), expires \(authorized_credential_expires_at ?? "never")"
                + ((scopes ?? []).isEmpty ? "" : ", scopes \((scopes ?? []).joined(separator: ", "))")
        }
    }

    struct CredentialAuthorizations: ServiceOperation {
        struct Input: Decodable, Sendable { let login: String? }
        static let name = "credential-authorizations"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Credentials authorized for the organisation's SAML single sign-on: classic and fine-grained personal access tokens, SSH keys and OAuth and GitHub App tokens, with who holds each, when it was last used and when it expires. Only GitHub Enterprise Cloud with SAML single sign-on has them; an owner reads them."
        static let input = JSONSchema.object(["login": .string("Only this user's credentials.")])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let login = try input.login.map { try GitHub.login($0) }
            let found = try await GitHub.read(GitHub.ssoNeed) {
                try await GitHub.list(service, try GitHub.orgPath(service, "credential-authorizations"), query: ["login": login], as: CredentialAuthorization.self)
            }
            var lines = found.items.isEmpty ? ["No credentials are authorized for single sign-on\(login.map { " for \($0)" } ?? "")."] : found.items.map(\.line)
            if found.more { lines.append("Stopped after \(GitHub.maximumPages) pages: there are more.") }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["credentials": found.items])
        }
    }

    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Says who signed in and their role in the organisation, how the App is installed and which permissions it lacks or holds beyond reading, then tries one read of each part and says, for each that fails, the permission, role or plan it needs. It sends only reads."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try GitHub.api(service)
            let org = try GitHub.org(service)
            var lines = ["· Organisation \(org), reached at https://\(GitHub.host) and nowhere else."]
            lines += await GitHub.signerLines(service, wantOwner: "most audit reads need an owner, and alerts an owner or security manager")
            lines += await GitHub.installationLines(service, wanted: GitHub.detectionPermissions)
            let one: [String: String?] = ["per_page": "1"]
            lines.append(await GitHub.probe(GitHub.membersNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "members"), query: one, as: [Person].self) })
            lines.append(await GitHub.probe(GitHub.teamsNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "teams"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.auditNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "audit-log"), query: one, as: [CellValue].self) })
            for kind in AlertKind.allCases {
                lines.append(await GitHub.probe(kind.need) { _ = try await GitHub.get(service, try GitHub.orgPath(service) + kind.path, query: one, as: [CellValue].self) })
            }
            lines.append(await GitHub.probe(GitHub.orgNeed) {
                let settings = try await GitHub.get(service, try GitHub.orgPath(service), as: [String: CellValue].self)
                if settings["two_factor_requirement_enabled"] == nil { throw ServiceError.forbidden("owner-only fields hidden") }
            })
            lines.append(await GitHub.probe(GitHub.twoFactorNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "members"), query: ["per_page": "1", "filter": "2fa_disabled"], as: [Person].self) })
            lines.append(await GitHub.probe(GitHub.codeSecurityNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "code-security", "configurations"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.installationsNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "installations"), query: one, as: [String: CellValue].self) })
            lines.append(await GitHub.probe(GitHub.hooksNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "hooks"), query: one, as: [CellValue].self) })
            var first: Repository?
            lines.append(await GitHub.probe(GitHub.reposNeed) { first = try await GitHub.get(service, try GitHub.orgPath(service, "repos"), query: ["per_page": "1", "sort": "pushed"], as: [Repository].self).first })
            if let first {
                lines.append(await GitHub.probe(GitHub.deployKeysNeed) { _ = try await GitHub.get(service, try GitHub.repoPath(first.name, service, "keys"), query: one, as: [CellValue].self) })
                if let branch = first.default_branch {
                    lines.append(await GitHub.probe(GitHub.rulesNeed) { _ = try await GitHub.get(service, try GitHub.repoPath(first.name, service, "rules", "branches", branch), as: [CellValue].self) })
                }
            }
            lines.append(await GitHub.probe(GitHub.tokensNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "personal-access-tokens"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.tokenRequestsNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "personal-access-token-requests"), query: one, as: [CellValue].self) })
            lines.append(await GitHub.probe(GitHub.actionsNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "actions", "permissions"), as: [String: CellValue].self) })
            lines.append(await GitHub.probe(GitHub.runnersNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "actions", "runners"), query: one, as: [String: CellValue].self) })
            lines.append(await GitHub.probe(GitHub.ssoNeed) { _ = try await GitHub.get(service, try GitHub.orgPath(service, "credential-authorizations"), query: one, as: [CellValue].self) })
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }

    /// Who signed in and their role, as lines for check-access.
    static func signerLines(_ service: ServiceClient, wantOwner why: String) async -> [String] {
        do {
            let signer = try await signer(service)
            switch signer.role {
            case "admin"?: return ["✓ Signed in as \(signer.login), an owner of the organisation."]
            case let role?: return ["⚠ Signed in as \(signer.login), a \(role) of the organisation, not an owner: \(why). Connect the tool again signed in as an owner."]
            case nil: return ["✗ Signed in as \(signer.login), whose membership of the organisation could not be read: they may not be a member, the App may lack \(membersRead.title), or the organisation's SAML single sign-on needs a session first."]
            }
        } catch {
            return ["✗ Who signed in could not be read: " + (fix(for: error, membersNeed) ?? error.localizedDescription)]
        }
    }
}
