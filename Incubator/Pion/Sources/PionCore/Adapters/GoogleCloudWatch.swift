import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Google Cloud Detection's alert watch, and security-events, which reads back what woke the agents: two feeds read the
/// same way for both. Security Command Center's high and critical findings, for organisations that have it, and the
/// Admin Activity audit logs of the scope, its folders and its projects, which Google writes for every organisation,
/// always and for free, for the changes that open the way in, hide what happens next or stay: keys made, powerful or
/// public grants, logging turned off, policies and firewalls loosened, SSH keys planted, projects deleted and VMs
/// made with GPUs or in numbers.
extension GoogleCloud {
    // MARK: Watched events

    /// One thing the watch wakes the agents for, from either feed.
    struct WatchedEvent: Codable, Sendable {
        /// What tells it from the rest: a finding's name, or audit/ and an entry's log, insertId and time.
        let id: String
        let time: String
        /// The turn it takes when more are found than one check keeps, 0 first: takeover and evasion, then exposure and
        /// loosened guardrails, then abuse of what was made.
        let tier: Int
        /// What it is, such as service account key made; events of one kind take one turn between them.
        let kind: String
        /// Which feed found it: scc or audit-logs.
        let feed: String
        let line: String
        /// Where an audit entry was logged, such as projects/kestrel-prod, so it can be searched for again.
        var origin: String? = nil

        var date: Date { ServiceAlert.time(time) ?? .distantPast }
    }

    /// At most `most` of `events`, newest first, taken in turn from each kind, the lower tiers' first in each round, so a
    /// burst of one kind, such as hundreds of misconfiguration findings or service accounts made, cannot crowd out a
    /// threat or a key made.
    static func inTurn(_ events: [WatchedEvent], most: Int) -> [WatchedEvent] {
        let newest = { (first: WatchedEvent, second: WatchedEvent) in first.date != second.date ? first.date > second.date : first.id < second.id }
        guard events.count > most, most > 0 else { return Array(events.sorted(by: newest).prefix(max(most, 0))) }
        var queues = Dictionary(grouping: events.sorted(by: newest)) { $0.kind }
            .sorted { ($0.value.map(\.tier).min() ?? 9, $0.key) < ($1.value.map(\.tier).min() ?? 9, $1.key) }.map { $0.value[...] }
        var kept: [WatchedEvent] = []
        while kept.count < most {
            for index in queues.indices where kept.count < most {
                if let event = queues[index].popFirst() { kept.append(event) }
            }
        }
        return kept.sorted(by: newest)
    }

    // MARK: Security Command Center

    /// The most pages of findings each of the watch's two reads takes, of 500 each: a thousand new findings of one
    /// severity in six hours is already a flood, and four requests a check is far inside Security Command Center's quota.
    static let watchFindingPages = 2
    /// The classes whose findings take their turn first: an attack seen, or a path to one put together from several.
    static let threatClasses = ["THREAT", "TOXIC_COMBINATION"]

    /// What one read of the findings found, and why it stopped short when it did.
    struct FindingsRead { var events: [WatchedEvent] = [], error: Error? = nil, cut = false }

    /// Active, unmuted, high and critical findings created or seen again in the window, read as two, critical first, so
    /// a flood of high misconfigurations cannot fill the pages a critical finding needs; threats and toxic combinations
    /// then take their turn first here. The filter names only fields Google's guide to listing findings shows, mute and
    /// create_time among them (https://docs.cloud.google.com/security-command-center/docs/how-to-api-list-findings):
    /// the finding class is not among them, so it is not filtered on. A finding is taken by when it was created, which
    /// is when it reached Security Command Center, or when it was last seen, whichever is later: a finding a source
    /// writes late, with an older event time, is still found within the six hours the watch reads back, and the later
    /// time keeps it among those seen.
    static func readFindings(_ service: ServiceClient, _ scope: (level: String, id: String), since: String, until: String?) async -> FindingsRead {
        let own = "\(scope.level)/\(scope.id)"
        let window = until.map { #"((create_time>="\#(since)" AND create_time<="\#($0)") OR (event_time>="\#(since)" AND event_time<="\#($0)"))"# }
            ?? #"(create_time>="\#(since)" OR event_time>="\#(since)")"#
        let base = #"state="ACTIVE" AND NOT mute="MUTED" AND "# + window
        let first = base + #" AND severity="CRITICAL""#, rest = base + #" AND severity="HIGH""#
        var read = FindingsRead(), seen = Set<String>()
        do {
            let center = try service.at(host: "securitycenter.googleapis.com")
            for filter in [first, rest] {
                var token: String?
                for page in 0..<watchFindingPages {
                    let answer: Findings.Answer
                    do {
                        answer = try await GoogleCloud.read(.findings, own) {
                            try await center.get(["v2", scope.level, scope.id, "sources", "-", "findings"], query: [
                                "filter": filter, "orderBy": "event_time desc", "pageSize": String(ServiceAlert.most), "pageToken": token,
                            ], as: Findings.Answer.self)
                        }
                    } catch where page > 0 {
                        // A later page that fails keeps what was read, said to be cut short.
                        read.cut = true
                        token = nil
                        break
                    }
                    for result in answer.listFindingsResults ?? [] {
                        guard let finding = result.finding, let name = finding.name, finding.mute != "MUTED", seen.insert(name).inserted else { continue }
                        let times = [finding.createTime, finding.eventTime].compactMap { $0 }
                        guard let time = times.max(by: { (ServiceAlert.time($0) ?? .distantPast) < (ServiceAlert.time($1) ?? .distantPast) }) else { continue }
                        let threat = threatClasses.contains(finding.findingClass ?? "")
                        let tier = threat ? 0 : finding.severity == "CRITICAL" ? 1 : 2
                        var line = "\(time) \(finding.severity ?? "?")\(finding.findingClass.map { " \($0)" } ?? "") finding \(finding.category ?? "?") — \(result.resource?.displayName ?? finding.resourceName ?? "?")"
                        if let access = finding.access, access.principalEmail != nil || access.callerIp != nil {
                            line += ";" + (access.principalEmail.map { " by \($0)" } ?? "") + (access.callerIp.map { " from \($0)" } ?? "") + (access.methodName.map { " calling \($0)" } ?? "")
                        }
                        if let created = finding.createTime, let event = finding.eventTime, created != event { line += " (first seen \(event), reached Security Command Center \(created))" }
                        line += " [\(name)]"
                        read.events.append(WatchedEvent(id: name, time: time, tier: tier, kind: "scc/\(tier)/\(finding.findingClass ?? "?")/\(finding.category ?? "?")", feed: "scc", line: line))
                    }
                    token = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
                    if token == nil { break }
                }
                if token != nil { read.cut = true }
            }
        } catch {
            read.error = error
        }
        return read
    }

    // MARK: Admin Activity audit logs

    /// The most Logging requests one check of the watch sends: Logging allows 60 searches a minute for the project
    /// Pion's requests count against and the watch checks every five minutes, so ten leaves most of a minute's for
    /// investigations, whose searches send up to 20 each.
    static let watchRequests = 10
    /// Of those, how many are kept for reading on past a first page, so a busy search is not cut short only because
    /// many resources are watched: the rest read one search of up to 100 resources each.
    static let readOnReserve = 2
    /// How long the folders and projects listed are watched before they are listed again: half an hour, so a project
    /// made by an attacker joins the watch well within the six hours each check reads back.
    static let relisting: TimeInterval = 1_800
    /// How many VMs one account makes in the window read before each counts: a few at a time is ordinary, twenty is
    /// mining or a stolen key's spree. Google's own service agents, which make the VMs of managed instance groups and
    /// GKE's nodes, are not counted.
    static let manyVMs = 20

    static let keyMethods = ["google.iam.admin.v1.CreateServiceAccountKey": "service account key made",
                             "google.iam.admin.v1.UploadServiceAccountKey": "service account key uploaded"]
    static let loggingMethods = ["google.logging.v2.ConfigServiceV2.DeleteSink": "log sink deleted", "google.logging.v2.ConfigServiceV2.UpdateSink": "log sink changed",
                                 "google.logging.v2.ConfigServiceV2.CreateExclusion": "log exclusion made", "google.logging.v2.ConfigServiceV2.UpdateExclusion": "log exclusion changed",
                                 "google.logging.v2.ConfigServiceV2.DeleteBucket": "log bucket deleted"]
    static let bucketUpdate = "google.logging.v2.ConfigServiceV2.UpdateBucket"
    static let identityPoolMethods = ["v1", "v1beta"].reduce(into: [String: String]()) { methods, version in
        let prefix = "google.iam.\(version).WorkloadIdentityPools."
        methods[prefix + "CreateWorkloadIdentityPool"] = "workload identity pool made"
        methods[prefix + "UpdateWorkloadIdentityPool"] = "workload identity pool changed"
        methods[prefix + "CreateWorkloadIdentityPoolProvider"] = "workload identity provider made"
        methods[prefix + "UpdateWorkloadIdentityPoolProvider"] = "workload identity provider changed"
    }
    static let orgPolicyMethods = ["google.cloud.orgpolicy.v2.OrgPolicy.CreatePolicy", "google.cloud.orgpolicy.v2.OrgPolicy.UpdatePolicy",
                                   "google.cloud.orgpolicy.v2.OrgPolicy.DeletePolicy"]
    /// Org Policy's first form, served by Resource Manager, whose logged method names Google shows only as REST
    /// calls, setOrgPolicy and clearOrgPolicy, and a project's deletion, which it shows only matched by part of its
    /// name: each is matched by part of its name, which Logging compares ignoring case.
    static let orgPolicyV1 = ["SetOrgPolicy", "ClearOrgPolicy"], projectDeletion = "DeleteProject"
    static let firewallMethods = ["v1.compute.firewalls.insert", "v1.compute.firewalls.patch", "v1.compute.firewalls.update",
                                  "beta.compute.firewalls.insert", "beta.compute.firewalls.patch", "beta.compute.firewalls.update"]
    static let projectMetadataMethods = ["v1.compute.projects.setCommonInstanceMetadata", "beta.compute.projects.setCommonInstanceMetadata"]
    static let instanceMetadataMethods = ["v1.compute.instances.setMetadata", "beta.compute.instances.setMetadata"]
    static let insertMethods = ["v1.compute.instances.insert", "beta.compute.instances.insert"]
    static let bulkInsertMethods = ["v1.compute.instances.bulkInsert", "beta.compute.instances.bulkInsert"]
    static let newAccount = "google.iam.admin.v1.CreateServiceAccount"
    /// A service account's IAM policy set, which IAM may log with the policy whole rather than what changed.
    static let serviceAccountPolicy = "google.iam.admin.v1.SetIAMPolicy"
    static let keyVersionMethods = ["DestroyCryptoKeyVersion", "UpdateCryptoKeyVersion"]
    /// Roles that hand over a scope or a service account: everything, every change, minting its tokens, making its keys,
    /// running the organisation, or setting its IAM policies.
    static let watchedRoles: Set<String> = ["roles/owner", "roles/editor", "roles/iam.serviceAccountTokenCreator", "roles/iam.serviceAccountKeyAdmin",
                                            "roles/resourcemanager.organizationAdmin", "roles/iam.securityAdmin"]
    /// Services whose resources hold data, where a public grant exposes it rather than handing over control.
    static let dataServices: Set<String> = ["storage.googleapis.com", "bigquery.googleapis.com"]
    /// Where Google's own service agents act from: the Google APIs service agent, which managed instance groups and
    /// GKE make VMs as.
    static let serviceAgentDomain = "cloudservices.gserviceaccount.com"

    /// The watched methods, as a Logging filter of the Admin Activity log: each named exactly, which Logging finds by
    /// index, except IAM policy changes, which every service names its own way, and Resource Manager's, which are
    /// matched by part of their name; and VMs made, taken only with GPUs or by someone other than Google's service
    /// agents. Only entries that did not fail; what each did is checked here. Each name is as Google's audit logging
    /// pages for IAM, Logging, Org Policy, Compute Engine, Cloud Storage and Cloud KMS give it.
    static func watchFilter(since: String, until: String?) -> String {
        let exact = Array(keyMethods.keys) + Array(loggingMethods.keys) + [bucketUpdate] + Array(identityPoolMethods.keys) + orgPolicyMethods
            + firewallMethods + projectMetadataMethods + instanceMetadataMethods + bulkInsertMethods + [newAccount] + keyVersionMethods
        let named = "protoPayload.methodName=(" + exact.sorted().map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
        let partly = (["SetIamPolicy", projectDeletion] + orgPolicyV1).map { #"protoPayload.methodName:"\#($0)""# }.joined(separator: " OR ")
        let policies = partly + #" OR protoPayload.methodName="storage.setIamPermissions""#
        let inserts = "(protoPayload.methodName=(" + insertMethods.map { "\"\($0)\"" }.joined(separator: " OR ")
            + #") AND (protoPayload.request.guestAccelerators:* OR NOT protoPayload.authenticationInfo.principalEmail:"\#(serviceAgentDomain)"))"#
        var parts = [#"log_id("cloudaudit.googleapis.com/activity")"#, "timestamp>=\"\(since)\""]
        if let until { parts.append("timestamp<=\"\(until)\"") }
        parts += [AuditLogs.statuses["succeeded"] ?? "", "(\(named) OR \(policies) OR \(inserts))"]
        return parts.joined(separator: " AND ")
    }

    /// What an entry's request and metadata say that the watch judges it by, read when the entry is and nothing more
    /// kept: never a key, a metadata value or a policy whole.
    struct Facts: Sendable {
        var hasRequest = false
        /// A firewall rule's: what it lets in from where, and whether it is off.
        var sourceRanges: [String] = [], direction: String? = nil, allows = false, denies = false, disabled = false
        /// The metadata keys a metadata change added, changed or removed, as Compute Engine logs them; it leaves the
        /// metadata itself out of the request.
        var metadataKeys: Set<String> = [], keysKnown = false
        var accelerators = 0, count = 1, firstOfOperation = true
        /// An organisation policy change's constraint, whether its rule loosens it (nil when the rule is not read here)
        /// and whether it hands it back to its parent or Google's default.
        var constraint: String? = nil, loosens: Bool? = nil, resets = false
        var keyVersionDisabled = false, updateMask = ""
        /// The roles an IAM policy set in full grants, by role, for a change that logs no delta, as IAM's own for a
        /// service account may not.
        var policyGrants: [String: [String]] = [:]
        /// A service account made: its email.
        var account: String? = nil

        init() {}

        init(_ entry: JSON?, method: String, resource: String?) {
            guard let payload = entry?["protoPayload"] else { return }
            func list(_ value: JSON?) -> [JSON] { if case .array(let items)? = value { return items }; return [] }
            func flag(_ value: JSON?) -> Bool { if case .bool(let flag)? = value { return flag }; return value?.text?.lowercased() == "true" }
            // A long operation is logged twice, first and last; only the first holds the request.
            if let operation = entry?["operation"], !flag(operation["first"]) { firstOfOperation = false }
            let request = payload["request"], metadata = payload["metadata"]
            hasRequest = request != nil
            func number(_ value: JSON?) -> Int? {
                if case .number(let number)? = value { return Int(number) }
                return value?.text.flatMap { Int($0) }
            }
            sourceRanges = list(request?["sourceRanges"]).compactMap(\.text)
            direction = request?["direction"]?.text
            allows = !list(request?["alloweds"]).isEmpty || !list(request?["allowed"]).isEmpty
            denies = !list(request?["denieds"]).isEmpty || !list(request?["denied"]).isEmpty
            disabled = flag(request?["disabled"])
            // Only the keys, never their values.
            if let delta = metadata?["instanceMetadataDelta"] ?? metadata?["projectMetadataDelta"] {
                keysKnown = true
                for field in ["addedMetadataKeys", "modifiedMetadataKeys", "deletedMetadataKeys"] { metadataKeys.formUnion(list(delta[field]).compactMap(\.text)) }
            }
            accelerators = list(request?["guestAccelerators"]).count
            count = number(request?["count"]) ?? number(request?["minCount"]) ?? 1
            // An organisation policy, as its first form sets it, with the constraint inside, or as its second, named
            // after the constraint and holding rules.
            let policy = request?["policy"]
            constraint = (policy?["constraint"]?.text ?? request?["constraint"]?.text
                ?? (policy?["name"]?.text ?? request?["name"]?.text ?? resource).flatMap { named in named.range(of: "/policies/").map { String(named[$0.upperBound...]) } })
                .map { $0.replacingOccurrences(of: "constraints/", with: "") }
            if method.localizedCaseInsensitiveContains("ClearOrgPolicy") || method.hasSuffix("DeletePolicy") { resets = true }
            if let policy {
                if policy["restoreDefault"] != nil || flag(policy["spec"]?["reset"]) { resets = true }
                if let boolean = policy["booleanPolicy"] {
                    // Google leaves a false value out, so a boolean rule without enforced is not enforced.
                    loosens = !flag(boolean["enforced"])
                } else if let listed = policy["listPolicy"] {
                    loosens = listed["allValues"]?.text == "ALLOW"
                } else if let spec = policy["spec"], !list(spec["rules"]).isEmpty {
                    loosens = list(spec["rules"]).contains { rule in
                        (rule["enforce"].map { !flag($0) } ?? false) || flag(rule["allowAll"])
                    }
                }
            }
            keyVersionDisabled = request?["cryptoKeyVersion"]?["state"]?.text == "DISABLED"
            updateMask = (request?["updateMask"]?.text ?? list(request?["updateMask"]?["paths"]).compactMap(\.text).joined(separator: ",")).lowercased()
            for binding in list(request?["policy"]?["bindings"]).isEmpty ? list(payload["response"]?["bindings"]) : list(request?["policy"]?["bindings"]) {
                if let role = binding["role"]?.text { policyGrants[role, default: []] += list(binding["members"]).compactMap(\.text) }
            }
            account = payload["response"]?["email"]?.text?.lowercased()
            if account == nil, let id = (request?["account_id"] ?? request?["accountId"])?.text, let project = resource.flatMap(GoogleCloud.project(in:)) ?? request?["name"]?.text.flatMap(GoogleCloud.project(in:)) {
                account = "\(id)@\(project).iam.gserviceaccount.com".lowercased()
            }
        }
    }

    /// An audit entry, as Logging gives it, with what the watch judges it by.
    struct Watched: Decodable {
        let entry: AuditLogs.Entry
        let facts: Facts
        init(from decoder: Decoder) throws {
            entry = try AuditLogs.Entry(from: decoder)
            facts = Facts(try? JSON(from: decoder), method: entry.protoPayload?.methodName ?? "", resource: entry.protoPayload?.resourceName)
        }
    }
    struct WatchedPage: Decodable { let entries: [Watched]?; let nextPageToken: String? }

    /// Whether a source range is all of the internet.
    static func isAnywhere(_ range: String) -> Bool { ["0.0.0.0/0", "::/0", "0.0.0.0"].contains(range.trimmingCharacters(in: .whitespaces)) }

    /// What an entry did that the watch wakes for, the most pressing first, or nil for one it does not: `made` holds
    /// the service accounts made in the same window, so a grant to one just made counts.
    static func judge(_ watched: Watched, made: Set<String>) -> (tier: Int, kind: String, what: String)? {
        let entry = watched.entry, facts = watched.facts
        guard let payload = entry.protoPayload, !entry.failed, facts.firstOfOperation else { return nil }
        let method = payload.methodName ?? "", service = payload.serviceName ?? ""
        var found: [(tier: Int, kind: String, what: String)] = []
        if let what = keyMethods[method] { found.append((0, what, what)) }
        // A policy set in full with no delta logged, as IAM logs a service account's: what it grants now is all there
        // is to judge by, so a watched role or everyone in it counts, said to be the whole policy.
        if payload.bindingDeltas.isEmpty, method == serviceAccountPolicy {
            for (role, members) in facts.policyGrants.sorted(by: { $0.key < $1.key }) {
                let everyone = members.filter(PublicResources.everyone.contains)
                if !everyone.isEmpty { found.append((0, "granted to everyone", "policy set granting \(role) to \(everyone.joined(separator: ", ")); the entry shows the whole policy, not what changed")) }
                else if watchedRoles.contains(role), !members.isEmpty {
                    found.append((0, "powerful role granted", "policy set granting \(role) to \(members.prefix(3).joined(separator: ", ")); the entry shows the whole policy, not what changed"))
                }
            }
        }
        // IAM changes, from the roles given and the audit logging changed: grants of roles that hand over a scope or a
        // service account, and grants to everyone, wherever they are; logging of data reads or writes turned off or
        // someone exempted from it. A public grant on a bucket or dataset exposes data, which comes after control.
        for delta in payload.bindingDeltas where delta.action?.uppercased() == "ADD" {
            let member = delta.member ?? "", role = delta.role ?? "?"
            if PublicResources.everyone.contains(member) {
                let data = dataServices.contains(service) || method == "storage.setIamPermissions" || payload.metadata?.datasetChange != nil
                found.append(data ? (1, "data made public", "\(role) granted to \(member)") : (0, "granted to everyone", "\(role) granted to \(member)"))
            } else if watchedRoles.contains(role) {
                found.append((0, "powerful role granted", "\(role) granted to \(member)"))
            } else if member.hasPrefix("serviceAccount:"), made.contains(String(member.dropFirst("serviceAccount:".count)).lowercased()) {
                found.append((1, "new service account granted", "\(role) granted to \(member), made in this window"))
            }
        }
        for delta in payload.auditConfigDeltas {
            let type = delta.logType ?? "?", on = delta.service ?? "?"
            if delta.action?.uppercased() == "REMOVE", ["DATA_READ", "DATA_WRITE"].contains(type) {
                found.append((0, "audit logging turned off", "\(type) audit logging turned off for \(on)"))
            } else if delta.action?.uppercased() == "ADD", let exempted = delta.exemptedMember {
                found.append((0, "audit logging turned off", "\(exempted) exempted from \(type) audit logging for \(on)"))
            }
        }
        if let what = loggingMethods[method] { found.append((0, "logging changed", what)) }
        // The old retention is not in the entry, so any change of it is told, which is rare.
        if method == bucketUpdate, facts.updateMask.contains("retention") { found.append((1, "logging changed", "log bucket retention changed")) }
        if let what = identityPoolMethods[method] { found.append((0, "workload identity federation changed", what)) }
        if orgPolicyMethods.contains(method) || orgPolicyV1.contains(where: method.localizedCaseInsensitiveContains) {
            // Only security constraints, and only a rule that loosens one, or one handed back to its parent or Google's
            // default; a rule not read here counts, as does a change whose constraint the entry does not show.
            if let constraint = facts.constraint {
                if OrgPolicies.protective[constraint] != nil || OrgPolicies.restrictive[constraint] != nil {
                    if facts.resets { found.append((1, "organisation policy loosened", "\(constraint) handed back to its parent's or Google's default")) }
                    else if facts.loosens != false {
                        found.append((1, "organisation policy loosened", "\(constraint) " + (facts.loosens == true ? "loosened" : "changed, in a form not read here")))
                    }
                }
            } else {
                found.append((1, "organisation policy loosened", "an organisation policy changed whose constraint the entry does not show"))
            }
        }
        // A rule letting the internet in: a rule that only denies, or an outbound one, opens nothing.
        if firewallMethods.contains(method), facts.hasRequest, !facts.disabled, facts.direction?.uppercased() != "EGRESS",
           facts.sourceRanges.contains(where: isAnywhere), facts.allows || !facts.denies {
            found.append((1, "firewall opened to the internet", "firewall rule lets in \(facts.sourceRanges.filter(isAnywhere).joined(separator: ", "))"))
        }
        // SSH keys planted or OS Login, which puts SSH under IAM, changed. Compute Engine leaves the metadata out of the
        // request, so only the keys it logs as changed are read. Project-wide metadata is set rarely, so a change
        // whose keys the entry does not show is told too; a VM's is set often, by startup scripts and more, so only one
        // whose keys show SSH or OS Login is.
        let ssh = facts.metadataKeys.contains("ssh-keys") || facts.metadataKeys.contains("sshKeys")
        let osLogin = facts.metadataKeys.contains("enable-oslogin") || facts.metadataKeys.contains("block-project-ssh-keys")
        let whose = projectMetadataMethods.contains(method) ? "project-wide" : instanceMetadataMethods.contains(method) ? "a VM's" : nil
        if let whose {
            if ssh { found.append((1, "SSH keys changed", "\(whose) SSH keys changed")) }
            if osLogin { found.append((1, "SSH keys changed", "\(whose) OS Login or SSH key blocking changed")) }
            if whose == "project-wide", !facts.keysKnown { found.append((1, "SSH keys changed", "project-wide metadata changed; the entry does not show which keys")) }
        }
        if method.localizedCaseInsensitiveContains(projectDeletion), !method.localizedCaseInsensitiveContains("Undelete") {
            found.append((1, "project deleted", "project deleted"))
        }
        if insertMethods.contains(method) || bulkInsertMethods.contains(method) {
            if facts.accelerators > 0 { found.append((2, "VMs made with GPUs", "VM made with GPUs")) }
            if bulkInsertMethods.contains(method), facts.count >= manyVMs { found.append((2, "many VMs made", "\(facts.count) VMs made at once")) }
        }
        if method == newAccount { found.append((2, "service account made", "service account made")) }
        if keyVersionMethods.contains(method), method.hasPrefix("Destroy") || facts.keyVersionDisabled {
            found.append((2, "encryption key version destroyed or disabled", method.hasPrefix("Destroy") ? "key version scheduled for destruction" : "key version disabled"))
        }
        return found.min { $0.tier < $1.tier }
    }

    /// Where the watch is in reading the scope's folders and projects, kept per account between checks: those listed,
    /// when, and the search of up to 100 the next check starts from when they do not all fit in one check.
    struct Rotation: Sendable {
        var names: [String]? = nil, listed: Date? = nil, next = 0
        /// Why the folders and projects listed are not all there are, such as a later page that failed, kept with them
        /// so a check that reuses them still says so; nil once a listing comes back whole.
        var incomplete: String? = nil
    }

    /// What one read of the audit logs found, and what it could not read.
    struct AuditRead {
        var events: [WatchedEvent] = [], searched: [String] = [], requests = 0
        /// Searches whose first page failed, with why.
        var failed: [(names: [String], error: Error)] = []
        /// Searches with more than the requests left could read.
        var cut: [String] = []
        /// Resources over the requests one read sends, not read at all.
        var notSearched: [String] = []
        /// Folders and projects pending deletion, which are not watched.
        var retired: [String] = []
        var listingError: Error? = nil, listing: String? = nil
        /// Why the folders and projects read are only some of them, when they are.
        var listingIncomplete: String? = nil
    }

    /// The watched Admin Activity entries of the scope, its folders and its projects in the window, in searches of up to
    /// 100 resources, one Logging request each, within `budget` requests, then reading on past a first page with what
    /// is left. With `rotation`, the watch's, searches that do not fit are left to later checks in turn, the scope's own
    /// first one read every time; without it, as security-events reads, they are said not to have been searched.
    /// `first` are searched before the rest, such as where the watch found what woke the agents; `only`, when given,
    /// are the only ones searched, unlisted.
    static func readAudit(_ service: ServiceClient, _ scope: (level: String, id: String), since: String, until: String?, budget: Int,
                          rotation: inout Rotation?, first: [String] = [], only: [String]? = nil, now: Date = Date()) async -> AuditRead {
        let own = "\(scope.level)/\(scope.id)"
        var read = AuditRead()
        var names = [own]
        let incomplete = { (reason: String, listed: String) in
            read.listingIncomplete = reason
            read.listing = "Only some folders and projects under \(own) were listed\(listed), as \(reason), so the rest were not searched; set the account to a folder."
        }
        if let only {
            names = only
        } else if scope.level != "projects" {
            if let kept = rotation?.names, let listed = rotation?.listed, now.timeIntervalSince(listed) < relisting {
                names = kept
                if let reason = rotation?.incomplete { incomplete(reason, " at \(ISO8601DateFormatter().string(from: listed))") }
            } else {
                do {
                    let found = try await GoogleCloud.hierarchy(service, scope)
                    let live = found.containers.filter { $0.live && $0.name != own }
                    // Folders first, as their few logs hold changes to everything below them.
                    names = [own] + live.filter { !$0.isProject }.map(\.name) + live.filter(\.isProject).map(\.name)
                    read.retired = found.containers.filter { !$0.live }.map(\.name)
                    if let stopped = found.stopped { incomplete(stopped, "") }
                    // Kept with why it is incomplete, if it is, so the checks reusing it say so too until a listing
                    // comes back whole.
                    rotation?.names = names
                    rotation?.listed = now
                    rotation?.incomplete = found.stopped
                } catch {
                    read.listingError = error
                    read.listing = "The folders and projects under \(own) could not be listed, so only its own logs were read: \(error.localizedDescription)"
                    if let kept = rotation?.names { names = kept; read.listing = "The folders and projects under \(own) could not be listed again, so those listed before were read: \(error.localizedDescription)" }
                }
            }
        }
        // Those asked for first, then the rest.
        var seenNames = Set<String>()
        names = (first + names).filter { seenNames.insert($0).inserted }
        let chunks = stride(from: 0, to: names.count, by: namesPerSearch).map { Array(names[$0..<min($0 + namesPerSearch, names.count)]) }
        // Which searches this read sends a first request for.
        var planned = Array(chunks.indices)
        if rotation != nil, chunks.count > budget - readOnReserve {
            let rest = Array(chunks.indices.dropFirst()), take = max(budget - readOnReserve - 1, 1)
            let start = (rotation?.next ?? 0) % max(rest.count, 1)
            let turn = (0..<min(take, rest.count)).map { rest[(start + $0) % rest.count] }
            planned = [0] + turn
            rotation?.next = (start + turn.count) % max(rest.count, 1)
        }
        let filter = watchFilter(since: since, until: until)
        var found: [Watched] = [], tokens: [(index: Int, token: String)] = []
        let logging: ServiceClient
        do { logging = try service.at(host: "logging.googleapis.com") } catch {
            read.failed = [(names, error)]
            return read
        }
        struct Body: Encodable { let resourceNames: [String], filter: String, orderBy: String, pageSize: Int, pageToken: String? }
        func search(_ index: Int, _ token: String?) async throws -> WatchedPage {
            read.requests += 1
            return try await GoogleCloud.read(.logs, own) {
                try await logging.post(["v2", "entries:list"], body: Body(resourceNames: chunks[index], filter: filter, orderBy: "timestamp desc", pageSize: 1000, pageToken: token),
                                       as: WatchedPage.self)
            }
        }
        for index in planned {
            guard read.requests < budget else { read.notSearched += chunks[index]; continue }
            do {
                let page = try await search(index, nil)
                found += page.entries ?? []
                read.searched += chunks[index]
                if let token = page.nextPageToken, !token.isEmpty { tokens.append((index, token)) }
            } catch {
                read.failed.append((chunks[index], error))
            }
        }
        // Reading on, the first searches first, while requests are left; Logging may hand back empty pages that still
        // lead on. A page that fails keeps what was read, and says the search was cut short.
        while let next = tokens.first, read.requests < budget {
            tokens.removeFirst()
            do {
                let page = try await search(next.index, next.token)
                found += page.entries ?? []
                if let token = page.nextPageToken, !token.isEmpty { tokens.insert((next.index, token), at: 0) }
            } catch {
                read.cut += chunks[next.index]
            }
        }
        read.cut += tokens.flatMap { chunks[$0.index] }
        // Taken once, however many searches returned it, then judged with every service account made in the window.
        var seen = Set<String>(), unique: [Watched] = []
        for watched in found {
            if let identity = watched.entry.identity, !seen.insert(identity).inserted { continue }
            unique.append(watched)
        }
        let made = Set(unique.filter { $0.entry.protoPayload?.methodName == newAccount && !$0.entry.failed }.compactMap(\.facts.account))
        // VMs made by one account other than Google's agents, counted when there are many.
        var madeVMs: [String: Int] = [:]
        for watched in unique where insertMethods.contains(watched.entry.protoPayload?.methodName ?? "") && watched.facts.firstOfOperation && !watched.entry.failed {
            if let who = watched.entry.protoPayload?.authenticationInfo?.principalEmail, !who.hasSuffix(serviceAgentDomain) { madeVMs[who, default: 0] += 1 }
        }
        for watched in unique {
            let entry = watched.entry
            var judged = judge(watched, made: made)
            let who = entry.protoPayload?.authenticationInfo?.principalEmail ?? ""
            if judged == nil, insertMethods.contains(entry.protoPayload?.methodName ?? ""), watched.facts.firstOfOperation, !entry.failed, (madeVMs[who] ?? 0) >= manyVMs {
                judged = (2, "many VMs made", "one of \(madeVMs[who] ?? 0) VMs \(who) made in this window")
            }
            guard let judged, let time = entry.timestamp, let identity = entry.identity ?? entry.insertId.map({ "\($0)|\(time)" }) else { continue }
            read.events.append(WatchedEvent(id: "audit/" + identity, time: time, tier: judged.tier, kind: judged.kind, feed: "audit-logs",
                                            line: "\(judged.what): \(entry.line(own: own))", origin: entry.container))
        }
        return read
    }

    // MARK: The account's scope

    /// Which of `names` are established as inside the account's scope, by the name Logging takes, and which are not,
    /// each with why: a project's account reads that project alone; an organisation's or folder's, itself and the
    /// folders and projects `listing` holds under it, by name or number. A listing that came back only in part, or
    /// not at all, leaves what it does not hold unknown, which is never taken as inside.
    static func placed(_ names: [String], own: String, level: String, listing: Hierarchy?, failure: String? = nil) -> (inside: [String], outside: [(name: String, why: String)]) {
        var inside: [String] = [], outside: [(name: String, why: String)] = []
        for name in names {
            if name == own { inside.append(name); continue }
            guard level != "projects" else { outside.append((name, "the account reads \(own) alone")); continue }
            if let listing {
                if let found = listing.containers.first(where: { $0.name == name || ($0.isProject ? "projects/" : "folders/") + $0.number == name }) {
                    inside.append(found.name)
                } else {
                    outside.append((name, listing.stopped.map { "it is not among the folders and projects listed under \(own), which came back only in part (\($0)), so whether it is inside is unknown" }
                                          ?? "it is not under \(own)"))
                }
            } else {
                outside.append((name, "whether it is under \(own) is unknown, as its folders and projects could not be listed\(failure.map { ": \($0)" } ?? "")"))
            }
        }
        return (inside, outside)
    }

    /// The refusal of names outside the account's scope, naming each and why.
    static func outsideScope(_ outside: [(name: String, why: String)], own: String) -> ServiceError {
        ServiceError.input("Not searched, as only what is inside this account's scope, \(own), is: " + outside.map { "\($0.name) (\($0.why))" }.joined(separator: "; ")
                           + ". Set the account's Scope, in Settings › Tools, to the organisation or a folder that holds them.")
    }

    /// `names` by the name Logging takes when every one is inside the account's scope, from the folders and projects
    /// the watch listed lately or a listing now; otherwise a refusal naming those that are not, before anything is read.
    static func withinScope(_ names: [String], _ service: ServiceClient, _ scope: (level: String, id: String)) async throws -> [String] {
        let own = "\(scope.level)/\(scope.id)"
        if scope.level != "projects", let account = service.account {
            let cached = NewSecurityEvents.kept.withLock { kept in kept[account]?.rotation }
            if let cached, cached.incomplete == nil, let listed = cached.listed, Date().timeIntervalSince(listed) < relisting,
               let known = cached.names.map(Set.init), names.allSatisfy(known.contains) {
                return names
            }
        }
        var listing: Hierarchy?, failure: String?
        if scope.level != "projects", names.contains(where: { $0 != own }) {
            do { listing = try await GoogleCloud.hierarchy(service, scope) } catch { failure = error.localizedDescription }
        }
        let placed = placed(names, own: own, level: scope.level, listing: listing, failure: failure)
        if !placed.outside.isEmpty { throw outsideScope(placed.outside, own: own) }
        return placed.inside
    }

    // MARK: Both feeds

    /// A feed's label in words.
    static func feed(_ label: String) -> String {
        ["scc": "Security Command Center findings", "audit-logs": "the audit logs", "listing": "the folders and projects under the scope"][label] ?? label
    }

    /// What one read of both feeds found, and what it could not read, by feed: scc, audit-logs and listing, the folders
    /// and projects under the scope.
    struct WatchRead {
        var events: [WatchedEvent] = []
        var findings = FindingsRead(), audit = AuditRead()
        /// What could not be read, by feed, with why and whether it failed for a reason that passes.
        var unreadable: [(label: String, reason: String, passing: Bool)] = []
        /// The feeds that had more than one read takes.
        var cut: [String] = []
        /// Whether nothing at all could be read.
        var nothingRead: Bool { findings.error != nil && audit.searched.isEmpty }

        /// What was read, and what was not and why, for a result.
        func coverage(_ own: String, window: String) -> [String] {
            var lines: [String] = []
            if findings.error == nil { lines.append("Searched: Security Command Center's active, unmuted, high and critical findings at \(own), created or seen again \(window).") }
            if !audit.searched.isEmpty { lines.append("Searched: the Admin Activity audit logs of \(GoogleCloud.described(audit.searched)), \(window), for the watched changes.") }
            for (label, reason, _) in unreadable { lines.append("Could not read \(GoogleCloud.feed(label)): \(reason)") }
            if findings.cut { lines.append("Cut short, with more not read: more high and critical findings than one read takes; narrow the window, or use scc-findings and scc-summary.") }
            if !audit.cut.isEmpty { lines.append("Cut short, with older entries not read: the audit logs of \(GoogleCloud.described(audit.cut)); narrow the window, or use audit-logs.") }
            if !audit.notSearched.isEmpty { lines.append("Not searched, over the \(GoogleCloud.searchRequests) Logging requests one read sends: \(GoogleCloud.described(audit.notSearched)); narrow the window's end, or set the account to a folder.") }
            if !audit.retired.isEmpty { lines.append("Not watched, pending deletion: \(GoogleCloud.described(audit.retired)).") }
            if let listing = audit.listing { lines.append(listing) }
            return lines
        }
    }

    /// Both feeds from `since` to `until`, the findings first, then the audit logs within `budget` Logging requests,
    /// each kept when the other cannot be read; the same for the watch and security-events, so what woke the agents
    /// reads back the same.
    static func watchedEvents(_ service: ServiceClient, since: String, until: String?, budget: Int, rotation: inout Rotation?,
                              first: [String] = [], only: [String]? = nil, now: Date = Date()) async throws -> WatchRead {
        let scope = try GoogleCloud.scope(service)
        var read = WatchRead()
        read.findings = await readFindings(service, scope, since: since, until: until)
        read.audit = await readAudit(service, scope, since: since, until: until, budget: budget, rotation: &rotation, first: first, only: only, now: now)
        if let error = read.findings.error { read.unreadable.append(("scc", error.localizedDescription, GoogleWorkspace.isPassing(error))) }
        if !read.audit.failed.isEmpty {
            let failed = read.audit.failed.flatMap(\.names)
            read.unreadable.append(("audit-logs", "\(GoogleCloud.described(failed)): " + Array(Set(read.audit.failed.map { $0.error.localizedDescription })).sorted().joined(separator: "; "),
                                    read.audit.failed.allSatisfy { GoogleWorkspace.isPassing($0.error) }))
        }
        if let error = read.audit.listingError { read.unreadable.append(("listing", error.localizedDescription, GoogleWorkspace.isPassing(error))) }
        // A listing cut short is told as one that failed: what it left out is not watched.
        else if let reason = read.audit.listingIncomplete { read.unreadable.append(("listing", "only some were listed, as \(reason)", false)) }
        if read.findings.cut { read.cut.append("scc") }
        if !read.audit.cut.isEmpty || !read.audit.notSearched.isEmpty { read.cut.append("audit-logs") }
        read.events = (read.findings.events + read.audit.events).sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
        return read
    }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Admin Activity audit logs are always on and cost nothing, so the changes above are recorded wherever they are made; Data Access audit logs, off by default for every service but BigQuery, are not read here, so tokens minted for a service account, secrets read and data read or copied are not watched: search them with audit-logs and logType data_access. Not watched either: a key used once made, custom roles, a VM's own startup scripts, new log sinks, deny policies, and VMs Google's own service agents make, such as a managed instance group's. Findings come only from what Security Command Center's tier detects, and threats only with Premium or Enterprise."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String?, project: String?, resourceNames: [String]? }
        static let name = "security-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: Security Command Center's active, unmuted, high and critical findings, threats first, and the Admin Activity audit log entries across the scope that open the way in or hide what follows: service account keys made or uploaded, owner, editor, token creator and other powerful roles granted, anything granted to everyone, Data Access logging turned off, log sinks, exclusions and buckets changed, workload identity federation set up, security organisation policies loosened, firewalls opened to the internet, SSH keys planted, projects deleted, data made public, VMs made with GPUs or in numbers, service accounts made and encryption keys destroyed, reading first where the watch found what it woke the agents for, saying what it searched and what it could not; project or resourceNames read only those."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601, included."),
            "project": .string("Only this project's audit logs, by its ID, such as kestrel-prod."),
            "resourceNames": .array(.string("An organisation, folder or project, as organizations/NUMBER, folders/NUMBER or projects/ID."),
                                    "Only these audit logs, up to \(GoogleCloud.namesPerSearch * GoogleCloud.searchRequests), rather than the whole scope's; each must be inside the account's scope. Findings are still the whole scope's, listed apart."),
        ])

        /// The resource names to search alone, from `project` and `resourceNames`, or nil for the whole scope.
        static func narrowed(_ input: Input) throws -> [String]? {
            let given = (input.project.map { ["projects/" + $0.trimmingCharacters(in: .whitespaces)] } ?? []) + (input.resourceNames ?? [])
            guard !given.isEmpty else { return nil }
            return try ServiceInput.list(given, limit: GoogleCloud.namesPerSearch * GoogleCloud.searchRequests) { value in
                let name = value.trimmingCharacters(in: .whitespaces)
                guard name.count <= 200, name.range(of: #"^(organizations|folders|projects)/[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil else {
                    throw ServiceError.input("Give each resource as organizations/NUMBER, folders/NUMBER or projects/ID, and project as the project's ID alone.")
                }
                return name
            }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service)
            let own = "\(scope.level)/\(scope.id)"
            let since = try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(1)
            let until = try input.until.map(ServiceInput.time)
            if let until, let start = ServiceAlert.time(since), let end = ServiceAlert.time(until), start > end {
                throw ServiceError.input("since (\(since)) is after until (\(until)); give since before until.")
            }
            // Names given are searched only once each is established as inside the account's scope.
            var only: [String]? = nil
            if let given = try Self.narrowed(input) { only = try await GoogleCloud.withinScope(given, service, scope) }
            // What the watch found in the window, kept while Pion runs, read first: the folders and projects it was
            // found in are searched before the rest, so what woke the agents is read again within the budget however
            // far down a large organisation it was, and it is shown as the watch found it should reading it again fail.
            let start = ServiceAlert.time(since) ?? .distantPast, end = until.flatMap { ServiceAlert.time($0) } ?? .distantFuture
            let found = service.account.map { account in
                NewSecurityEvents.kept.withLock { kept in (kept[account]?.found.values).map(Array.init) ?? [] }
            }?.filter { $0.date >= start && $0.date <= end } ?? []
            let origins = Array(Set(found.compactMap(\.origin))).sorted()
            var rotation: Rotation? = nil
            var read = try await GoogleCloud.watchedEvents(service, since: since, until: until, budget: searchRequests, rotation: &rotation,
                                                           first: only == nil ? origins : [], only: only)
            if read.nothingRead, found.isEmpty, let error = read.findings.error { throw error }
            let reread = Set(read.events.map(\.id))
            let kept = only == nil ? found.filter { !reread.contains($0.id) } : []
            read.events = (read.events + kept).sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
            // Narrowed, the audit logs are those resources' alone, while findings are still the whole scope's: they
            // are listed apart, said to be, rather than taken for the resources'.
            let scopeFindings = only == nil ? [] : read.events.filter { $0.feed == "scc" }
            if only != nil { read.events.removeAll { $0.feed == "scc" } }
            let window = "from \(since) to \(until ?? "now")"
            var lines: [String]
            if read.events.isEmpty {
                lines = [read.unreadable.isEmpty && read.cut.isEmpty ? "No watched events \(window)." : "No watched events \(window) in what could be read; see below for what was not."]
            } else {
                // The first 80 taken in turn from each kind, so a burst of one does not hide the rest.
                lines = GoogleCloud.inTurn(read.events, most: 80).map(\.line)
                if read.events.count > 80 { lines.append("\(read.events.count - 80) more in the structured result.") }
            }
            if let only, !scopeFindings.isEmpty {
                lines.append("Security Command Center findings across the whole of \(own), not narrowed to \(GoogleCloud.described(only)):")
                lines += GoogleCloud.inTurn(scopeFindings, most: 30).map(\.line)
                if scopeFindings.count > 30 { lines.append("\(scopeFindings.count - 30) more in the structured result.") }
            }
            lines += read.coverage(own, window: window)
            if !kept.isEmpty {
                lines.append("\(kept.count) of these \(kept.count == 1 ? "is" : "are") as the watch found \(kept.count == 1 ? "it" : "them") while Pion ran, not read again now: \(GoogleCloud.listed(kept.prefix(5).map(\.id)))\(kept.count > 5 ? " and more" : "").")
            }
            if only == nil, service.account != nil {
                lines.append("What the watch found is kept only while Pion runs: after a relaunch this searches the scope afresh, in the order it lists it, within \(GoogleCloud.searchRequests) Logging requests; give project or resourceNames to read one part.")
            }
            lines.append(GoogleCloud.unwatched)
            struct Kept: Encodable {
                let events: [WatchedEvent]; let scopeFindings: [WatchedEvent]; let couldNotRead: [String: String]; let cutShort: [String]; let searched: [String]; let notSearched: [String]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                events: read.events, scopeFindings: scopeFindings, couldNotRead: Dictionary(read.unreadable.map { ($0.label, $0.reason) }, uniquingKeysWith: { "\($0); \($1)" }),
                cutShort: read.cut, searched: read.audit.searched, notSearched: read.audit.notSearched))
        }
    }

    /// The watch: each check reads both feeds from `since` on. Google lists some audit entries and findings minutes to
    /// hours after their time, and a source may write a finding hours after the event it found, so each reads six hours
    /// back. What one feed found is kept when the other cannot be read.
    ///
    /// A feed that cannot be read is never dropped unsaid: Security Command Center not activated, refused, its API off
    /// or the sign-in expired is told as an alert of its own, which wakes the agents to read security-events, whose
    /// result names it and why. It is told once for each time the feed stops answering, and again after a relaunch, and
    /// it is dated at the start of the window read, so it never moves the watch past what was not yet read. A feed
    /// failing for a passing reason holds the watch back instead, a few checks at most, and is then told the same way;
    /// one cut short, with more than a check reads even reading on, is told once until it is read in full again; so is a
    /// listing of the folders and projects that came back only in part, which the checks reusing it keep saying until
    /// one comes back whole.
    ///
    /// What each check finds is kept while Pion runs, with where it was logged, so security-events reads it first: an
    /// entry found in a project far down a large organisation, read by the watch in turn, is read again within the
    /// budget of one call. After a relaunch security-events searches afresh and says what it could not reach.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 6 * 3_600 }
        /// How many checks in a row a feed failing for a passing reason holds the watch back, half an hour at the watch's
        /// pace, before it is told as unreadable: each check still reads six hours back, so one that answers again
        /// within hours is read from before it failed.
        static let holdChecks = 6

        /// What the checks of one account keep between them while Pion runs: how many checks in a row each feed has
        /// failed for a passing reason, the notices told, by feed, with the ID they were told with, forgotten once the
        /// feed is read in full again, and where the watch is in reading the scope's folders and projects. It is not
        /// saved, so after a relaunch a feed still unreadable is told once more.
        struct Kept: Sendable {
            var inARow: [String: Int] = [:], told: [String: String] = [:], rotation = Rotation()
            /// What the checks found, by ID, the newest `recorded`, for security-events to read first.
            var found: [String: WatchedEvent] = [:]
        }
        static let kept = Mutex<[UUID: Kept]>([:])
        /// How many of what the checks found are kept for security-events: one check's worth.
        static let recorded = ServiceAlert.most

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// `now` is when the check runs, which decides whether the folders and projects are listed again.
        func alerts(since: Date, on service: ServiceClient, account: UUID?, now: Date = Date()) async throws -> [ServiceAlert] {
            var rotation: Rotation? = account.map { account in Self.kept.withLock { $0[account]?.rotation ?? Rotation() } }
            let read = try await GoogleCloud.watchedEvents(service, since: ISO8601DateFormatter().string(from: since), until: nil,
                                                          budget: GoogleCloud.watchRequests, rotation: &rotation, now: now)
            let passing = Set(read.unreadable.filter(\.passing).map(\.label))
            // What to tell, by what it is kept under: each feed that cannot be read, and each cut short.
            let notices = read.unreadable.map { ($0.label, "unreadable/\($0.label)") } + read.cut.map { ("more/\($0)", "unchecked/\($0)") }
            let current = Set(notices.map(\.0))
            // Kept up to date before any hold, so a feed that answered on a held check has its outage forgotten and a
            // later one is told afresh.
            var inARow: [String: Int] = [:]
            if let account {
                inARow = Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    watched.inARow = watched.inARow.filter { passing.contains($0.key) }
                    for label in passing { watched.inARow[label, default: 0] += 1 }
                    watched.told = watched.told.filter { current.contains($0.key) }
                    if let rotation { watched.rotation = rotation }
                    // What was found is kept for security-events, the newest first, whatever this check goes on to do.
                    for event in read.events { watched.found[event.id] = event }
                    if watched.found.count > Self.recorded {
                        let newest = watched.found.values.sorted { $0.date > $1.date }.prefix(Self.recorded)
                        watched.found = Dictionary(newest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                    kept[account] = watched
                    return watched.inARow
                }
            }
            // A feed that could not be read for now fails the whole check, so the watch stays where it is and the next
            // check reads the same window again, rather than moving past what it would have found.
            let held = passing.filter { (inARow[$0] ?? 1) <= Self.holdChecks }.sorted()
            if !held.isEmpty {
                throw ServiceError.input("Could not read \(GoogleCloud.listed(held.map(GoogleCloud.feed))) for now; the next check reads the same window again.")
            }
            // The rest is told once per outage, marked told only on the check that returns it: a new ID each time, so a
            // second outage is told even while the first is still among those seen.
            var tell = notices
            if let account {
                tell = Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    let new = notices.filter { watched.told[$0.0] == nil }.map { ($0.0, "\($0.1)/\(UUID().uuidString)") }
                    for (label, id) in new { watched.told[label] = id }
                    kept[account] = watched
                    return new
                }
            } else {
                tell = notices.map { ($0.0, "\($0.1)/\(UUID().uuidString)") }
            }
            // Nothing read at all, and nothing new to tell: the check fails, so Settings says why.
            if read.nothingRead, tell.isEmpty, let first = read.unreadable.first { throw ServiceError.input(first.reason) }
            // Dated at the window's start, which is never after the newest seen, so it moves nothing on.
            let told = tell.map { ServiceAlert(id: $0.1, time: since) }
            return told + GoogleCloud.inTurn(read.events, most: ServiceAlert.most - told.count).compactMap { event in
                ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) }
            }
        }
    }
}
