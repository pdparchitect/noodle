import Foundation
import NoodleCore
import NoodleToolConnections

/// Google Cloud, as a defender reads it: who did what in the audit logs, what Security Command Center found, who has
/// access to what, and where resources are. Each account is one organisation, folder or project, read as the person
/// who signs in with Google, through an iOS OAuth client their organisation made for Pion's bundle ID, as Google
/// Workspace is. It never signs in as a service account.
public enum GoogleCloud {
    public static let preset = ToolDefinition(
        id: "371912f8-7145-4096-a763-2c3ce3af0e55", name: "Google Cloud Detection", summary: "Audit logs, Security Command Center findings, IAM access and resources, read-only.",
        defaultInstructions: """
        Use Google Cloud Detection to investigate an organisation, folder or project: audit-logs searches the Cloud Audit \
        Logs of the scope, its folders and its projects, and log views of a central logging bucket when named, by \
        principal, including what they did while impersonating a service account, method, resource, caller IP, \
        outcome, service, log and time, and shows what an IAM change granted or revoked and the request's key fields; \
        scc-findings lists Security Command Center findings by severity and category, scc-finding reads one in full \
        and scc-summary counts them by category, severity or project; iam-policies finds who has access to what, for a \
        member, including through groups, or for a resource; who-can-impersonate finds who can act as a service \
        account, or which service accounts a member can act as; public-resources finds what allUsers or \
        allAuthenticatedUsers can reach; sa-keys lists service account keys, flagging user-managed and new ones; \
        asset-history compares IAM policies or resources of one type with how they were up to 35 days ago; \
        org-policies lists organisation policies, flagging security constraints loosened; logging-coverage says where \
        Data Access audit logging is on; and find-resources lists resources by type, name, creation time and location. \
        The alert watch checks every five minutes and wakes you with a note naming security-events, which reads what \
        it reads for the note's window: Security Command Center's active, unmuted, high and critical findings, threats \
        first, and the Admin Activity audit logs of the scope, its folders and its projects, which Google always writes \
        and does not charge for, for service account keys made or uploaded, owner, editor, token creator, key admin, \
        organisation admin or security admin granted, anything granted to allUsers or allAuthenticatedUsers, Data \
        Access logging turned off or someone exempted from it, log sinks, exclusions and buckets changed, workload \
        identity pools and providers made or changed, security organisation policies loosened or reset, firewall rules \
        opening to 0.0.0.0/0 or ::/0, project-wide metadata or a VM's SSH keys or OS Login changed, projects deleted, \
        buckets and datasets made public, a service account made and then granted a role, VMs made with GPUs or twenty \
        by one account, and encryption key versions destroyed or disabled. It does not read Data Access logs, which are \
        off by default, so it never wakes for tokens minted for a service account, secrets read or data copied: search \
        those with audit-logs. A note may name a feed the watch could not read, such as Security Command Center not \
        activated or a sign-in expired, or read only in part; security-events says which and why, so tell the champion \
        what to change and treat that feed's silence as unknown. \
        When a tool is refused or something you need seems missing, run check-access and tell the champion exactly \
        what it says to change. Silence is not proof: every result says what it searched, what it did not and why, \
        such as a project pending deletion or more projects than one search reaches, what it could not read and what \
        it read only in part, and when more matched than it kept; report those gaps with what you found. Data Access \
        audit logs, which record reads of data such as a bucket's objects, are off by default for every service but \
        BigQuery, and reading them needs Private Logs Viewer, so no data reads found means unknown unless \
        logging-coverage or the champion confirms Data Access logging is on for that service. Logs stay 30 days in the \
        _Default bucket, which holds Data Access logs, and 400 days in _Required, which holds Admin Activity and \
        System Event logs; an organisation may route copies to a log bucket of its own, which audit-logs searches \
        when you name its view in logViews. An audit entry's principal, service account key and delegation chain name \
        the credential used, not who held it: a stolen token or key acts as its owner, so say what the log shows and \
        what it does not prove. Findings exist only for what Security Command Center's tier detects: threat findings \
        need Premium or Enterprise. Muted findings are left out unless asked for. IAM answers cover allow policies \
        only, not deny policies; access through groups needs the signer to read Workspace groups and custom roles \
        need Role Viewer, and the answer says when either is missing. Google allows an organisation without Security \
        Command Center Premium or Enterprise 20 IAM analyses a day, shared by iam-policies, who-can-impersonate and \
        check-access, so ask them narrowly. Cloud Asset's IAM data, such as keys, can lag up to 7 days, so check \
        recent changes in the audit logs. Recipes: a key made and used: audit-logs method CreateServiceAccountKey \
        shows the key's name in its response, then audit-logs principal set to the service account shows each entry \
        made with that key, and sa-keys what keys exist; impersonation: who-can-impersonate on the account, \
        audit-logs principal set to the person, and service iamcredentials.googleapis.com with logType data_access \
        for the tokens minted, which IAM's Data Access logs record only when on; a secret read: service \
        secretmanager.googleapis.com, method AccessSecretVersion, logType data_access; keys destroyed or used: \
        service cloudkms.googleapis.com, method DestroyCryptoKeyVersion, or Decrypt with logType data_access; a \
        firewall opened: method compute.firewalls, whose request shows sourceRanges and ports; a bucket made public: \
        method setIamPermissions with service storage.googleapis.com, whose change shows allUsers, then \
        public-resources and asset-history for the bucket type; workloads deployed: service run.googleapis.com, \
        cloudfunctions.googleapis.com or container.googleapis.com, and k8s.io with method pods.exec or \
        clusterrolebindings inside clusters; cryptomining: find-resources compute.googleapis.com/Instance with \
        createdSince and location, then audit-logs method compute.instances.insert, and scc-findings category \
        Execution: Cryptocurrency Mining Hash Match; logging tampered with: method ConfigServiceV2 for sinks, \
        exclusions and buckets, SetIamPolicy whose change turns audit logging off, and logging-coverage; policies \
        loosened: org-policies, and audit-logs method SetOrgPolicy or OrgPolicy.UpdatePolicy. Record each finding as \
        evidence, citing the scope, the time window and each entry's insertId. These tools only read: recommend \
        removing access or changing a resource to the champion.
        """,
        iconName: "google-cloud",
        configuration: .connection(.init(endpointTemplate: "https://googleapis.com",
            fields: [ToolField(key: "level", title: "Scope", placeholder: "organizations", kind: .choice([
                         .init(value: "organizations", title: "Organization"), .init(value: "folders", title: "Folder"),
                         .init(value: "projects", title: "Project")])),
                     ToolField(key: "id", title: "Organization, folder or project ID", placeholder: "123456789012", kind: .identifier),
                     ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            // The narrowest each API takes: Logging's read-only scope, and Cloud Asset's and Security Command Center's own,
            // as neither has a read-only one and none of their methods takes Google Cloud's read-only scope, by each API's
            // discovery document. Google lets both change things too, such as Cloud Asset's feeds and SCC's mutes, so the
            // signer's viewer roles are what keep them to reading; Pion only reads with them. Never all of Google Cloud,
            // which Cloud Asset's searches would need; its list and analysis stand in for them.
            oauth: .google(scopes: [logsScope, assetsScope, findingsScope], clients: []),
            oauthClientField: "clientID", adapter: "google-cloud")),
        setup: setup)

    static let logsScope = "https://www.googleapis.com/auth/logging.read"
    static let assetsScope = "https://www.googleapis.com/auth/cloudasset"
    static let findingsScope = "https://www.googleapis.com/auth/securitycenter"

    static let setup = [
        "In the [Google Cloud console](https://console.cloud.google.com), pick or create a project in your organisation and enable the [Cloud Logging API](https://console.cloud.google.com/apis/library/logging.googleapis.com), the [Security Command Center API](https://console.cloud.google.com/apis/library/securitycenter.googleapis.com) and the [Cloud Asset API](https://console.cloud.google.com/apis/library/cloudasset.googleapis.com) in it. Pion's requests count against this project.",
        "Set up [Google Auth Platform](https://console.cloud.google.com/auth/overview) with the audience **Internal**, and under [Data Access](https://console.cloud.google.com/auth/scopes) add the scopes `https://www.googleapis.com/auth/logging.read`, `https://www.googleapis.com/auth/cloudasset` and `https://www.googleapis.com/auth/securitycenter`. Data Access offers an API's scopes only once that API is enabled in the project. The same client can serve both Google Workspace tools too.",
        "Under [Clients](https://console.cloud.google.com/auth/clients), choose **Create client** of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev), and copy its **Client ID** here.",
        "Whoever signs in acts with their own access, so sign in with an account kept for Pion that holds only viewer roles. In [IAM](https://console.cloud.google.com/iam-admin/iam), on the organisation, folder or project to investigate, it needs **Logs Viewer** and **Private Logs Viewer** for the audit logs, Data Access logs included, **Security Center Findings Viewer** for findings, **Cloud Asset Viewer** for access, resources, keys, organisation policies and audit configuration, and **Role Viewer** so access through custom roles is analysed. If your organisation routes audit logs to a log bucket of its own, give it **Logs View Accessor** on that bucket's project too, or on the view alone with an IAM condition, so audit-logs can search the view named in logViews. For access through groups, give it **Groups Reader** in the [Admin console](https://admin.google.com/ac/roles) too. Neither Cloud Asset nor Security Command Center offers a read-only scope, so these viewer roles are what keep Pion's sign-in to reading: it could do whatever the account can there. Never sign in with an account that can change anything, such as an Owner, Editor, Security Center Admin, Findings Editor, Findings Mute Setter or Cloud Asset Owner. check-access warns when it can change findings.",
        "Turn on Data Access audit logs, at least Data Read, for the services that hold sensitive data, such as Cloud Storage, in [Audit Logs](https://console.cloud.google.com/iam-admin/audit): they are off by default for every service but BigQuery, and without them nobody's reads are recorded. Findings need [Security Command Center](https://console.cloud.google.com/security/command-center) activated: Standard and Enterprise only for a whole organisation, Premium for an organisation or a project, and only Premium and Enterprise detect threats.",
        "Set Scope and its ID to where they have that access: the organisation's or folder's number, or the project's ID. Then choose **Add & Connect**, sign in, and ask an agent to run check-access.",
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        AuditLogs(), SecurityEvents(), Findings(), FindingDetail(), FindingSummary(), IAMPolicies(), Impersonation(), PublicResources(),
        ServiceAccountKeys(), AssetHistory(), OrgPolicies(), LoggingCoverage(), FindResources(), CheckAccess(),
        DisableKey(), EnableKey(), DisableServiceAccount(), EnableServiceAccount(), RemoveIAMMember(), EnforcePublicAccessPrevention(),
        RevertPublicAccessPrevention(), SnapshotDisks(), StopInstance(), IsolateInstance(), UnisolateInstance(), ComputeOperationStatus(),
        ContainmentCheckAccess(),
    ]

    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents())

    /// The account's scope, such as organizations/123456789012.
    static func scope(_ service: ServiceClient) throws -> (level: String, id: String) {
        let level = try ServiceInput.oneOf(try service.setting("level"), ["organizations", "folders", "projects"], "scope")
        return (level, try service.setting("id"))
    }

    // MARK: Limits

    /// The most pages of up to 1000 folders and projects one listing reads, 10,000 in all: Cloud Asset allows 100
    /// listings a minute for a project, so this leaves room for the rest of an investigation.
    static let listingPages = 10
    /// The most resources Logging searches in one request, which Google does not raise.
    static let namesPerSearch = 100
    /// The most Logging requests one audit log search sends, across all its resources: Logging allows 60 searches a
    /// minute for the project Pion's requests count against, and an investigation runs several.
    static let searchRequests = 20
    /// The most pages one search of up to 100 resources reads, as Logging may hand back empty pages that still lead on.
    static let searchPages = 10
    /// The most pages of findings or resources one call reads.
    static let findingPages = 5
    static let resourcePages = 10
    /// How many results each lists in its text; the structured result keeps more.
    static let shown = 30
    /// The most pages of up to 1000 IAM policies, keys or organisation policies one call reads, 10,000 in all, as for
    /// folders and projects: well under Cloud Asset's 100 listings a minute for the project Pion's requests count
    /// against and 800 a minute for an organisation.
    static let policyPages = 10
    /// The most pages one snapshot of asset-history reads; it reads two, then and now, so ten requests in all.
    static let historyPages = 5
    /// The most pages of up to 100 Security Command Center sources check-access reads, and how many of them it asks
    /// which permissions the account holds, one request each: an organisation has one source per built-in service and
    /// integration, a few dozen at most.
    static let sourcePages = 5
    static let sourceChecks = 20
    /// The most pages of up to 1000 groups scc-summary reads: more groups than categories, severities and projects
    /// usually make.
    static let groupPages = 3

    // MARK: Folders and projects

    static let projectType = "cloudresourcemanager.googleapis.com/Project"
    static let folderType = "cloudresourcemanager.googleapis.com/Folder"

    /// A folder or project under the scope, by the name Logging takes for it, projects/ID or folders/NUMBER, and its
    /// lifecycle state.
    struct Container: Sendable {
        let name: String, id: String, number: String, state: String
        var isProject: Bool { name.hasPrefix("projects/") }
        var live: Bool { state == "ACTIVE" }
        var stateSaid: String { state == "DELETE_REQUESTED" ? "pending deletion" : state.lowercased().replacingOccurrences(of: "_", with: " ") }
    }

    /// The folders and projects found, and why the listing stopped short when it did.
    struct Hierarchy { var containers: [Container] = []; var stopped: String? = nil }

    /// The folders and projects under an organisation or folder, at every depth, from Cloud Asset's read-only listing,
    /// page after page. A deleted project or folder stays listed, pending deletion, for 30 days. A later page that
    /// fails keeps what was listed and says why it stopped.
    static func hierarchy(_ service: ServiceClient, _ scope: (level: String, id: String),
                          types: [String] = [folderType, projectType]) async throws -> Hierarchy {
        struct Data: Decodable {
            let projectId: String?, lifecycleState: String?, state: String?
            enum Keys: String, CodingKey { case projectId, lifecycleState, state }
            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: Keys.self)
                projectId = try? fields?.decodeIfPresent(String.self, forKey: .projectId)
                lifecycleState = try? fields?.decodeIfPresent(String.self, forKey: .lifecycleState)
                state = try? fields?.decodeIfPresent(String.self, forKey: .state)
            }
        }
        struct Details: Decodable { let data: Data? }
        struct Asset: Decodable { let name: String?; let assetType: String?; let resource: Details? }
        struct Answer: Decodable { let assets: [Asset]?; let nextPageToken: String? }
        let own = "\(scope.level)/\(scope.id)"
        var found = Hierarchy(), token: String?
        for page in 0..<listingPages {
            let answer: Answer
            do {
                answer = try await read(.assets, own) {
                    try await service.at(host: "cloudasset.googleapis.com").get(["v1", scope.level, scope.id, "assets"], query: [
                        "contentType": "RESOURCE", "pageSize": "1000", "pageToken": token,
                    ], repeated: ["assetTypes": types], as: Answer.self)
                }
            } catch where page > 0 {
                found.stopped = "a later page of the listing could not be read: \(error.localizedDescription)"
                return found
            }
            for asset in answer.assets ?? [] {
                guard let name = asset.name, let number = name.split(separator: "/").last.map(String.init) else { continue }
                let data = asset.resource?.data
                let state = data?.lifecycleState ?? data?.state ?? "ACTIVE"
                let type = asset.assetType ?? (name.contains("/folders/") ? folderType : projectType)
                if type == projectType, let id = data?.projectId {
                    found.containers.append(Container(name: "projects/" + id, id: id, number: number, state: state))
                } else if type == folderType {
                    found.containers.append(Container(name: "folders/" + number, id: number, number: number, state: state))
                }
            }
            token = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if token == nil { return found }
        }
        found.stopped = "more than \(listingPages * 1000) folders and projects are under it, more than one listing reads"
        return found
    }

    /// For an organisation or folder, how each of its projects not in use is described, by its ID and by its number,
    /// so what sits in a project pending deletion is not taken for live; empty for a project's own account. A listing
    /// that could not be read whole, or at all, is said in `note`, rather than failing what was already found.
    static func retiredProjects(_ service: ServiceClient, _ scope: (level: String, id: String)) async -> (retired: [String: String], note: String?) {
        guard scope.level != "projects" else { return ([:], nil) }
        do {
            let found = try await hierarchy(service, scope, types: [projectType])
            var retired: [String: String] = [:]
            for project in found.containers where !project.live {
                retired[project.id] = project.stateSaid
                retired[project.number] = project.stateSaid
            }
            return (retired, found.stopped.map { "Only some projects were checked for pending deletion: \($0)." })
        } catch {
            return ([:], "Whether any of these sit in a project pending deletion could not be checked: \(error.localizedDescription)")
        }
    }

    /// The project a resource's full name or ancestor names, such as kestrel-prod in
    /// //iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@…, or 1001 in projects/1001.
    static func project(in name: String) -> String? {
        let parts = name.split(separator: "/")
        guard let index = parts.firstIndex(of: "projects"), index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }

    /// A value inside a Google filter's double quotes.
    static func quoted(_ value: String, _ name: String) throws -> String { "\"" + (try ServiceInput.quoted(value, name)) + "\"" }

    /// Words joined as a sentence lists them: a, b and c.
    static func listed(_ words: [String]) -> String {
        words.count <= 1 ? words.joined() : words.dropLast().joined(separator: ", ") + " and " + words.last!
    }

    /// Resources named for a sentence: each one when there are few, otherwise how many folders and projects, with the
    /// first few named.
    static func described(_ names: [String]) -> String {
        guard names.count > 5 else { return listed(names) }
        // A folder's or project's own name has two parts; a log view's below one has more.
        let own = { (name: String, kind: String) in name.hasPrefix(kind) && name.split(separator: "/").count == 2 }
        let folders = names.filter { own($0, "folders/") }.count, projects = names.filter { own($0, "projects/") }.count
        let others = names.filter { !own($0, "folders/") && !own($0, "projects/") }
        let counted = others + [folders == 0 ? nil : "\(folders) folder\(folders == 1 ? "" : "s")",
                                projects == 0 ? nil : "\(projects) project\(projects == 1 ? "" : "s")"].compactMap { $0 }
        return listed(counted) + " (" + names.filter { !others.contains($0) }.prefix(3).joined(separator: ", ") + "…)"
    }

    // MARK: Refusals

    /// What one thing the tool reads needs from the setup, to say exactly what to change when Google refuses it.
    struct Need: Sendable {
        let title: String, api: String, apiID: String, scope: String, role: String
        /// What to do when Google ran out of time, for a read that can be narrowed.
        var timeout: String? = nil
        /// What to do when the service is not set up for the scope, such as Security Command Center not activated.
        var inactive: String? = nil

        static let logs = Need(title: "Audit logs", api: "Cloud Logging API", apiID: "logging.googleapis.com", scope: logsScope,
                               role: "Logs Viewer (roles/logging.viewer), and Private Logs Viewer (roles/logging.privateLogViewer) for Data Access logs,")
        static let dataAccess = Need(title: "Data Access audit logs", api: "Cloud Logging API", apiID: "logging.googleapis.com", scope: logsScope,
                                     role: "Private Logs Viewer (roles/logging.privateLogViewer)")
        static let logViews = Need(title: "Log views", api: "Cloud Logging API", apiID: "logging.googleapis.com", scope: logsScope,
                                   role: "Logs View Accessor (roles/logging.viewAccessor), on the view or its bucket's project,")
        static let assets = Need(title: "Cloud Asset listing", api: "Cloud Asset API", apiID: "cloudasset.googleapis.com", scope: assetsScope,
                                 role: "Cloud Asset Viewer (roles/cloudasset.viewer)")
        static let analysis = Need(title: "IAM analysis", api: "Cloud Asset API", apiID: "cloudasset.googleapis.com", scope: assetsScope,
                                   role: "Cloud Asset Viewer (roles/cloudasset.viewer), and Role Viewer (roles/iam.roleViewer) for custom roles,",
                                   timeout: "Google ran out of time analysing the whole scope: narrow it with a role or a resource, or set the account to a folder or project.")
        static let findings = Need(title: "Security Command Center findings", api: "Security Command Center API", apiID: "securitycenter.googleapis.com",
                                   scope: findingsScope, role: "Security Center Findings Viewer (roles/securitycenter.findingsViewer)",
                                   inactive: "Security Command Center is not activated where this account looks: activate it in the console (Standard and Enterprise only for a whole organisation, Premium for an organisation or a project), or set the account's Scope to where it is.")
    }

    /// What to change when Google refused something, from what it said: a scope the sign-in lacks, an API turned off in
    /// the project, Security Command Center not activated, a search too big to finish, a role the account lacks, or a
    /// sign-in that expired; nil for any other failure.
    static func fix(for error: Error, _ need: Need, on scope: String) -> String? {
        let said: String, status: Int?
        switch error {
        case ServiceError.rejected: return "the sign-in expired or was revoked: sign the tool in again in Settings › Tools."
        case ServiceError.forbidden(let reason): said = reason ?? ""; status = 403
        case ServiceError.refused(let reason): said = reason; status = nil
        case ServiceError.status(let code, let reason): said = reason ?? ""; status = code
        default: return nil
        }
        let lower = said.lowercased()
        if lower.contains("insufficient authentication scopes") || lower.contains("access_token_scope_insufficient") {
            return "the sign-in lacks the scope \(need.scope): add it under Google Auth Platform › Data Access if it is missing, then sign the tool in again in Settings › Tools."
        }
        if lower.contains("has not been used in project") || lower.contains("service_disabled") || lower.contains("it is disabled") {
            // Google names the page that turns it on, with the project.
            let link = said.range(of: #"https://\S+"#, options: .regularExpression).map { String(said[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)")) }
            return "the \(need.api) is turned off in the tool's Google Cloud project: enable it at \(link ?? "https://console.cloud.google.com/apis/library/" + need.apiID), then try again."
        }
        if let inactive = need.inactive, lower.contains("activat") || lower.contains("onboard") || lower.contains("not enabled for") {
            return inactive
        }
        if let timeout = need.timeout, status == 504 || lower.contains("deadline") { return timeout }
        if case ServiceError.forbidden = error {
            return "the account signed in may not do this on \(scope): grant it \(need.role) there in IAM (https://console.cloud.google.com/iam-admin/iam), or check the account's Scope and ID in Settings › Tools."
        }
        return nil
    }

    /// A request, with Google's refusal said as what to change, so an agent can tell the champion.
    static func read<Value>(_ need: Need, _ scope: String, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need, on: scope) else { throw error }
            throw ServiceError.input("Google refused \(need.title.lowercased()): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }
}

extension GoogleCloud {
    struct AuditLogs: ServiceOperation {
        struct Input: Decodable, Sendable {
            let principal: String?, method: String?, resource: String?, ip: String?, status: String?, service: String?, logType: String?
            let logViews: [String]?, since: String?, until: String?, limit: Int?
        }
        static let name = "audit-logs"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Cloud Audit Log entries across the scope, its folders and its projects, and any log views named, newest first, by principal (what they did as themselves or while impersonating a service account), method, resource, caller IP, outcome, service and log, with who acted, the service account key and delegation behind it, what an IAM change granted or revoked, the permissions checked and the request's and response's key fields, saying what was and was not searched."
        static let input = JSONSchema.object([
            "principal": .string("Who acted: an email, such as mallory@example.com or a service account, matched also where they acted through a service account they impersonated; or a principal:// identity from workforce or workload identity federation."),
            "method": .string("The API method, or part of it, such as SetIamPolicy or google.iam.admin.v1.CreateServiceAccountKey."),
            "resource": .string("The resource name, or part of it, such as projects/my-project."),
            "ip": .string("The caller's IPv4 or IPv6 address."),
            "status": .string("Only entries that failed (any error), were denied (permission denied) or succeeded.", oneOf: ["failed", "denied", "succeeded"]),
            "service": .string("The Google Cloud service, such as storage.googleapis.com, secretmanager.googleapis.com or k8s.io."),
            "logType": .string("Only one audit log: Admin Activity, Data Access, System Event or Policy Denied. All of them when left out.", oneOf: logTypes),
            "logViews": .array(.string("A log view, as projects/PROJECT/locations/LOCATION/buckets/BUCKET/views/VIEW."),
                               "Log views of buckets the organisation routes audit logs to, such as a central logging project's, searched as well, up to \(mostViews); each must be held by the account's own project, folder or organisation or one under it."),
            "since": .string("The earliest time, in ISO 8601. 30 days before until, or before now, when left out."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."), "limit": .integer("How many entries, at most.", minimum: 1, maximum: 200),
        ])

        /// The audit logs one search can be narrowed to, as Logging names them after cloudaudit.googleapis.com/.
        static let logTypes = ["activity", "data_access", "system_event", "policy"]
        /// What each outcome is in Logging's terms: an entry's status code is absent or 0 when it succeeded, and 7,
        /// PERMISSION_DENIED, when IAM or VPC Service Controls refused it.
        static let statuses = ["failed": "protoPayload.status.code!=0", "denied": "protoPayload.status.code=7",
                               "succeeded": "(NOT protoPayload.status.code:* OR protoPayload.status.code=0)"]
        /// The most log views one search names, all searched together in one search of their own.
        static let mostViews = 10

        /// Who acted, as a Logging filter: an email matches who authenticated and the first person behind a delegation
        /// chain, so what someone did while impersonating a service account is found too; a federated identity matches
        /// its subject. IAM's own form, such as user:mallory@…, is matched by its email.
        static func principalFilter(_ principal: String) throws -> String {
            let value = principal.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("principal://") || value.hasPrefix("principalSet://") {
                let quoted = try GoogleCloud.quoted(value, "the principal")
                return "(protoPayload.authenticationInfo.principalSubject=\(quoted) OR protoPayload.authenticationInfo.serviceAccountDelegationInfo.principalSubject=\(quoted))"
            }
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            let email = parts.count == 2 && ["user", "serviceAccount", "group"].contains(parts[0]) ? parts[1] : value
            // Logging matches emails exactly, and records them in lower case.
            let quoted = try GoogleCloud.quoted(email.lowercased(), "the principal")
            return "(protoPayload.authenticationInfo.principalEmail=\(quoted) OR protoPayload.authenticationInfo.serviceAccountDelegationInfo.firstPartyPrincipal.principalEmail=\(quoted))"
        }

        /// A log view in the form Logging takes among the resources it searches.
        static func logView(_ value: String) throws -> String {
            let view = value.trimmingCharacters(in: .whitespaces)
            guard view.count <= 300, view.range(of: #"^(projects|organizations|folders|billingAccounts)/[A-Za-z0-9._:-]+/locations/[A-Za-z0-9_-]+/buckets/[A-Za-z0-9_.-]+/views/[A-Za-z0-9_.-]+$"#,
                                                options: .regularExpression) != nil else {
                throw ServiceError.input("Give each log view as projects/PROJECT/locations/LOCATION/buckets/BUCKET/views/VIEW, such as projects/siem-prod/locations/global/buckets/audit/views/_AllLogs.")
            }
            return view
        }

        struct Body: Encodable { let resourceNames: [String], filter: String, orderBy: String, pageSize: Int, pageToken: String? }
        struct FirstParty: Codable { let principalEmail: String? }
        struct Delegation: Codable { let firstPartyPrincipal: FirstParty?; let principalSubject: String? }
        struct Authentication: Codable {
            let principalEmail: String?, principalSubject: String?, serviceAccountKeyName: String?
            let serviceAccountDelegationInfo: [Delegation]?
        }
        struct Metadata: Codable { let callerIp: String?; let callerSuppliedUserAgent: String? }
        struct Status: Codable { let code: Int?; let message: String? }
        /// A permission Google checked for the request, and whether the caller held it.
        struct Authorization: Codable { let resource: String?, permission: String?, granted: Bool? }
        /// One role given to or taken from one member by an IAM policy change.
        struct BindingDelta: Codable { let action: String?, role: String?, member: String?; let condition: IAMPolicies.Expr? }
        /// Data Access logging turned on or off for a service by an IAM policy change.
        struct AuditConfigDelta: Codable { let action: String?, service: String?, exemptedMember: String?, logType: String? }
        struct PolicyDelta: Codable { let bindingDeltas: [BindingDelta]?; let auditConfigDeltas: [AuditConfigDelta]? }
        /// What an IAM policy change did, where Resource Manager, IAM, Cloud Storage and older services put it:
        /// serviceData, of the type google.iam.v1.logging.AuditData.
        struct AuditData: Codable {
            let policyDelta: PolicyDelta?
            enum CodingKeys: String, CodingKey { case policyDelta }
            init(from decoder: Decoder) throws { policyDelta = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(PolicyDelta.self, forKey: .policyDelta) }
        }
        /// The same where newer services put it, in metadata; BigQuery's dataset changes say theirs in datasetChange.
        struct AuditMetadata: Codable {
            struct DatasetChange: Codable { let bindingDeltas: [BindingDelta]? }
            let policyDelta: PolicyDelta?, datasetChange: DatasetChange?
            enum CodingKeys: String, CodingKey { case policyDelta, datasetChange }
            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: CodingKeys.self)
                policyDelta = try? fields?.decodeIfPresent(PolicyDelta.self, forKey: .policyDelta)
                datasetChange = try? fields?.decodeIfPresent(DatasetChange.self, forKey: .datasetChange)
            }
        }

        /// The fields of a request that decide a case, kept short: the account, bucket or key it named, a firewall's
        /// ranges and ports, a sink's filter and destination. Never a policy whole, metadata or key material.
        static let requestFields = ["name", "parent", "accountId", "account", "serviceAccount", "bucket", "destination", "filter", "includeChildren",
                                    "writerIdentity", "disabled", "direction", "network", "sourceRanges", "destinationRanges", "sourceTags",
                                    "targetTags", "targetServiceAccounts", "alloweds", "allowed", "denieds", "priority", "machineType",
                                    "guestAccelerators", "keyAlgorithm", "privateKeyType", "updateMask", "role"]
        /// The fields of a response that name what was made: a key's name, an account's unique ID and email, an
        /// operation's target.
        static let responseFields = ["name", "uniqueId", "email", "keyType", "keyOrigin", "validAfterTime", "validBeforeTime", "disabled",
                                     "targetLink", "operationType", "writerIdentity"]
        /// How many characters of each request or response field are kept.
        static let fieldLength = 200

        struct Payload: Codable {
            let methodName: String?, serviceName: String?, resourceName: String?, authenticationInfo: Authentication?
            let requestMetadata: Metadata?, status: Status?, authorizationInfo: [Authorization]?
            let serviceData: AuditData?, metadata: AuditMetadata?
            /// The request's and response's key fields, each shortened, read leniently as requests differ.
            let request: [String: String]?, response: [String: String]?

            enum CodingKeys: String, CodingKey {
                case methodName, serviceName, resourceName, authenticationInfo, requestMetadata, status, authorizationInfo, serviceData, metadata, request, response
            }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                func text(_ key: CodingKeys) -> String? { try? fields.decodeIfPresent(String.self, forKey: key) }
                methodName = text(.methodName); serviceName = text(.serviceName); resourceName = text(.resourceName)
                authenticationInfo = try? fields.decodeIfPresent(Authentication.self, forKey: .authenticationInfo)
                requestMetadata = try? fields.decodeIfPresent(Metadata.self, forKey: .requestMetadata)
                status = try? fields.decodeIfPresent(Status.self, forKey: .status)
                authorizationInfo = try? fields.decodeIfPresent([Authorization].self, forKey: .authorizationInfo)
                serviceData = try? fields.decodeIfPresent(AuditData.self, forKey: .serviceData)
                metadata = try? fields.decodeIfPresent(AuditMetadata.self, forKey: .metadata)
                func kept(_ key: CodingKeys, _ names: [String]) -> [String: String]? {
                    guard let object = (try? fields.decodeIfPresent(JSON.self, forKey: key)) ?? nil else { return nil }
                    let values = names.reduce(into: [String: String]()) { kept, name in
                        if let value = object[name], value != .null { kept[name] = value.compact(AuditLogs.fieldLength) }
                    }
                    return values.isEmpty ? nil : values
                }
                request = kept(.request, AuditLogs.requestFields)
                response = kept(.response, AuditLogs.responseFields)
            }

            /// The roles an IAM change gave and took, wherever the service logged them.
            var bindingDeltas: [BindingDelta] {
                serviceData?.policyDelta?.bindingDeltas ?? metadata?.policyDelta?.bindingDeltas ?? metadata?.datasetChange?.bindingDeltas ?? []
            }
            var auditConfigDeltas: [AuditConfigDelta] { serviceData?.policyDelta?.auditConfigDeltas ?? metadata?.policyDelta?.auditConfigDeltas ?? [] }

            /// What the entry changed and was allowed, in a few words each: roles granted and revoked, Data Access
            /// logging turned on or off, permissions denied, and the request's and response's key fields.
            var details: [String] {
                var said: [String] = []
                let deltas = bindingDeltas
                if !deltas.isEmpty {
                    said.append(deltas.prefix(5).map { delta in
                        let added = delta.action?.uppercased() == "ADD"
                        return "\(added ? "granted" : "revoked") \(delta.role ?? "?") \(added ? "to" : "from") \(delta.member ?? "?")"
                            + (delta.condition.map { " only when \($0.title ?? $0.expression ?? "a condition holds")" } ?? "")
                    }.joined(separator: "; ") + (deltas.count > 5 ? " (+\(deltas.count - 5) more)" : ""))
                }
                let audits = auditConfigDeltas
                if !audits.isEmpty {
                    said.append("audit logging " + audits.prefix(3).map { delta in
                        "\(delta.action?.uppercased() == "ADD" ? "turned on" : "turned off") \(delta.logType ?? "?") for \(delta.service ?? "?")"
                            + (delta.exemptedMember.map { " exempting \($0)" } ?? "")
                    }.joined(separator: "; ") + (audits.count > 3 ? " (+\(audits.count - 3) more)" : ""))
                }
                let denied = (authorizationInfo ?? []).filter { $0.granted == false }.compactMap(\.permission)
                if !denied.isEmpty { said.append("denied \(Array(Set(denied)).sorted().prefix(3).joined(separator: ", "))") }
                if let request = request?.filter({ $0.key != "name" }), !request.isEmpty {
                    said.append("request " + AuditLogs.requestFields.compactMap { key in request[key].map { "\(key)=\($0)" } }.prefix(6).joined(separator: ", "))
                }
                if let response, !response.isEmpty {
                    said.append("response " + AuditLogs.responseFields.compactMap { key in response[key].map { "\(key)=\($0)" } }.prefix(6).joined(separator: ", "))
                }
                return said
            }
        }
        struct Monitored: Codable {
            let type: String?, labels: [String: String]?
            enum CodingKeys: String, CodingKey { case type, labels }
            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: CodingKeys.self)
                type = try? fields?.decodeIfPresent(String.self, forKey: .type)
                labels = try? fields?.decodeIfPresent([String: String].self, forKey: .labels)
            }
        }
        struct Entry: Codable {
            let insertId: String?, timestamp: String?, logName: String?, severity: String?, resource: Monitored?, protoPayload: Payload?

            var failed: Bool { (protoPayload?.status?.code ?? 0) != 0 }

            /// The container whose log holds it, such as projects/kestrel-prod or folders/42.
            var container: String? {
                guard let log = logName else { return nil }
                let parts = log.split(separator: "/")
                return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
            }

            /// What makes it the same entry when two searches return it, such as a project's own log and a log view
            /// its entries are routed to: Logging takes entries of one log with the same insertId and time as one, and
            /// an entry routed to a bucket keeps its logName, so a view's copy carries its original's. Two projects'
            /// entries may share an insertId and a time, so the log tells them apart. Nil without a log or an insertId,
            /// as such an entry cannot be matched to another's copy and is kept.
            var identity: String? {
                guard let insertId, let log = logName.map({ $0.removingPercentEncoding ?? $0 }) else { return nil }
                return "\(log)|\(insertId)|\(timestamp ?? "")"
            }

            /// One line: when, what, who with which key and through whom, from where, on what, where it was logged,
            /// whether it failed, and what it changed.
            func line(own: String) -> String {
                let payload = protoPayload, auth = payload?.authenticationInfo
                var line = "\(timestamp ?? "?") \(payload?.methodName ?? "?")"
                if let who = auth?.principalEmail ?? auth?.principalSubject { line += " by \(who)" }
                let chain = (auth?.serviceAccountDelegationInfo ?? []).compactMap { $0.firstPartyPrincipal?.principalEmail ?? $0.principalSubject }
                if !chain.isEmpty { line += " (delegated by \(chain.joined(separator: " → ")))" }
                if let key = auth?.serviceAccountKeyName {
                    line += " with key \(key.split(separator: "/").last.map(String.init) ?? key)"
                } else if auth?.principalEmail?.hasSuffix(".gserviceaccount.com") == true, chain.isEmpty {
                    // A service account without a key recorded may have used a key the log omits, an attached account or a token.
                    line += " with key unknown"
                }
                if let ip = payload?.requestMetadata?.callerIp { line += " from \(ip)" }
                if let resource = payload?.resourceName { line += " on \(resource)" }
                if let target = payload?.request?["name"], target != payload?.resourceName { line += " (target \(target))" }
                // Where it was logged, when that is not the scope itself.
                if let container, container != own { line += " in \(container)" }
                if failed { line += " — failed (\(payload?.status?.message ?? String(payload?.status?.code ?? 0)))" }
                for detail in payload?.details ?? [] { line += " — \(detail)" }
                if let agent = payload?.requestMetadata?.callerSuppliedUserAgent { line += " — agent \(agent.prefix(80))" }
                if let id = insertId { line += " [insertId \(id)]" }
                return line
            }
        }
        struct Entries: Codable { let entries: [Entry]?; var nextPageToken: String? = nil }

        /// What a search of up to 100 resources names: the scope's own folders and projects, those pending deletion,
        /// or log views named, each searched apart so one cannot fail the others.
        enum Kind { case live, retired, view }

        /// One search of up to 100 resources, as Logging takes them: what it found, the page it would read next, and
        /// why it stopped.
        struct Searched {
            let names: [String], kind: Kind
            var entries: [Entry] = [], token: String? = nil, calls = 0
            /// The first page failed, so nothing of these resources was read.
            var error: Error? = nil
            /// A later page failed, so only the newer entries were read.
            var partial: String? = nil
        }

        struct Gap: Encodable { var resources: [String]; let reason: String }
        struct Continuation: Encodable { let resourceNames: [String]; let pageToken: String; let reason: String }
        struct Coverage: Encodable {
            var since = "", until: String? = nil
            var searched: [String] = [], searchedPendingDeletion: [String] = [], searchedViews: [String] = []
            var notSearched: [Gap] = [], failed: [Gap] = [], partial: [Gap] = [], unfinished: [String] = []
            /// Why the folders and projects under the scope could not be listed in full, when they could not.
            var listing: String? = nil
            /// Whether more entries matched than were kept.
            var more = false
            /// How many entries two searches both returned, kept once.
            var duplicates = 0
            /// How many entries named no log or insertId, so a copy of one from a log view could not be matched to it.
            var unmatched = 0
            var continuations: [Continuation] = []
        }
        struct Kept: Encodable { let entries: [Entry]; let coverage: Coverage; let filter: String; let succeeded: Int; let failed: Int }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            // The audit logs by name, which Logging finds by index; matching part of every log's name is slow enough
            // across an organisation's projects for Logging to fail the search.
            let logs = try input.logType.map { [try ServiceInput.oneOf($0, Self.logTypes, "logType")] } ?? Self.logTypes + ["access_transparency"]
            let named = logs.map { #"log_id("cloudaudit.googleapis.com/\#($0)")"# }
            var filter = [named.count == 1 ? named[0] : "(" + named.joined(separator: " OR ") + ")"]
            // Every value goes between double quotes, refused when it holds a quote, backslash or line break that could
            // end them early.
            if let principal = input.principal { filter.append(try Self.principalFilter(principal)) }
            if let method = input.method { filter.append("protoPayload.methodName:" + (try GoogleCloud.quoted(method, "the method"))) }
            if let resource = input.resource { filter.append("protoPayload.resourceName:" + (try GoogleCloud.quoted(resource, "the resource"))) }
            if let ip = input.ip { filter.append("protoPayload.requestMetadata.callerIp=" + (try GoogleCloud.quoted(try ServiceInput.ip(ip), "the IP address"))) }
            if let status = input.status {
                filter.append(Self.statuses[try ServiceInput.oneOf(status, ["failed", "denied", "succeeded"], "status")]!)
            }
            if let name = input.service {
                filter.append("protoPayload.serviceName=" + (try GoogleCloud.quoted(try ServiceInput.domain(name), "the service")))
            }
            let views = try (input.logViews ?? []).isEmpty ? [] : ServiceInput.list(input.logViews ?? [], limit: Self.mostViews, Self.logView)
            // The window reaches 30 days back from its end, so a search up to a past time is not left empty.
            let until = try input.until.map(ServiceInput.time)
            let since = try input.since.map(ServiceInput.time)
                ?? ISO8601DateFormatter().string(from: (until.flatMap(ServiceAlert.time) ?? Date()).addingTimeInterval(-30 * 86_400))
            if let until, let start = ServiceAlert.time(since), let end = ServiceAlert.time(until), start > end {
                throw ServiceError.input("since (\(since)) is after until (\(until)); give since before until.")
            }
            filter.append("timestamp>=\"\(since)\"")
            if let until { filter.append("timestamp<=\"\(until)\"") }
            let limit = input.limit ?? 50
            guard (1...200).contains(limit) else { throw ServiceError.input("Ask for between 1 and 200 entries.") }
            let query = filter.joined(separator: " AND ")
            var coverage = Coverage(since: since, until: until)

            // Each folder and project keeps its own audit logs, so an organisation's or folder's search names them too.
            // One pending deletion is searched apart, so it cannot fail the search of the live ones.
            var live = [own], retired: [String] = []
            // A log view is searched only when the project, folder or organisation holding it is inside the account's
            // scope, checked against the listing below, so naming one never widens what the account reads.
            var listed: Hierarchy?, listingFailure: String?
            if scope.level != "projects" {
                do {
                    let found = try await GoogleCloud.hierarchy(service, scope)
                    listed = found
                    for container in found.containers where container.name != own {
                        if container.live { live.append(container.name) } else { retired.append(container.name) }
                    }
                    // Folders first, as their few logs hold changes to everything below them.
                    live = [own] + live.dropFirst().filter { $0.hasPrefix("folders/") } + live.dropFirst().filter { !$0.hasPrefix("folders/") }
                    if let stopped = found.stopped { coverage.listing = "Only some folders and projects under \(own) were listed, as \(stopped), so the rest were not searched; set the account to a folder." }
                } catch {
                    listingFailure = error.localizedDescription
                    coverage.listing = "The folders and projects under \(own) could not be listed, so only its own logs were searched: \(error.localizedDescription)"
                }
            }
            if !views.isEmpty {
                let parents = views.map { $0.split(separator: "/").prefix(2).joined(separator: "/") }
                let placed = GoogleCloud.placed(Array(Set(parents)).sorted(), own: own, level: scope.level, listing: listed, failure: listingFailure)
                if !placed.outside.isEmpty {
                    throw GoogleCloud.outsideScope(placed.outside.map { outside in
                        (views.filter { $0.hasPrefix(outside.name + "/") }.joined(separator: ", "), "held by \(outside.name): \(outside.why)")
                    }, own: own)
                }
            }
            func chunked(_ names: [String], _ kind: Kind) -> [(names: [String], kind: Kind)] {
                stride(from: 0, to: names.count, by: namesPerSearch).map { (Array(names[$0..<min($0 + namesPerSearch, names.count)]), kind) }
            }
            // Log views were asked for by name, so they are searched right after the scope's own first search.
            var chunks = chunked(live, .live)
            chunks.insert(contentsOf: chunked(views, .view), at: min(1, chunks.count))
            chunks += chunked(retired, .retired)

            let logging = try service.at(host: "logging.googleapis.com")
            // Logging fails a search now and then, as Google says to expect, so a failed page is asked for once more.
            // Some searches it fails every time while small pages of the same still come back, so after that the rest is
            // read in pages of five; failing even those, the search keeps what it found, saying where Logging stopped. A
            // later page refused or rate limited keeps what was found too.
            let smallPage = 5
            func search(_ names: [String], kind: Kind, allowed: Int) async -> Searched {
                var found = Searched(names: names, kind: kind), page: String?, pages = 0, retried = false, pageSize: Int?, failure: Error?
                // A log view is read with its own role, so a refusal says to grant that.
                let need = kind == .view ? Need.logViews : Need.logs, on = kind == .view ? GoogleCloud.listed(names) : own
                while found.calls < allowed {
                    let body = Body(resourceNames: names, filter: query, orderBy: "timestamp desc",
                                    pageSize: min(limit - found.entries.count, pageSize ?? limit), pageToken: page)
                    found.calls += 1
                    let answer: Entries
                    do {
                        answer = try await GoogleCloud.read(need, on) { try await logging.post(["v2", "entries:list"], body: body, as: Entries.self) }
                        failure = nil
                    } catch {
                        failure = error
                        if case ServiceError.status(let status, _) = error, status >= 500 {
                            if !retried {
                                retried = true
                                try? await Task.sleep(for: .seconds(1))
                                continue
                            }
                            if pageSize == nil, body.pageSize > smallPage {
                                pageSize = smallPage
                                continue
                            }
                        }
                        break
                    }
                    pages += 1
                    found.entries += answer.entries ?? []
                    page = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
                    if page == nil || found.entries.count >= limit || pages >= searchPages { break }
                }
                if let failure {
                    if pages == 0 { found.error = failure } else { found.partial = failure.localizedDescription }
                }
                found.token = page
                return found
            }

            // Every search gets one request at least while the budget lasts; the first ones may read further.
            var searches: [Searched] = [], remaining = searchRequests
            for (index, chunk) in chunks.enumerated() {
                guard remaining > 0 else {
                    // Said once for all of them, once for those pending deletion and once for log views.
                    let reason = (chunk.kind == .retired ? "pending deletion and " : chunk.kind == .view ? "log views, " : "") + "over the \(searchRequests) Logging requests one search sends"
                    if let gap = coverage.notSearched.firstIndex(where: { $0.reason == reason }) { coverage.notSearched[gap].resources += chunk.names }
                    else { coverage.notSearched.append(Gap(resources: chunk.names, reason: reason)) }
                    continue
                }
                let allowed = remaining - min(chunks.count - index - 1, remaining - 1)
                let found = await search(chunk.names, kind: chunk.kind, allowed: allowed)
                remaining -= found.calls
                searches.append(found)
            }
            let read = searches.filter { $0.error == nil }
            // Nothing could be read at all: say why, as there is nothing to keep.
            if read.isEmpty, let error = searches.first?.error { throw error }

            var entries: [Entry] = [], seen = Set<String>()
            for found in searches {
                if let error = found.error {
                    coverage.failed.append(Gap(resources: found.names, reason: (found.kind == .retired ? "pending deletion; " : "") + error.localizedDescription))
                    continue
                }
                for entry in found.entries {
                    guard let identity = entry.identity else { coverage.unmatched += 1; entries.append(entry); continue }
                    if !seen.insert(identity).inserted { coverage.duplicates += 1; continue }
                    entries.append(entry)
                }
                coverage.searched += found.names
                if found.kind == .retired { coverage.searchedPendingDeletion += found.names }
                if found.kind == .view { coverage.searchedViews += found.names }
                if let partial = found.partial {
                    // The boundary is inclusive, as until is, so entries sharing the oldest time read are not skipped.
                    let reason = found.entries.last?.timestamp.map { oldest in
                        "Logging failed partway (\(partial)), so entries at or before \(oldest) may be missing; search again with until \(oldest), which includes that moment, and drop entries repeated by insertId"
                    } ?? "Logging failed (\(partial)) before any entry came back, so nothing of the window was read; search the same window again"
                    coverage.partial.append(Gap(resources: found.names, reason: reason))
                } else if found.token != nil, found.entries.count >= limit {
                    coverage.more = true
                } else if found.token != nil {
                    coverage.unfinished += found.names
                }
                if let token = found.token {
                    coverage.continuations.append(Continuation(resourceNames: found.names, pageToken: token,
                        reason: found.partial != nil ? "a later page failed" : found.entries.count >= limit ? "the limit was reached" : "the pages or requests one search reads ran out"))
                }
            }
            let order: (Entry, Entry) -> Bool = { first, second in
                let a = ServiceAlert.time(first.timestamp) ?? .distantPast, b = ServiceAlert.time(second.timestamp) ?? .distantPast
                return a != b ? a > b : (first.timestamp ?? "") > (second.timestamp ?? "")
            }
            entries.sort(by: order)
            if entries.count > limit { coverage.more = true }
            let kept = Array(entries.prefix(limit))
            let failedCount = kept.filter(\.failed).count

            var lines: [String] = []
            let window = "from \(since) to \(until ?? "now")"
            let gaps = !coverage.notSearched.isEmpty || !coverage.failed.isEmpty || !coverage.partial.isEmpty || !coverage.unfinished.isEmpty || coverage.listing != nil
            if kept.isEmpty {
                lines.append(gaps ? "No audit log entries were found in what could be searched, \(window); see below for what was not."
                    : "No audit log entries match in \(GoogleCloud.described(coverage.searched)), \(window).")
            } else {
                lines += kept.prefix(shown).map { $0.line(own: own) }
                if kept.count > shown { lines.append("Showing \(shown) of the \(kept.count) entries kept; the structured result holds all of them.") }
                lines.append(failedCount == 0 ? "All \(kept.count) succeeded." : "\(kept.count - failedCount) succeeded and \(failedCount) failed, marked failed.")
            }
            if coverage.more {
                let oldest = kept.last?.timestamp ?? since
                lines.append("More entries match than the \(limit) kept: some at or before \(oldest) were not read or not kept; search again with until \(oldest), which includes that moment, dropping entries repeated by insertId, or narrow by principal, method, resource, IP, status, service or log.")
            }
            lines.append("Searched: \(GoogleCloud.described(coverage.searched)), \(window).")
            if !coverage.searchedViews.isEmpty { lines.append("Searched these log views too: \(GoogleCloud.listed(coverage.searchedViews)).") }
            if coverage.duplicates > 0 { lines.append("\(coverage.duplicates) entries came back from more than one of them, such as a project and a log view its logs are routed to, and are shown once.") }
            if coverage.unmatched > 0, !coverage.searchedViews.isEmpty {
                lines.append("\(coverage.unmatched) entries named no log or insertId, so one also returned by a log view could not be matched to its copy and may be shown twice.")
            }
            if !coverage.searchedPendingDeletion.isEmpty { lines.append("Searched, though pending deletion: \(GoogleCloud.described(coverage.searchedPendingDeletion)).") }
            for gap in coverage.notSearched { lines.append("Not searched, \(gap.reason): \(GoogleCloud.described(gap.resources)); set the account to a folder or narrow the search.") }
            for gap in coverage.failed { lines.append("Could not read: \(GoogleCloud.described(gap.resources)) (\(gap.reason)).") }
            for gap in coverage.partial { lines.append("Read only in part: \(GoogleCloud.described(gap.resources)): \(gap.reason).") }
            if !coverage.unfinished.isEmpty {
                lines.append("Logging did not finish searching the whole time window in \(GoogleCloud.described(coverage.unfinished)), so older entries may be missing; narrow it with since and until, or by principal, method or resource.")
            }
            if let listing = coverage.listing { lines.append(listing) }
            if kept.contains(where: { $0.protoPayload?.authenticationInfo?.serviceAccountKeyName != nil || $0.protoPayload?.authenticationInfo?.serviceAccountDelegationInfo?.isEmpty == false
                || $0.protoPayload?.authenticationInfo?.principalEmail?.hasSuffix(".gserviceaccount.com") == true }) {
                lines.append("The principal, key and delegation recorded are the credential used, not proof of who held it.")
            }
            if kept.isEmpty, logs.contains("data_access") {
                lines.append("Data Access audit logs, which record reads of data such as a bucket's objects, are off by default for every service but BigQuery, and reading them needs Private Logs Viewer: no reads found means unknown, not none, unless Data Access logging is known to be on for that service. logging-coverage says, for a service, whether each project logs data reads and data writes; check-access says whether this account can read them.")
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(entries: kept, coverage: coverage, filter: query, succeeded: kept.count - failedCount, failed: failedCount))
        }
    }

    struct Findings: ServiceOperation {
        struct Input: Decodable, Sendable { let severities: [String]?, category: String?, since: String?, limit: Int?, includeMuted: Bool? }
        static let name = "scc-findings"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Active Security Command Center findings, newest first, by severity, category and time, with their class, the resource each concerns, who acted and from where for threats, and how many matched in all; muted ones only when asked."
        static let input = JSONSchema.object([
            "severities": .array(.string("A severity.", oneOf: ["CRITICAL", "HIGH", "MEDIUM", "LOW"]), "Severities. Critical and high when left out."),
            "category": .string("A finding category, such as PUBLIC_BUCKET_ACL or Persistence: IAM Anomalous Grant."),
            "since": .string("The earliest time each was last seen, in ISO 8601."),
            "limit": .integer("How many findings, at most.", minimum: 1, maximum: 100),
            "includeMuted": .boolean("Include findings muted as accepted or known; left out when not given."),
        ])

        struct Access: Codable { let principalEmail: String?, principalSubject: String?, callerIp: String?, userAgent: String?, methodName: String?, serviceName: String? }
        struct Finding: Codable {
            let name: String?, category: String?, severity: String?, state: String?, eventTime: String?, createTime: String?, resourceName: String?
            let externalUri: String?, findingClass: String?, mute: String?, description: String?, access: Access?
        }
        struct Resource: Codable { let name: String?, displayName: String?, type: String? }
        struct Result: Codable { let finding: Finding?; let resource: Resource? }
        struct Answer: Codable { let listFindingsResults: [Result]?; let nextPageToken: String?; let totalSize: Int? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let severities = try (input.severities ?? ["CRITICAL", "HIGH"]).map { try ServiceInput.oneOf($0, ["CRITICAL", "HIGH", "MEDIUM", "LOW"], "severity") }
            let includeMuted = input.includeMuted ?? false
            // Google's own filter for findings nobody muted.
            var filter = [#"state="ACTIVE""#] + (includeMuted ? [] : [#"NOT mute="MUTED""#])
            filter.append("(" + severities.map { "severity=\"\($0)\"" }.joined(separator: " OR ") + ")")
            if let category = input.category { filter.append("category=" + (try GoogleCloud.quoted(category, "the category"))) }
            if let since = input.since { filter.append("event_time>=\"\(try ServiceInput.time(since))\"") }
            let limit = input.limit ?? 25
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 findings.") }
            let center = try service.at(host: "securitycenter.googleapis.com")
            var results: [Result] = [], token: String?, total: Int?, stopped: String?
            for page in 0..<findingPages {
                let answer: Answer
                do {
                    answer = try await GoogleCloud.read(.findings, own) {
                        try await center.get(["v2", scope.level, scope.id, "sources", "-", "findings"], query: [
                            "filter": filter.joined(separator: " AND "), "orderBy": "event_time desc",
                            "pageSize": String(limit - results.count), "pageToken": token,
                        ], as: Answer.self)
                    }
                } catch where page > 0 {
                    stopped = error.localizedDescription
                    break
                }
                results += answer.listFindingsResults ?? []
                total = answer.totalSize ?? total
                token = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
                if token == nil || results.count >= limit { break }
            }
            var lines: [String]
            if results.isEmpty {
                lines = ["No active \(GoogleCloud.listed(severities.map { $0.lowercased() })) findings\(input.category.map { " in \($0)" } ?? "")\(input.since.map { " since \($0)" } ?? "") at \(own)\(includeMuted ? "" : ", leaving out muted ones")."]
                if stopped == nil {
                    lines.append("Security Command Center finds only what its tier and services detect: threats need Event Threat Detection, of the Premium and Enterprise tiers. check-access lists the services that report here.")
                }
            } else {
                lines = results.map { result in
                    let finding = result.finding
                    var line = "\(finding?.eventTime ?? "?") \(finding?.severity ?? "?")\(finding?.findingClass.map { " \($0)" } ?? "") \(finding?.category ?? "?") — \(result.resource?.displayName ?? finding?.resourceName ?? "?")"
                    if finding?.mute == "MUTED" { line += ", muted" }
                    if let access = finding?.access, access.principalEmail != nil || access.callerIp != nil {
                        line += ";" + (access.principalEmail.map { " by \($0)" } ?? "") + (access.callerIp.map { " from \($0)" } ?? "")
                            + (access.methodName.map { " calling \($0)" } ?? "")
                    }
                    if let uri = finding?.externalUri { line += " (\(uri))" }
                    if let name = finding?.name { line += " [\(name)]" }
                    return line
                }
            }
            let more = token != nil || (total.map { $0 > results.count } ?? false)
            if more {
                lines.append("Showing \(results.count)\(total.map { " of the \($0)" } ?? "") matching findings; more exist: narrow by category or since, or raise limit up to 100.")
            } else if let total, !results.isEmpty {
                lines.append("All \(total) matching findings are shown.")
            }
            if let stopped { lines.append("Read only in part: a later page could not be read (\(stopped)).") }
            if !includeMuted { lines.append("Muted findings are left out; set includeMuted to see them.") }
            struct Kept: Encodable {
                let listFindingsResults: [Result]; let totalSize: Int?; let more: Bool; let nextPageToken: String?; let mutedLeftOut: Bool; let filter: String
                let stopped: String?
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(listFindingsResults: results, totalSize: total, more: more, nextPageToken: token,
                                                                                    mutedLeftOut: !includeMuted, filter: filter.joined(separator: " AND "), stopped: stopped))
        }
    }

    struct IAMPolicies: ServiceOperation {
        struct Input: Decodable, Sendable { let member: String?, resource: String?, role: String? }
        static let name = "iam-policies"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Who can do what on which resource across the scope, under IAM allow policies: for a member, including access through groups, or for a resource, with each binding's condition and what the analysis could not cover."
        static let input = JSONSchema.object([
            "member": .string("A user's, group's or service account's email, or a principal such as group:admins@example.com, to find every role it holds. A bare email is checked as a user, then as a group when that finds nothing."),
            "resource": .string("A full resource name instead, such as //cloudresourcemanager.googleapis.com/projects/my-project, to find who has access to it."),
            "role": .string("Only this role, such as roles/owner."),
        ])

        struct Expr: Codable { let title: String?, expression: String? }
        struct Binding: Codable { let role: String?; let members: [String]?; let condition: Expr? }
        struct Named: Codable { let name: String? }
        struct Identities: Codable { let identities: [Named]? }
        struct Evaluation: Codable { let evaluationValue: String? }
        struct Control: Codable { let conditionEvaluation: Evaluation? }
        struct Result: Codable {
            let attachedResourceFullName: String?, iamBinding: Binding?, identityList: Identities?, accessControlLists: [Control]?, fullyExplored: Bool?
        }
        struct Problem: Codable { let code: String?, cause: String? }
        struct Analysis: Codable { let analysisResults: [Result]?; let fullyExplored: Bool?; let nonCriticalErrors: [Problem]? }
        struct Answer: Codable { let mainAnalysis: Analysis?; let fullyExplored: Bool? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            guard input.member != nil || input.resource != nil else { throw ServiceError.input("Give a member or a resource.") }
            var query: [String: String?] = [:]
            // The principals to ask about in turn, the next only when the one before has no access.
            var identities: [String] = []
            if let member = input.member {
                let value = try ServiceInput.quoted(member.trimmingCharacters(in: .whitespaces), "the member")
                // A bare email is a person's, a group's, or a service account's when it ends as theirs do. Groups the
                // member belongs to are analysed with it; Google takes no group expansion alongside a member.
                if value.contains(":") { identities = [value] }
                else if value.lowercased().hasSuffix(".gserviceaccount.com") { identities = ["serviceAccount:" + value.lowercased()] }
                else { identities = ["user:" + value.lowercased(), "group:" + value.lowercased()] }
            }
            if let resource = input.resource {
                let value = try ServiceInput.quoted(resource.trimmingCharacters(in: .whitespaces), "the resource")
                guard value.hasPrefix("//") else { throw ServiceError.input("Give the resource's full name, such as //cloudresourcemanager.googleapis.com/projects/my-project.") }
                query["analysisQuery.resourceSelector.fullResourceName"] = value
            }
            if let role = input.role {
                let value = try ServiceInput.quoted(role.trimmingCharacters(in: .whitespaces), "the role")
                guard value.hasPrefix("roles/") || value.contains("/roles/") else { throw ServiceError.input("Give the role as roles/owner or a custom role's name.") }
                query["analysisQuery.accessSelector.roles"] = value
            }
            let assets = try service.at(host: "cloudasset.googleapis.com")
            func analyse(_ identity: String?) async throws -> Answer {
                var asked = query
                if let identity { asked["analysisQuery.identitySelector.identity"] = identity }
                return try await GoogleCloud.read(.analysis, own) {
                    try await assets.get(["v1", scope.level, "\(scope.id):analyzeIamPolicy"], query: asked, as: Answer.self)
                }
            }
            var answer = try await analyse(identities.first)
            var checked = Array(identities.prefix(1)), notes: [String] = []
            if (answer.mainAnalysis?.analysisResults ?? []).isEmpty, identities.count > 1 {
                do {
                    let group = try await analyse(identities[1])
                    checked.append(identities[1])
                    if !(group.mainAnalysis?.analysisResults ?? []).isEmpty {
                        notes.append("\(identities[0]) has no access, so this is \(identities[1]).")
                    }
                    answer = group
                } catch {
                    notes.append("It was checked as \(identities[0]) only; as \(identities[1]) it could not be: \(error.localizedDescription)")
                }
            }
            let analysis = answer.mainAnalysis
            let results = analysis?.analysisResults ?? []
            let (retired, retiredNote) = results.isEmpty ? ([:], nil) : await GoogleCloud.retiredProjects(service, scope)
            var lines: [String] = []
            if results.isEmpty {
                let whom = checked.isEmpty ? "" : " for \(checked.joined(separator: " or "))"
                lines.append("No access matches\(whom)\(input.role.map { " with \($0)" } ?? "")\(input.resource.map { " on \($0)" } ?? "") across \(own).")
            } else {
                lines += results.prefix(shown).map { result in
                    let members = result.iamBinding?.members ?? [], who = (result.identityList?.identities ?? []).compactMap(\.name)
                    let state = result.attachedResourceFullName.flatMap(GoogleCloud.project(in:)).flatMap { retired[$0] }
                    var line = "\(result.attachedResourceFullName ?? "?")\(state.map { " (project \($0))" } ?? ""): \(result.iamBinding?.role ?? "?") to "
                        + members.prefix(5).joined(separator: ", ") + (members.count > 5 ? " (+\(members.count - 5) more)" : "")
                    if !who.isEmpty { line += " (reaching \(who.prefix(5).joined(separator: ", "))\(who.count > 5 ? " +\(who.count - 5) more" : ""))" }
                    if let condition = result.iamBinding?.condition {
                        let evaluated = result.accessControlLists?.compactMap { $0.conditionEvaluation?.evaluationValue }.first
                        line += " — only when \(condition.title ?? condition.expression ?? "a condition holds")\(evaluated.map { " (\($0.lowercased()))" } ?? "")"
                    }
                    if result.fullyExplored == false { line += " — not fully analysed" }
                    return line
                }
                if results.count > shown { lines.append("Showing \(shown) of \(results.count) results, each naming up to 5 members and 5 identities; the structured result holds all of them.") }
            }
            lines += notes
            if answer.fullyExplored == false || analysis?.fullyExplored == false { lines.append("The analysis was not complete; narrow it to a resource or a role.") }
            let problems = analysis?.nonCriticalErrors ?? []
            if !problems.isEmpty {
                lines.append("Google could not analyse all of it: " + problems.prefix(5).map { "\($0.code ?? "?")\($0.cause.map { ": \($0)" } ?? "")" }.joined(separator: "; ")
                             + ". Access through groups needs Groups Reader in Google Workspace and custom roles need Role Viewer, so what they grant may be missing here.")
                if problems.contains(where: { $0.code == "DEADLINE_EXCEEDED" }), let timeout = Need.analysis.timeout { lines.append(timeout) }
            }
            if let retiredNote { lines.append(retiredNote) }
            lines.append("These are IAM allow policies only: deny policies, which can block what they grant, are not evaluated.")
            struct Kept: Encodable { let results: [Result]; let checkedAs: [String]; let fullyExplored: Bool; let nonCriticalErrors: [Problem] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                results: results, checkedAs: checked, fullyExplored: answer.fullyExplored != false && analysis?.fullyExplored != false, nonCriticalErrors: problems))
        }
    }

    struct FindResources: ServiceOperation {
        struct Input: Decodable, Sendable { let assetTypes: [String], name: String?, createdSince: String?, location: String? }
        static let name = "find-resources"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Resources of the given types across the scope, with where each is and its state, optionally only those whose name contains a word, made since a time or in a location, such as VMs made lately in an unusual region, saying when more exist than were read."
        static let input = JSONSchema.object([
            "assetTypes": .array(.string("An asset type, such as compute.googleapis.com/Instance or storage.googleapis.com/Bucket."), "The types to list, up to 20."),
            "name": .string("Only resources whose name contains this, such as web-01."),
            "createdSince": .string("Only resources made at or after this time, in ISO 8601; those whose type records no creation time are left out and counted."),
            "location": .string("Only resources in this location, such as us-central1, which takes its zones too, or a zone such as us-central1-a."),
        ], required: ["assetTypes"])

        /// The most resources the structured result keeps.
        static let kept = 100

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            guard !input.assetTypes.isEmpty else { throw ServiceError.input("Give at least one asset type, such as compute.googleapis.com/Instance.") }
            let types = try ServiceInput.list(input.assetTypes, limit: 20) { try ServiceInput.quoted($0, "the asset type") }
            let word = input.name?.trimmingCharacters(in: .whitespaces).lowercased()
            let createdSince = try input.createdSince.map { try ServiceInput.time($0) }
            let since = createdSince.flatMap(ServiceAlert.time)
            let place = try input.location.map { try ServiceInput.quoted($0, "the location").lowercased() }
            /// When a Kubernetes-style resource, such as a Cloud Run service of the first version, was made.
            struct Made: Codable { let creationTimestamp: String? }
            /// A resource's own name, state and creation time, under whichever names its type uses, read leniently since
            /// types differ: a project gives its ID, name, lifecycle state and createTime; an instance its name, status
            /// and creationTimestamp; a bucket its timeCreated; a BigQuery dataset its creationTime in milliseconds.
            struct State: Codable {
                let projectId: String?, name: String?, displayName: String?, status: String?, state: String?, lifecycleState: String?
                let creationTimestamp: String?, timeCreated: String?, createTime: String?, creationTime: String?, metadata: Made?
                init(from decoder: Decoder) throws {
                    let fields = try? decoder.container(keyedBy: CodingKeys.self)
                    func text(_ key: CodingKeys) -> String? { try? fields?.decode(String.self, forKey: key) }
                    projectId = text(.projectId); name = text(.name); displayName = text(.displayName)
                    status = text(.status); state = text(.state); lifecycleState = text(.lifecycleState)
                    creationTimestamp = text(.creationTimestamp); timeCreated = text(.timeCreated); createTime = text(.createTime)
                    creationTime = text(.creationTime) ?? (try? fields?.decode(Double.self, forKey: .creationTime)).map { String(Int64($0)) }
                    metadata = try? fields?.decode(Made.self, forKey: .metadata)
                }
                /// When it was made, from whichever field its type records it in.
                var created: Date? {
                    if let time = [creationTimestamp, timeCreated, createTime, metadata?.creationTimestamp].compactMap({ $0 }).first { return ServiceAlert.time(time) }
                    return creationTime.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                }
                /// What it is called, without repeating the end of its address.
                func called(_ short: String) -> String {
                    let names = [projectId, name, displayName].compactMap { $0 }.filter { $0 != short }
                    var seen = Set<String>()
                    return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
                }
            }
            struct Details: Codable { let location: String?; let data: State? }
            struct Asset: Codable { let name: String?; let assetType: String?; let resource: Details?; var ancestors: [String]? = nil }
            struct Answer: Codable { let assets: [Asset]?; let nextPageToken: String? }
            func short(_ asset: Asset) -> String { (asset.name ?? "?").split(separator: "/").last.map(String.init) ?? "?" }
            func label(_ asset: Asset) -> String {
                let called = asset.resource?.data?.called(short(asset)) ?? ""
                // A project's address ends in its number, which says less than its ID and name.
                return called.isEmpty ? short(asset) : asset.assetType == projectType ? called : "\(short(asset)), \(called)"
            }
            // Page after page, matching each by name here as Cloud Asset's listing takes no name, until enough are kept.
            let assets = try service.at(host: "cloudasset.googleapis.com")
            var matching: [Asset] = [], read = 0, pages = 0, token: String?, stopped: String?, undated = 0
            func matches(_ asset: Asset) -> Bool {
                if let word, word.isEmpty || !((asset.name ?? "") + " " + label(asset)).lowercased().contains(word) { return false }
                // A region takes its zones, such as us-central1-a in us-central1.
                if let place, !(asset.resource?.location.map { $0.lowercased() == place || $0.lowercased().hasPrefix(place + "-") } ?? false) { return false }
                if let since {
                    guard let made = asset.resource?.data?.created else { undated += 1; return false }
                    return made >= since
                }
                return true
            }
            repeat {
                let answer: Answer
                do {
                    answer = try await GoogleCloud.read(.assets, own) {
                        try await assets.get(["v1", scope.level, scope.id, "assets"], query: [
                            "contentType": "RESOURCE", "pageSize": "1000", "pageToken": token,
                        ], repeated: ["assetTypes": types], as: Answer.self)
                    }
                } catch where pages > 0 {
                    stopped = error.localizedDescription
                    break
                }
                pages += 1
                read += answer.assets?.count ?? 0
                matching += (answer.assets ?? []).filter(matches)
                token = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && pages < resourcePages && matching.count < Self.kept
            let (retired, retiredNote) = matching.isEmpty ? ([:], nil) : await GoogleCloud.retiredProjects(service, scope)
            var lines: [String]
            if matching.isEmpty {
                let narrowed = [word.map { "whose name contains \($0)" }, place.map { "in \($0)" }, createdSince.map { "made since \($0)" }].compactMap { $0 }
                lines = ["No resource of these types\(narrowed.isEmpty ? "" : " " + GoogleCloud.listed(narrowed)) among the \(read) read in \(own)."]
            } else {
                lines = matching.prefix(shown).map { asset in
                    let data = asset.resource?.data
                    let state = data?.status ?? data?.state ?? data?.lifecycleState
                    // A project's own state says it already; what sits in one pending deletion says so too.
                    let home = asset.assetType == projectType ? nil
                        : (asset.ancestors?.first.flatMap(GoogleCloud.project(in:)) ?? asset.name.flatMap(GoogleCloud.project(in:))).flatMap { retired[$0] }
                    let made = since == nil ? nil : [data?.creationTimestamp, data?.timeCreated, data?.createTime, data?.metadata?.creationTimestamp].compactMap { $0 }.first
                        ?? data?.created.map { ISO8601DateFormatter().string(from: $0) }
                    return "\(label(asset)) (\(asset.assetType ?? "?"))\(asset.resource?.location.map { " in \($0)" } ?? "")\(state.map { ", \($0)" } ?? "")"
                        + (made.map { ", made \($0)" } ?? "") + (home.map { ", in a project \($0)" } ?? "")
                }
                if matching.count > shown {
                    lines.append("Showing \(shown) of the \(min(matching.count, Self.kept)) kept; the structured result holds up to \(Self.kept).")
                }
            }
            if token != nil {
                lines.append(matching.count >= Self.kept
                    ? "More may match: reading stopped once \(Self.kept) were found; narrow by name or type."
                    : "More may match: only the first \(read) resources were read, the most one search reads; narrow by name or type, or set the account to a folder or project.")
            }
            if let stopped { lines.append("Read only in part: a later page could not be read (\(stopped)).") }
            if undated > 0 {
                lines.append("\(undated) of the resources read record no creation time Cloud Asset shows, so whether they were made since \(createdSince ?? "then") is unknown and they were left out; audit-logs shows what was made, such as method compute.instances.insert.")
            }
            if let retiredNote { lines.append(retiredNote) }
            struct Kept: Encodable { let resources: [Asset]; let read: Int; let more: Bool; let stopped: String?; let undated: Int }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(resources: Array(matching.prefix(Self.kept)), read: read,
                                                                                    more: token != nil, stopped: stopped, undated: undated))
        }
    }

    /// Tries each thing Google Cloud Detection reads once, with the smallest request it takes, and says how to fix what it
    /// cannot. It changes nothing: asking which permissions the sign-in holds changes nothing either.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly what to change: a scope, an API, a role or Security Command Center's activation; whether Data Access logs can be read; which Security Command Center services report here; and whether the account signed in could change findings. It changes nothing; its IAM check counts as one of the organisation's daily analyses. Run it when a tool is refused."
        static let input = JSONSchema.object([:])

        /// Why the sign-in only reads: Google's scopes for the two APIs do not keep it to reading, the account's roles do.
        static let readOnlyByRoles = "· Cloud Asset Inventory and Security Command Center offer no read-only scope, so only the account's viewer roles keep this sign-in to reading: an account that could also make, change or delete Cloud Asset feeds, or mute or change findings, would let this sign-in do the same. Keep the account to the viewer roles in Setup Steps. This check cannot ask Google about Cloud Asset's permissions."

        /// The permissions that change findings, which no viewer role holds.
        static let writes = ["securitycenter.findings.setMute", "securitycenter.findings.bulkMuteUpdate", "securitycenter.findings.setState",
                             "securitycenter.findings.update", "securitycenter.muteconfigs.create", "securitycenter.findingsecuritymarks.update"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let logging = try service.at(host: "logging.googleapis.com"), assets = try service.at(host: "cloudasset.googleapis.com")
            let center = try service.at(host: "securitycenter.googleapis.com")
            let month = "timestamp>=\"\(ServiceInput.daysAgo(30))\""
            struct Body: Encodable { let resourceNames: [String], filter: String, orderBy: String, pageSize: Int }
            struct Entries: Decodable { let entries: [AuditLogs.Entry]? }
            func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ \(need.title)" }
                catch { return "✗ \(need.title): " + (GoogleCloud.fix(for: error, need, on: own) ?? error.localizedDescription) }
            }
            var lines = [await check(.logs) {
                _ = try await logging.post(["v2", "entries:list"], body: Body(resourceNames: [own], filter: #"log_id("cloudaudit.googleapis.com/activity") AND "# + month,
                                                                            orderBy: "timestamp desc", pageSize: 1), as: Entries.self)
            }]
            // Logging may leave out logs the account cannot see rather than refuse, so only an entry proves they can be read.
            do {
                let found = try await logging.post(["v2", "entries:list"], body: Body(resourceNames: [own], filter: #"log_id("cloudaudit.googleapis.com/data_access") AND "# + month,
                                                                                    orderBy: "timestamp desc", pageSize: 1), as: Entries.self).entries ?? []
                lines.append(found.isEmpty
                    ? "· \(Need.dataAccess.title): none came back from \(own)'s own logs in the last 30 days, so whether they can be read is not established: Data Access logging may be off there, as it is by default for every service but BigQuery, or the account may lack \(Need.dataAccess.role). Until one comes back, no data reads found means unknown."
                    : "✓ \(Need.dataAccess.title): readable; one came back from the last 30 days.")
            } catch {
                lines.append("✗ \(Need.dataAccess.title): " + (GoogleCloud.fix(for: error, .dataAccess, on: own) ?? error.localizedDescription))
            }
            lines.append(await check(.assets) {
                _ = try await assets.data(["v1", scope.level, scope.id, "assets"], query: ["contentType": "RESOURCE", "pageSize": "1"])
            })
            lines.append(await check(.analysis) {
                _ = try await assets.data(["v1", scope.level, "\(scope.id):analyzeIamPolicy"], query: [
                    "analysisQuery.resourceSelector.fullResourceName": "//cloudresourcemanager.googleapis.com/\(own)",
                    "analysisQuery.accessSelector.roles": "roles/owner",
                ])
            })
            lines.append(await check(.findings) {
                _ = try await center.data(["v2", scope.level, scope.id, "sources", "-", "findings"], query: ["filter": #"state="ACTIVE""#, "pageSize": "1"])
            })
            // The services that report findings here say what the tier detects; each organisation source's permissions
            // say whether the account could change its findings, as the Security Command Center scope lets it do what it
            // may. Sources are read page by page, and each asked about in turn, within a budget said when it runs out.
            struct Source: Decodable { let name: String?; let displayName: String? }
            struct Sources: Decodable { let sources: [Source]?; let nextPageToken: String? }
            do {
                var sources: [Source] = [], token: String?, pages = 0, stopped: String?
                repeat {
                    do {
                        let page = try await center.get(["v2", scope.level, scope.id, "sources"], query: ["pageSize": "100", "pageToken": token], as: Sources.self)
                        sources += page.sources ?? []
                        token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
                        pages += 1
                    } catch where pages > 0 {
                        stopped = error.localizedDescription
                        break
                    }
                } while token != nil && pages < sourcePages
                let whole = token == nil && stopped == nil
                let names = sources.compactMap(\.displayName)
                let read = "the \(sources.count) sources read" + (whole ? "" : stopped.map { ", as a later page could not be read (\($0))" } ?? ", as more than \(sourcePages) pages of them exist")
                lines.append(names.isEmpty ? "· Security Command Center services: none report findings here\(whole ? "" : " among \(read)")."
                    : "· Security Command Center services reporting here: \(names.joined(separator: ", "))\(whole ? "" : ", among \(read)").")
                if !names.contains(where: { $0.localizedCaseInsensitiveContains("Event Threat Detection") }) {
                    lines.append(whole
                        ? "· Event Threat Detection is not among them, so no threat findings, such as an anomalous grant or a leaked key used, will appear: it comes with the Premium and Enterprise tiers."
                        : "· Event Threat Detection was not seen among \(read), so whether threat findings will appear is unknown: it comes with the Premium and Enterprise tiers.")
                }
                let organisation = sources.compactMap(\.name).filter { $0.hasPrefix("organizations/") && $0.split(separator: "/").count == 4 }
                struct Permissions: Codable { let permissions: [String]? }
                var held: [(source: String, permissions: [String])] = [], tested: [String] = [], failed: [String] = []
                for source in organisation.prefix(sourceChecks) {
                    let parts = source.split(separator: "/").map(String.init)
                    do {
                        let permissions = try await center.post(["v2", parts[0], parts[1], parts[2], "\(parts[3]):testIamPermissions"],
                                                                body: Permissions(permissions: Self.writes), as: Permissions.self).permissions ?? []
                        tested.append(source)
                        if !permissions.isEmpty { held.append((source, permissions)) }
                    } catch {
                        failed.append(source)
                    }
                }
                let untested = organisation.count - tested.count - failed.count
                let asked = "asked of \(GoogleCloud.described(tested)) for \(Self.writes.joined(separator: ", "))"
                if !held.isEmpty {
                    lines.append("⚠ The account signed in can change findings: " + held.map { "on \($0.source) it holds \($0.permissions.joined(separator: ", "))" }.joined(separator: "; ")
                                 + ". Security Command Center has no read-only scope, so this sign-in could do the same; sign in instead with an account holding only Security Center Findings Viewer.")
                } else if organisation.isEmpty {
                    lines.append("· Whether the account can mute or change findings: not checked, as no organisation's source was listed\(whole ? "" : " among \(read)").")
                } else if whole, untested == 0, failed.isEmpty {
                    lines.append("✓ The account signed in cannot mute or change findings: none of \(Self.writes.count) permissions is held on any of the organisation's \(tested.count) sources (\(asked); a role given on one project alone does not show here).")
                } else {
                    let unknown = [failed.isEmpty ? nil : "\(failed.count) could not be asked (\(GoogleCloud.described(failed)))",
                                   untested > 0 ? "\(untested) were not asked, over the \(sourceChecks) one check asks" : nil,
                                   whole ? nil : "sources past \(read) were not listed"].compactMap { $0 }
                    lines.append("· Whether the account can mute or change findings is unknown for some sources: none of the \(tested.count) asked grants it (\(asked)), but \(GoogleCloud.listed(unknown)).")
                }
            } catch {
                lines.append("· Security Command Center services and whether the account can change findings: not checked: "
                             + (GoogleCloud.fix(for: error, .findings, on: own) ?? error.localizedDescription))
            }
            lines.append(Self.readOnlyByRoles)
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
