import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Microsoft Entra ID Detection's alert watch, and security-events, which reads back what woke the agents, the same way for
/// both: the directory audit log's changes that hand over the tenant, open a way back in or weaken its defences, and
/// the users and sign-ins Identity Protection rates at high risk.
extension Entra {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Limits

    /// The most pages of each feed one check of the watch reads, and one call of security-events: Graph throttles each
    /// app in each tenant, so both leave most of it for investigations.
    static let watchPages = 4, eventsPages = 10
    static let auditPage = "500", riskPage = "200"

    // MARK: Feeds

    enum Feed: String, CaseIterable, Sendable {
        case audit = "directory-audit", riskyUsers = "risky-users", detections = "risk-detections"

        var title: String {
            switch self {
            case .audit: "the directory audit log"
            case .riskyUsers: "Identity Protection's risky users"
            case .detections: "Identity Protection's risk detections"
            }
        }

        var need: Need {
            switch self {
            case .audit: .audit
            case .riskyUsers: .risky
            case .detections: .detections
            }
        }

        var path: [String] {
            switch self {
            case .audit: ["auditLogs", "directoryAudits"]
            case .riskyUsers: ["identityProtection", "riskyUsers"]
            case .detections: ["identityProtection", "riskDetections"]
            }
        }

        /// The search for `since` to `until`: the audit log bounded at both ends, Identity Protection from since on, at
        /// high risk, as it filters its times only from a start; what came after until is left out when read.
        func query(since: Date, until: Date) -> [String: String?] {
            switch self {
            case .audit: ["$filter": "activityDateTime ge \(Entra.iso(since)) and activityDateTime le \(Entra.iso(until))", "$top": Entra.auditPage]
            case .riskyUsers: ["$filter": "riskLevel eq 'high' and riskLastUpdatedDateTime ge \(Entra.iso(since))", "$top": Entra.riskPage]
            case .detections: ["$filter": "riskLevel eq 'high' and detectedDateTime ge \(Entra.iso(since))", "$top": Entra.riskPage]
            }
        }
    }

    /// A query cut short at the page budget, to go on with: Graph's $skiptoken for its next page and the window it was
    /// asked for, as a token is good only with the query it came from. Entries made at the same moment have no order
    /// Pion could resume by, so only the token, never a time, says where the query stopped.
    struct Continuation: Sendable, Equatable {
        let token: String, since: Date, until: Date
        /// The oldest of what its pages found but the checks had no room to return.
        var owed: Date? = nil
    }

    /// What one read of one feed found, and how far it got.
    struct FeedRead {
        var events: [WatchedEvent] = []
        /// Read whole: every page, nothing refused.
        var complete = false
        /// More remained than the pages it may read, or a next page it would not follow.
        var cut = false
        var error: Error? = nil
        /// Why the feed has nothing to read, such as Identity Protection without its licence, said as what to change.
        var off: String? = nil
        /// For a read cut at its page budget: how to go on with the same query.
        var next: Continuation? = nil
        /// The query this read went on with, when a check before had cut it short.
        var resumed: Continuation? = nil
        var pages = 0
        /// Why it stopped early, when a page failed after others were read.
        var stopped: String? = nil
    }

    // MARK: Watched changes

    /// Permissions that read or change mail, files or the whole directory, or make administrators: consenting to one
    /// hands an app far more than a sign-in.
    static let highPrivilege: Set<String> = AppPermissions.makesAdministrators.union([
        "Mail.Read", "Mail.ReadWrite", "Mail.Send", "MailboxSettings.ReadWrite", "Files.Read.All", "Sites.Read.All", "EWS.AccessAsUser.All",
        "full_access_as_app", "full_access_as_user", "Directory.Read.All", "User.Export.All",
    ])

    static func isHighPrivilege(_ permission: String) -> Bool {
        highPrivilege.contains(permission) || permission.hasSuffix(".ReadWrite.All") || permission.hasSuffix(".FullControl.All")
    }

    /// Permission names in a property's text, such as an audit entry's "Scope: Mail.Read User.Read, …".
    static func permissions(_ text: String?) -> [String] {
        guard let text, let regex = try? NSRegularExpression(pattern: #"[A-Za-z_]+(\.[A-Za-z_]+)+"#) else { return [] }
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        return Array(NSOrderedSet(array: found)) as? [String] ?? found
    }

    /// An audit property's value as written, without the quotes and brackets Graph wraps it in.
    static func unquoted(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while let first = value.first, let last = value.last, value.count >= 2, (first == "\"" && last == "\"") || (first == "[" && last == "]") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    static let methodProperties: Set<String> = ["StrongAuthenticationMethod", "StrongAuthenticationUserDetails", "StrongAuthenticationPhoneAppDetail",
                                                "StrongAuthenticationRequirement", "SearchableDeviceKey"]

    /// What an audit entry did that the watch wakes for, the most pressing first, or nil for one it does not: tier 0
    /// hands over the tenant or opens a way back in, tier 1 loosens what defends it, tier 2 may have, but the log
    /// does not show which.
    static func judge(_ audit: Audit) -> (tier: Int, kind: String, what: String)? {
        guard (audit.result ?? "success").lowercased() == "success" else { return nil }
        let activity = audit.activityDisplayName ?? "", lower = activity.lowercased()
        let targets = audit.targetResources ?? []
        let properties = targets.flatMap { $0.modifiedProperties ?? [] }
        func new(_ name: String) -> String? { unquoted(properties.first { $0.displayName == name }?.newValue) }
        func old(_ name: String) -> String? { unquoted(properties.first { $0.displayName == name }?.oldValue) }
        let named = { (types: Set<String>) in targets.first { types.contains(($0.type ?? "").lowercased()) }.map { $0.userPrincipalName ?? $0.displayName ?? $0.id ?? "?" } }
        let member = named(["user", "serviceprincipal", "group"]) ?? targets.first.flatMap { $0.userPrincipalName ?? $0.displayName } ?? "?"
        let app = named(["application", "serviceprincipal"]) ?? targets.first?.displayName ?? "?"
        switch audit.category?.lowercased() ?? "" {
        case "rolemanagement":
            // Roles granted, made eligible or activated in Privileged Identity Management; never what was only asked for.
            guard lower.hasPrefix("add"), lower.contains("member to role"), !lower.contains("requested") else { return nil }
            let roleTarget = targets.first { ($0.type ?? "").lowercased() == "role" }
            let role = new("Role.DisplayName") ?? roleTarget?.displayName
            let template = new("Role.TemplateId") ?? roleTarget?.id
            guard role != nil || template != nil else { return (2, "role granted", "a directory role granted to \(member); the log does not show which") }
            guard isPrivileged(id: template, name: role) else { return nil }
            let shown = role ?? privilegedRoles[template?.lowercased() ?? ""] ?? "a privileged role"
            if lower.contains("pim activation") { return (0, "privileged role activated", "\(shown) activated through Privileged Identity Management by \(member)") }
            if lower.contains("eligible") { return (1, "privileged role made eligible", "\(member) made eligible for \(shown)") }
            return (0, "privileged role granted", "\(shown) granted to \(member)")
        case "applicationmanagement":
            if lower.contains("certificates and secrets management") {
                let before = (old("KeyDescription") ?? "").components(separatedBy: "KeyIdentifier=").count, after = (new("KeyDescription") ?? "").components(separatedBy: "KeyIdentifier=").count
                if after < before { return nil }
                return (0, "app credential added", after > before ? "secret or certificate added to app \(app)" : "secrets or certificates of app \(app) changed; the log does not show whether one was added")
            }
            if lower == "add service principal credentials" { return (0, "app credential added", "secret or certificate added to enterprise app \(app)") }
            if lower == "consent to application" {
                let admin = new("ConsentContext.IsAdminConsent")?.lowercased() == "true"
                let scopes = permissions(new("ConsentAction.Permissions"))
                let high = scopes.filter(isHighPrivilege)
                let listed = scopes.isEmpty ? "" : ": " + scopes.prefix(12).joined(separator: ", ")
                if admin { return (0, "admin consent to an app", "admin consent, for everyone, to app \(app)\(listed)") }
                if !high.isEmpty { return (0, "consent to high privileges", "\(audit.actor) consented to app \(app) with \(high.joined(separator: ", "))") }
                return (2, "consent to an app", "\(audit.actor) consented to app \(app)\(listed)")
            }
            if lower == "add delegated permission grant" {
                let scopes = permissions(new("DelegatedPermissionGrant.Scope"))
                let high = scopes.filter(isHighPrivilege)
                return high.isEmpty ? (1, "delegated permission granted", "delegated permissions \(scopes.joined(separator: ", ")) granted to app \(app)")
                    : (0, "consent to high privileges", "delegated permissions granted to app \(app), including \(high.joined(separator: ", "))")
            }
            if lower == "add app role assignment to service principal" {
                let role = new("AppRole.Value") ?? "?"
                return isHighPrivilege(role) ? (0, "application permission granted", "application permission \(role) granted to app \(app), which acts without anyone signed in")
                    : (1, "application permission granted", "application permission \(role) granted to app \(app)")
            }
            return nil
        case "directorymanagement":
            if lower.contains("federation") || lower == "set domain authentication" {
                return (0, "federation changed", "\(activity) on \(named(["domain", "other"]) ?? targets.first?.displayName ?? "a domain"), which decides who may sign in as the tenant's users")
            }
            if lower.hasPrefix("verify domain") || lower == "add verified domain" || lower == "add unverified domain" || lower == "add domain to company" {
                return (1, "domain added", "\(activity): \(targets.first?.displayName ?? "?")")
            }
            return nil
        case "policy":
            if lower.contains("conditional access policy") {
                if lower.hasPrefix("delete") { return (0, "Conditional Access policy deleted", "Conditional Access policy deleted: \(targets.first?.displayName ?? "?")") }
                return (1, "Conditional Access policy changed", "\(activity): \(targets.first?.displayName ?? "?"); the log does not show whether it weakened sign-in, so read the policy")
            }
            if lower.contains("named location") { return (1, "named location changed", "\(activity): \(targets.first?.displayName ?? "?"), which Conditional Access may trust") }
            return nil
        case "usermanagement":
            if lower.hasPrefix("admin "), lower.contains("security info") {
                return (0, "sign-in method changed by an admin", "\(activity) for \(member)")
            }
            if lower == "update user", properties.contains(where: { methodProperties.contains($0.displayName ?? "") }),
               let user = targets.first(where: { ($0.type ?? "").lowercased() == "user" }), let actor = audit.initiatedBy?.user?.id, actor != user.id {
                return (0, "sign-in method changed by someone else", "sign-in methods of \(user.userPrincipalName ?? user.id ?? "?") changed by someone other than them")
            }
            return nil
        default:
            return nil
        }
    }

    static func line(_ audit: Audit, _ what: String) -> String {
        "\(audit.activityDateTime ?? "?") \(what), by \(audit.actor)\(audit.ip.map { " from \($0)" } ?? "") [\(audit.id ?? "?")]"
    }

    struct RiskyUser: Decodable, Sendable {
        let id: String, userPrincipalName: String?, riskLevel: String?, riskState: String?, riskDetail: String?, riskLastUpdatedDateTime: String?
    }

    struct Detection: Decodable, Sendable {
        struct Place: Decodable, Sendable { let city: String?; let countryOrRegion: String? }
        let id: String, riskEventType: String?, riskLevel: String?, riskState: String?, detectedDateTime: String?, activity: String?
        let userPrincipalName: String?, ipAddress: String?, location: Place?
    }

    static let atRisk: Set<String> = ["atrisk", "confirmedcompromised"]

    // MARK: Reading

    /// The watched entries of one feed from `since` to `until`, or of the query `continuation` from its token. With
    /// `partial`, a page that fails after others keeps what they held and says so; without, the read fails whole.
    static func readFeed(_ feed: Feed, _ service: ServiceClient, since: Date, until: Date, pages: Int, from continuation: Continuation? = nil,
                         partial: Bool = false) async -> FeedRead {
        var read = FeedRead(resumed: continuation)
        let (since, until) = continuation.map { ($0.since, $0.until) } ?? (since, until)
        let within = { (time: Date) in time >= since.addingTimeInterval(-1) && time <= until.addingTimeInterval(1) }
        do {
            func listing<Item: Decodable>(_ type: Item.Type) async throws -> Listing<Item> {
                try await Entra.list(service, feed.path, query: feed.query(since: since, until: until), as: Item.self, pages: pages,
                                     token: continuation?.token, partial: partial)
            }
            let found: (pages: Int, more: Bool, stopped: String?, token: String?)
            switch feed {
            case .audit:
                let audits = try await listing(Audit.self)
                found = (audits.pages, audits.more, audits.stopped, audits.token)
                for audit in audits.value {
                    guard let id = audit.id, let time = ServiceAlert.time(audit.activityDateTime), within(time), let judged = judge(audit) else { continue }
                    read.events.append(WatchedEvent(id: safeID("audit/", id), time: iso(time), tier: judged.tier, kind: judged.kind, feed: feed.rawValue,
                                                    line: line(audit, judged.what)))
                }
            case .riskyUsers:
                let users = try await listing(RiskyUser.self)
                found = (users.pages, users.more, users.stopped, users.token)
                for user in users.value {
                    guard user.riskLevel?.lowercased() == "high", atRisk.contains(user.riskState?.lowercased() ?? ""),
                          let time = ServiceAlert.time(user.riskLastUpdatedDateTime), within(time) else { continue }
                    read.events.append(WatchedEvent(id: safeID("riskyuser/", "\(user.id)|\(user.riskLastUpdatedDateTime ?? "")"), time: iso(time), tier: 0,
                                                    kind: "user at high risk", feed: feed.rawValue,
                                                    line: "\(iso(time)) Identity Protection rates \(user.userPrincipalName ?? user.id) at high risk (\(user.riskState ?? "?")\(user.riskDetail.map { ", \($0)" } ?? "")) [\(user.id)]"))
                }
            case .detections:
                let detections = try await listing(Detection.self)
                found = (detections.pages, detections.more, detections.stopped, detections.token)
                for detection in detections.value {
                    guard detection.riskLevel?.lowercased() == "high", atRisk.contains(detection.riskState?.lowercased() ?? ""),
                          let time = ServiceAlert.time(detection.detectedDateTime), within(time) else { continue }
                    let place = [detection.location?.city, detection.location?.countryOrRegion].compactMap { $0 }.filter { !$0.isEmpty }
                    read.events.append(WatchedEvent(id: safeID("detection/", detection.id), time: iso(time), tier: 0,
                                                    kind: detection.activity == "signin" ? "high-risk sign-in" : "high-risk detection", feed: feed.rawValue,
                                                    line: "\(iso(time)) Identity Protection detected \(detection.riskEventType ?? "a risk") at high risk for \(detection.userPrincipalName ?? "?")\(detection.ipAddress.map { " from \($0)" } ?? "")\(place.isEmpty ? "" : " (\(place.joined(separator: ", ")))") [\(detection.id)]"))
                }
            }
            read.pages = found.pages
            read.stopped = found.stopped
            read.complete = !found.more && found.stopped == nil
            read.cut = !read.complete
            if let token = found.token, found.more, found.stopped == nil {
                read.next = Continuation(token: token, since: since, until: until, owed: continuation?.owed)
            }
        } catch {
            if unlicensed(error) {
                read.off = "\(feed.title) cannot be read without \(feed.need.licence ?? "a licence the tenant lacks"), so what it would show is not watched: add the licence to watch it."
                read.complete = true
            } else {
                read.error = error
            }
        }
        return read
    }

    /// The same digest Azure gives an ID a wake carries.
    static func safeID(_ prefix: String, _ value: String) -> String { Azure.safeID(prefix, value) }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: sign-ins themselves, failed ones and bursts of failed MFA included, which sign-ins finds with failuresOnly; users made, deleted, disabled or given new passwords; group memberships and app assignments; roles other than the privileged ones (Global, Privileged Role, Privileged Authentication, Security, Exchange, SharePoint, Application, Cloud Application, User, Conditional Access, Hybrid Identity and Authentication Administrator) and roles given through a group's membership; a user registering their own sign-in methods; consent a user gives with low privileges, which is told only alongside what is; and users and sign-ins at medium or low risk. Identity Protection needs Microsoft Entra ID P2; without it, its feeds are said to be off."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: privileged directory roles granted, made eligible or activated, secrets or certificates added to apps, admin consent and consent to high-privilege permissions, federation and domains changed, Conditional Access policies and named locations changed or deleted, sign-in methods changed by an admin, and users and sign-ins Identity Protection rates at high risk; saying, for each feed, what it searched, what is off, what it could not read and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Entra.window(input.since, input.until, days: 1)
            var reads: [(Feed, FeedRead)] = []
            for feed in Feed.allCases { reads.append((feed, await Entra.readFeed(feed, service, since: since, until: until, pages: Entra.eventsPages, partial: true))) }
            if reads.allSatisfy({ $0.1.error != nil || $0.1.off != nil }), reads.contains(where: { $0.1.error != nil }) {
                throw ServiceError.input("Nothing could be read: " + reads.map { feed, read in
                    "\(feed.title): " + (read.off ?? read.error.map { Entra.fix(for: $0, feed.need) ?? $0.localizedDescription } ?? "")
                }.joined(separator: "; "))
            }
            let events = reads.flatMap(\.1.events)
            let window = "from \(Entra.iso(since)) to \(Entra.iso(until))"
            let gaps = reads.contains { $0.1.error != nil || $0.1.cut || $0.1.off != nil }
            var lines: [String]
            if events.isEmpty {
                lines = [gaps ? "No watched events \(window) in what could be read; see below for what was not." : "No watched events \(window)."]
            } else {
                lines = GoogleCloud.inTurn(events, most: 80).map(\.line)
                if events.count > 80 { lines.append("\(events.count - 80) more in the structured result.") }
            }
            var unread: [String: String] = [:], off: [String: String] = [:], cut: [String] = []
            for (feed, read) in reads {
                if read.error == nil, read.off == nil { lines.append("Searched: \(feed.title) \(window), \(read.pages) page\(read.pages == 1 ? "" : "s").") }
                if let error = read.error {
                    lines.append("Could not read \(feed.title), so its silence is unknown: \(Entra.fix(for: error, feed.need) ?? error.localizedDescription)")
                    unread[feed.rawValue] = error.localizedDescription
                }
                if let reason = read.off { lines.append("Off: \(reason)"); off[feed.rawValue] = reason }
                if let reason = read.stopped {
                    lines.append("Incomplete: stopped at page \(read.pages + 1) of \(feed.title) because \(reason); what the pages before held is kept.")
                    cut.append(feed.rawValue)
                } else if read.cut {
                    lines.append("Cut short, with more not read: \(feed.title), past \(Entra.eventsPages) pages; narrow the window\(feed == .audit ? ", or use directory-audit with a category or activity" : "").")
                    cut.append(feed.rawValue)
                }
            }
            lines.append(Entra.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let couldNotRead: [String: String]; let off: [String: String]; let cutShort: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(events: events.sorted { $0.date > $1.date }, couldNotRead: unread, off: off, cutShort: cut,
                                                      complete: reads.allSatisfy { $0.1.complete && $0.1.error == nil }))
        }
    }

    /// The watch: each check reads every feed, each from six hours before the newest seen or before the last check that
    /// read it whole, whichever is later, as the audit log lists an entry minutes after it and Identity Protection may
    /// rate a user or sign-in hours after. What a check returned is remembered while Pion runs and left out of later
    /// checks, so what is read again is not news again; when a check finds more than it can return, it returns each kind
    /// in turn, tells once that more follow, and the checks after read again from the oldest left out until all of it is
    /// returned. A feed that reaches its page budget keeps Graph's $skiptoken and the query it belongs to, and the next
    /// check goes on with that query, never from a time, so however many entries share one moment the watch moves on
    /// through them; a query that ends leaves a boundary, its end less the six hours, which the feed reads on from
    /// however far the watch moved on meanwhile. Each feed keeps the oldest of what it owes until it is read whole and
    /// all it found returned. Nothing a check read is kept when it fails.
    ///
    /// A feed that cannot be read is never dropped unsaid: refused, the sign-in rejected, or Identity Protection without
    /// its licence, it is told as an alert of its own, which wakes the agents to read security-events, whose result
    /// names it and why. It is told once each time it starts, and again after a relaunch, dated at the start of the
    /// window read so it never moves the watch past what was not yet read. A $skiptoken Graph no longer takes is given
    /// up and its window read again from its start, told the same way. A failure that passes, such as Graph throttling,
    /// holds the watch back instead, a few checks at most, keeping nothing but how many checks in a row failed, and is
    /// then told the same way.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 6 * 3_600 }
        static let holdChecks = 6
        /// The most IDs of what was returned that one connection keeps, the newest first.
        static let remembered = 20_000

        /// What the checks of one connection keep between them while Pion runs.
        struct Kept: Sendable {
            var inARow: [String: Int] = [:], told: [String: String] = [:]
            /// By feed, when it was last read whole, and all it found returned, up to.
            var readUntil: [String: Date] = [:]
            /// What the checks returned, by ID, with when it happened.
            var delivered: [String: Date] = [:]
            /// By feed, the oldest of what a check owes: found but not returned, or not read at all. It moves on, or goes,
            /// only with a whole read of its feed.
            var owedFrom: [String: Date] = [:]
            /// By feed, a query cut short at the page budget, which the next checks go on with until it ends.
            var continuations: [String: Continuation] = [:]
            /// By feed, where a query that ended reads on from: its end, less the overlap, however far the watch moved on
            /// while it was read. It goes once a whole read from there returns all it found.
            var catchUp: [String: Date] = [:]
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// Whether Graph turned down the request itself, such as a $skiptoken it no longer takes, rather than the
        /// sign-in or for now.
        static func rejects(_ error: Error) -> Bool {
            switch error {
            case ServiceError.refused, ServiceError.notFound: true
            case ServiceError.status(let status, _): (400..<500).contains(status) && status != 408 && status != 429
            default: false
            }
        }

        /// Counts a check that failed for a reason that passes, keeping nothing else, and says which feeds hold it back.
        private func holding(_ labels: Set<String>, account: UUID?) -> [String] {
            var inARow: [String: Int] = [:]
            if let account {
                inARow = Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    watched.inARow = watched.inARow.filter { labels.contains($0.key) }
                    for label in labels { watched.inARow[label, default: 0] += 1 }
                    kept[account] = watched
                    return watched.inARow
                }
            }
            return labels.filter { (inARow[$0] ?? 1) <= Self.holdChecks }.sorted()
        }

        func alerts(since: Date, on service: ServiceClient, account: UUID?, now: Date = Date()) async throws -> [ServiceAlert] {
            let state = account.map { account in Self.kept.withLock { $0[account] ?? Kept() } } ?? Kept()
            let lookBack = lookBack
            // Each feed reads from what it owes, everything before having been returned or read whole; then from a
            // boundary a query left when it ended; otherwise from six hours before its last whole read, or from where the
            // watch is. A query cut short goes on with its own window.
            let start = { (feed: Feed) -> Date in
                if let query = state.continuations[feed.rawValue] { return query.since }
                var from = since
                if let owed = state.owedFrom[feed.rawValue] { from = owed }
                else if let boundary = state.catchUp[feed.rawValue] { from = boundary }
                else if let until = state.readUntil[feed.rawValue] { from = max(since, until.addingTimeInterval(-lookBack)) }
                // The audit log keeps 30 days with a licence, and refuses a search reaching further.
                return max(from, now.addingTimeInterval(-29 * 86_400))
            }
            var reads: [(feed: Feed, read: FeedRead)] = []
            for feed in Feed.allCases {
                reads.append((feed, await Entra.readFeed(feed, service, since: start(feed), until: now, pages: Entra.watchPages,
                                                         from: state.continuations[feed.rawValue])))
            }
            let failed = reads.filter { $0.read.error != nil }
            let passing = Set(failed.filter { GoogleWorkspace.isPassing($0.read.error!) }.map(\.feed.rawValue))
            // A feed that could not be read for now fails the whole check, so the watch reads the same window again, and
            // nothing else of it is kept but how many checks in a row it failed.
            let held = holding(passing, account: account)
            if !held.isEmpty {
                let titles = failed.filter { held.contains($0.feed.rawValue) }.map(\.feed.title)
                let said = failed.first { held.contains($0.feed.rawValue) }?.read.error?.localizedDescription ?? ""
                throw ServiceError.input("Could not read \(GoogleCloud.listed(titles)) for now; the next check reads the same window again. \(said)")
            }
            var seen = Set<String>()
            let events = reads.flatMap(\.read.events).filter { seen.insert($0.id).inserted }
            // Each event once: what earlier checks returned is left out before the room is counted.
            let pending = events.filter { state.delivered[$0.id] == nil }
            var notices: [(label: String, id: String)] = []
            var backlog = false
            for (feed, result) in reads {
                let label = feed.rawValue
                if result.error != nil { notices.append((label, "unreadable/\(label)")) }
                // A query a check before cut short that now fails is given up, and read again from its start: said.
                if result.error != nil, result.resumed != nil, Self.rejects(result.error!) { notices.append(("again/\(label)", "unchecked/\(label)")) }
                if result.off != nil { notices.append(("off/\(label)", "unreadable/\(label)")) }
                // A query cut short that the next checks go on with leaves no gap; while it holds back what is new, more
                // follow. One only catching up through what was returned before tells nothing.
                if let next = result.next {
                    backlog = backlog || next.owed != nil || pending.contains { $0.feed == label } || (result.resumed == nil && state.owedFrom[label] != nil)
                } else if result.cut { notices.append(("more/\(label)", "unchecked/\(label)")) }
            }
            // Once said, that more follow stays said while anything a feed found is still owed or a query is read on.
            if state.told["more/backlog"] != nil, reads.contains(where: { $0.read.next != nil || $0.read.resumed?.owed != nil }) || !state.owedFrom.isEmpty {
                backlog = true
            }
            if backlog || pending.count > ServiceAlert.most - notices.count { notices.append(("more/backlog", "unchecked/backlog")) }
            let complete = Dictionary(uniqueKeysWithValues: reads.map { ($0.feed.rawValue, $0.read.complete && $0.read.error == nil) })
            let results = Dictionary(uniqueKeysWithValues: reads.map { ($0.feed.rawValue, $0.read) })
            let starts = Dictionary(uniqueKeysWithValues: Feed.allCases.map { ($0.rawValue, start($0)) })
            let current = Set(notices.map(\.label))
            let update = { (watched: inout Kept) -> (told: [ServiceAlert], chosen: [WatchedEvent]) in
                watched.told = watched.told.filter { current.contains($0.key) }
                let new = notices.filter { watched.told[$0.label] == nil }.map { ($0.label, "\($0.id)/\(UUID().uuidString)") }
                for (label, id) in new { watched.told[label] = id }
                // Dated at the window's start, which is never after the newest seen, so it moves nothing on.
                let told = new.map { ServiceAlert(id: $0.1, time: since) }
                // The rest of what is new, each kind in turn; what has no room waits for the next check.
                let chosen = GoogleCloud.inTurn(pending, most: ServiceAlert.most - told.count)
                let ids = Set(chosen.map(\.id))
                let leftover = Dictionary(grouping: pending.filter { !ids.contains($0.id) }, by: \.feed).compactMapValues { $0.map(\.date).min() }
                var owed: [String: Date] = [:], continuations: [String: Continuation] = [:], readTo: [String: Date] = [:], catchUp: [String: Date] = [:]
                for feed in starts.keys {
                    let result = results[feed]
                    if var next = result?.next {
                        // A query cut short goes on next time with its token. What it owes is kept with it, and its start
                        // stays owed until it ends, so should it fail, it is read again from there.
                        next.owed = [next.owed, leftover[feed]].compactMap { $0 }.min()
                        continuations[feed] = next
                        if let start = starts[feed] { owed[feed] = start }
                        if let boundary = watched.catchUp[feed] { catchUp[feed] = boundary }
                        continue
                    }
                    if let query = result?.resumed, complete[feed] == true {
                        // A query gone on with to its end accounts for its window and nothing after it, however far the
                        // watch moved on while it was read: the feed owes from its end, with the overlap for what is
                        // listed late, or from the oldest it found but had no room for, until a whole read from there.
                        let boundary = query.until.addingTimeInterval(-lookBack)
                        if let held = [query.owed, leftover[feed]].compactMap({ $0 }).min() { owed[feed] = min(held, boundary) } else { catchUp[feed] = boundary }
                        continue
                    }
                    // A whole read accounts for everything its feed was owed. Any other, refused, cut short without a
                    // token, a query given up, or read only in part, keeps the oldest owed, and owes what it was asked to
                    // read too.
                    let value: Date? = if complete[feed] == true { leftover[feed] }
                        else { [watched.owedFrom[feed], result?.resumed?.owed, leftover[feed], starts[feed]].compactMap { $0 }.min() }
                    if let value { owed[feed] = value } else if complete[feed] == true { readTo[feed] = now }
                }
                // A boundary to catch up from stays until a whole read from it, or what it owes takes its place.
                for (feed, boundary) in watched.catchUp where catchUp[feed] == nil && owed[feed] == nil && readTo[feed] == nil && starts[feed] != nil {
                    catchUp[feed] = boundary
                }
                watched.owedFrom = owed
                watched.continuations = continuations
                watched.catchUp = catchUp
                for event in chosen { watched.delivered[event.id] = event.date }
                let oldest = (Array(starts.values) + Array(owed.values) + Array(catchUp.values) + continuations.values.compactMap(\.owed)).min() ?? since
                watched.delivered = watched.delivered.filter { $0.value >= oldest.addingTimeInterval(-60) }
                if watched.delivered.count > Self.remembered {
                    watched.delivered = Dictionary(uniqueKeysWithValues: watched.delivered.sorted { $0.value > $1.value }.prefix(Self.remembered).map { ($0.key, $0.value) })
                }
                // A feed counts as read up to a time only once all it found has been returned.
                for (feed, time) in readTo { watched.readUntil[feed] = time }
                return (told, chosen)
            }
            var scratch = state
            let (told, chosen) = account.map { account in
                Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    let result = update(&watched)
                    kept[account] = watched
                    return result
                }
            } ?? update(&scratch)
            if reads.allSatisfy({ $0.read.error != nil }), told.isEmpty, let first = failed.first?.read.error { throw first }
            return told + chosen.compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
        }
    }
}
