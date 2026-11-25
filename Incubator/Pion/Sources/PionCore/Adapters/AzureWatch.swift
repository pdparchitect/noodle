import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Microsoft Azure Detection's alert watch, and security-events, which reads back what woke the agents, the same way for
/// both: open high-severity Defender for Cloud alerts, for the plans turned on, and the activity log entries that open
/// the way in, hide what follows or stay: powerful roles granted, Key Vault access changed, logging deleted, locks and
/// policies removed, network rules opened to the internet, commands run on VMs, storage opened, and access elevated.
extension Azure {
    typealias WatchedEvent = GoogleCloud.WatchedEvent
    typealias JSON = GoogleCloud.JSON

    // MARK: Limits

    /// The resource providers whose activity the watch reads, one search each with the time range and success, as
    /// Azure's activity log takes a provider but not an operation: the most pressing first, so they are read first
    /// when requests run short.
    static let watchedProviders = ["Microsoft.Authorization", "Microsoft.Insights", "Microsoft.KeyVault", "Microsoft.Storage",
                                   "Microsoft.Network", "Microsoft.Compute"]
    /// The most activity log requests one check of the watch sends, and one call of security-events: Azure allows a
    /// subscription's reader thousands of reads an hour, so both leave most for investigations.
    static let watchRequests = 12, eventsRequests = 30
    /// The most pages of the directory activity log one read takes.
    static let directoryPages = 2

    // MARK: Watched activity

    /// Built-in roles that hand over the subscription or its access, by their definition's GUID, which is the same in
    /// every tenant.
    static let owner = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635", contributor = "b24988ac-6180-42a0-ab88-20f7382dd24c"
    static let userAccessAdministrator = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9", accessControlAdministrator = "f58310d9-a9f6-439a-9e8d-f62e7b41a168"
    static let watchedRoles = [owner: "Owner", contributor: "Contributor", userAccessAdministrator: "User Access Administrator",
                               accessControlAdministrator: "Role Based Access Control Administrator"]
    /// Of those, the roles that can grant access, which count wherever they are granted.
    static let grantingRoles: Set<String> = [owner, userAccessAdministrator, accessControlAdministrator]
    static let runCommands: Set<String> = ["microsoft.compute/virtualmachines/runcommand/action", "microsoft.compute/virtualmachines/runcommands/write",
                                           "microsoft.compute/virtualmachinescalesets/virtualmachines/runcommand/action",
                                           "microsoft.compute/virtualmachinescalesets/virtualmachines/runcommands/write"]
    /// Source addresses that mean anyone on the internet.
    static let anywhere: Set<String> = ["*", "0.0.0.0/0", "0.0.0.0", "::/0", "internet", "any"]

    /// An activity log entry as the watch reads it: what identifies it, and its request and response, judged when read
    /// and never kept.
    struct WatchedActivity: Decodable {
        let eventDataId: String?, eventTimestamp: String?, caller: String?, resourceId: String?, correlationId: String?
        let operationName: ActivityLog.Named?, httpRequest: ActivityLog.Request?
        let properties: [String: JSON]?
    }
    static let watchSelect = "eventDataId,eventTimestamp,caller,resourceId,correlationId,operationName,httpRequest,properties"

    /// The request's and response's bodies, as the activity log keeps them: text holding JSON, or JSON itself.
    static func bodies(_ properties: [String: JSON]?) -> [JSON] {
        (properties ?? [:]).sorted { $0.key < $1.key }.compactMap { key, value -> JSON? in
            guard ["requestbody", "responsebody"].contains(key.lowercased()) else { return nil }
            switch value {
            case .string(let text): return try? JSONDecoder().decode(JSON.self, from: Data(text.utf8))
            case .object: return value
            default: return nil
            }
        }
    }

    /// A field by its path, whatever its case, as Azure writes both Properties and properties.
    static func field(_ json: JSON?, _ path: [String]) -> JSON? {
        var current = json
        for name in path {
            guard case .object(let object)? = current else { return nil }
            current = object.first { $0.key.lowercased() == name.lowercased() }?.value
        }
        return current
    }

    static func flag(_ value: JSON?) -> Bool? {
        switch value {
        case .bool(let flag)?: flag
        case .string(let text)?: ["true": true, "false": false][text.lowercased()]
        default: nil
        }
    }

    static func texts(_ value: JSON?) -> [String] {
        switch value {
        case .string(let text)?: [text]
        case .array(let items)?: items.compactMap(\.text)
        default: []
        }
    }

    /// A network security rule letting the internet in: the sources and ports it opens, or nil for one that does not.
    static func opening(_ rule: JSON?) -> String? {
        let properties = field(rule, ["properties"]) ?? rule
        guard texts(field(properties, ["access"])).first?.lowercased() == "allow",
              texts(field(properties, ["direction"])).first?.lowercased() == "inbound" else { return nil }
        let sources = texts(field(properties, ["sourceAddressPrefix"])) + texts(field(properties, ["sourceAddressPrefixes"]))
        let open = sources.filter { anywhere.contains($0.lowercased()) }
        guard !open.isEmpty else { return nil }
        let ports = texts(field(properties, ["destinationPortRange"])) + texts(field(properties, ["destinationPortRanges"]))
        return "lets in \(open.joined(separator: ", ")) to port\(ports.count == 1 && ports != ["*"] ? "" : "s") \(ports.isEmpty ? "*" : ports.joined(separator: ", "))"
    }

    /// What an entry did that the watch wakes for, the most pressing first, or nil for one it does not. `subscription`
    /// tells a grant on the whole subscription from one on a part of it.
    static func judge(_ event: WatchedActivity, subscription: String) -> (tier: Int, kind: String, what: String)? {
        let operation = event.operationName?.value?.lowercased() ?? "", resource = event.resourceId ?? ""
        let bodies = bodies(event.properties)
        func first(_ path: String...) -> JSON? { bodies.lazy.compactMap { field($0, path) }.first }
        switch operation {
        case "microsoft.authorization/roleassignments/write":
            let role = first("properties", "roleDefinitionId")?.text.map(RoleAssignments.roleKey)
            let to = first("properties", "principalId")?.text.map { " to \($0)" } ?? ""
            let scope = first("properties", "scope")?.text
                ?? resource.range(of: "/providers/Microsoft.Authorization/roleAssignments/", options: .caseInsensitive).map { String(resource[..<$0.lowerBound]) } ?? resource
            let whole = ["/subscriptions/\(subscription)".lowercased(), "/subscriptions/\(subscription)/".lowercased()].contains(scope.lowercased())
            let name = role.flatMap { watchedRoles[$0] }
            if scope.lowercased().contains("/providers/microsoft.keyvault/vaults/") {
                return (1, "Key Vault access changed", "\(name ?? role.map { "role \($0)" } ?? "a role") granted\(to) on Key Vault \(scope)")
            }
            if let name, whole { return (0, "powerful role granted", "\(name) granted\(to) on the subscription") }
            if let role, let name, grantingRoles.contains(role) { return (1, "powerful role granted", "\(name) granted\(to) on \(scope)") }
            if role == nil, whole { return (1, "role granted", "a role granted\(to) on the subscription; the log does not show which") }
            return nil
        case "microsoft.authorization/elevateaccess/action":
            return (0, "access elevated", "a Global Administrator elevated their access to every subscription in the directory")
        case "microsoft.insights/diagnosticsettings/delete":
            return (0, "logging turned off", "diagnostic setting deleted, so logs it sent elsewhere stop")
        case "microsoft.insights/logprofiles/delete":
            return (0, "logging turned off", "activity log profile deleted")
        case _ where runCommands.contains(operation):
            return (0, "command run on a VM", "command run on a VM; the log does not show the script")
        case "microsoft.authorization/locks/delete":
            return (1, "protection removed", "resource lock deleted")
        case "microsoft.authorization/policyassignments/delete":
            return (1, "protection removed", "policy assignment deleted")
        case "microsoft.authorization/policyexemptions/write":
            return (1, "protection removed", "policy exemption made")
        case "microsoft.network/networksecuritygroups/securityrules/write":
            if bodies.isEmpty { return (2, "network rule changed", "network security rule changed; the log does not show the rule") }
            return bodies.lazy.compactMap(opening).first.map { (1, "network opened to the internet", "network security rule \($0)") }
        case "microsoft.network/networksecuritygroups/write":
            guard case .array(let rules)? = first("properties", "securityRules") else { return nil }
            return rules.lazy.compactMap(opening).first.map { (1, "network opened to the internet", "network security group rule \($0)") }
        case "microsoft.storage/storageaccounts/write":
            var what: [String] = []
            if flag(first("properties", "allowBlobPublicAccess")) == true { what.append("anonymous public blob access allowed") }
            if flag(first("properties", "allowSharedKeyAccess")) == true { what.append("shared key access allowed") }
            return what.isEmpty ? nil : (1, "storage opened", "storage account: " + what.joined(separator: " and "))
        case "microsoft.storage/storageaccounts/blobservices/containers/write":
            guard let level = first("properties", "publicAccess")?.text, ["blob", "container"].contains(level.lowercased()) else { return nil }
            return (1, "storage opened", "blob container made public (\(level))")
        case "microsoft.keyvault/vaults/accesspolicies/write":
            return (1, "Key Vault access changed", "Key Vault access policy changed")
        case "microsoft.keyvault/vaults/write":
            if bodies.isEmpty { return (2, "Key Vault access changed", "Key Vault changed; the log does not show what") }
            var what: [String] = []
            if case .array(let policies)? = first("properties", "accessPolicies"), !policies.isEmpty { what.append("access policies set") }
            if let rbac = flag(first("properties", "enableRbacAuthorization")) { what.append("access by Azure roles \(rbac ? "on" : "off")") }
            if first("properties", "networkAcls", "defaultAction")?.text?.lowercased() == "allow" { what.append("its firewall allows all networks") }
            return what.isEmpty ? nil : (1, "Key Vault access changed", "Key Vault " + what.joined(separator: ", "))
        default:
            return nil
        }
    }

    static func skipToken(_ link: String?) -> String? {
        link.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name.lowercased() == "$skiptoken" }?.value }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What one read of the activity log found, and what it could not read.
    struct ActivityRead {
        var events: [WatchedEvent] = [], searched: [String] = [], requests = 0
        var failed: [(provider: String, error: Error)] = []
        /// Providers with more than the requests left could read.
        var cut: [String] = []
    }

    static func line(_ event: WatchedActivity, _ what: String) -> String {
        var line = "\(event.eventTimestamp ?? "?") \(what): \(event.operationName?.value ?? "?") on \(event.resourceId ?? "?") by \(event.caller ?? "?")"
        if let ip = event.httpRequest?.clientIpAddress { line += " from \(ip)" }
        return line + " [\(event.eventDataId ?? "?")]"
    }

    /// The watched activity of the subscription from `since` to `until`: a search of successful operations for each
    /// watched provider, a first page each, then reading on, the first providers first, within `budget` requests.
    static func readActivity(_ service: ServiceClient, since: String, until: String, budget: Int) async -> ActivityRead {
        var read = ActivityRead()
        let subscription: String, path: [String]
        do {
            subscription = try Azure.subscription(service)
            path = try Azure.path(service, "Microsoft.Insights", "eventtypes") + ["management", "values"]
        } catch {
            read.failed = watchedProviders.map { ($0, error) }
            return read
        }
        func page(_ provider: String, _ token: String?) async throws -> List<WatchedActivity> {
            read.requests += 1
            let filter = "eventTimestamp ge '\(since)' and eventTimestamp le '\(until)' and resourceProvider eq '\(provider)' and status eq 'Succeeded'"
            return try await Azure.read(.activity) {
                try await service.get(path, query: ["api-version": activityVersion, "$filter": filter, "$select": watchSelect, "$skipToken": token],
                                      as: List<WatchedActivity>.self)
            }
        }
        var found: [WatchedActivity] = [], tokens: [(provider: String, token: String)] = []
        func take(_ provider: String, _ answer: List<WatchedActivity>, first: Bool) {
            found += answer.value
            guard answer.nextLink?.isEmpty == false else { return }
            if let token = skipToken(answer.nextLink) { tokens.insert((provider, token), at: first ? tokens.endIndex : 0) } else { read.cut.append(provider) }
        }
        for provider in watchedProviders {
            guard read.requests < budget else { read.cut.append(provider); continue }
            do {
                take(provider, try await page(provider, nil), first: true)
                read.searched.append(provider)
            } catch {
                read.failed.append((provider, error))
            }
        }
        while let next = tokens.first, read.requests < budget {
            tokens.removeFirst()
            do { take(next.provider, try await page(next.provider, next.token), first: false) } catch { read.cut.append(next.provider) }
        }
        read.cut += tokens.map(\.provider)
        read.cut = Array(Set(read.cut)).sorted { (watchedProviders.firstIndex(of: $0) ?? 0) < (watchedProviders.firstIndex(of: $1) ?? 0) }
        var seen = Set<String>()
        for event in found {
            guard let id = event.eventDataId, seen.insert(id).inserted, let time = event.eventTimestamp,
                  let judged = judge(event, subscription: subscription) else { continue }
            read.events.append(WatchedEvent(id: safeID("activity/", id), time: time, tier: judged.tier, kind: judged.kind, feed: "activity-log",
                                            line: line(event, judged.what)))
        }
        return read
    }

    /// Access elevated by a Global Administrator, which Azure records only in the directory's own activity log: it
    /// needs a role at the root scope, which few apps have, so what stops it being read is a gap said in results, not
    /// a wake.
    static func readDirectory(_ service: ServiceClient, since: String, until: String) async -> (events: [WatchedEvent], error: Error?, cut: Bool) {
        let filter = "eventTimestamp ge '\(since)' and eventTimestamp le '\(until)' and resourceProvider eq 'Microsoft.Authorization'"
        do {
            let listing = try await Azure.read(.directory) {
                try await list(service, path: ["providers", "Microsoft.Insights", "eventtypes", "management", "values"],
                               query: ["api-version": activityVersion, "$filter": filter, "$select": watchSelect], as: WatchedActivity.self,
                               pages: directoryPages) { $0.operationName?.value?.lowercased() == "microsoft.authorization/elevateaccess/action" }
            }
            let subscription = (try? Azure.subscription(service)) ?? ""
            let events = listing.value.compactMap { event -> WatchedEvent? in
                guard let id = event.eventDataId, let time = event.eventTimestamp, let judged = judge(event, subscription: subscription) else { return nil }
                return WatchedEvent(id: safeID("directory/", id), time: time, tier: judged.tier, kind: judged.kind, feed: "directory", line: line(event, judged.what))
            }
            return (events, nil, listing.more)
        } catch {
            return ([], error, false)
        }
    }

    /// Open high-severity Defender for Cloud alerts that reached it from `since` on, and whether there were more than
    /// one listing reads.
    static func readAlerts(_ service: ServiceClient, since: Date, until: Date?) async -> (events: [WatchedEvent], error: Error?, cut: Bool) {
        do {
            let listing = try await alerts(service)
            let events = listing.value.compactMap { alert -> WatchedEvent? in
                guard alert.properties?.severity == "High", alert.open, let time = alert.time, time >= since, until.map({ time <= $0 }) ?? true else { return nil }
                let line = "\(ISO8601DateFormatter().string(from: time)) High Defender for Cloud alert \(alert.properties?.alertDisplayName ?? "?") — \(alert.properties?.compromisedEntity ?? "?") (\(alert.properties?.status ?? "?")) [\(alert.id)]"
                return WatchedEvent(id: safeID("defender/", alert.id), time: ISO8601DateFormatter().string(from: time), tier: 0, kind: "Defender for Cloud alert",
                                    feed: "defender-alerts", line: line)
            }
            return (events, nil, listing.more)
        } catch {
            return ([], error, false)
        }
    }

    // MARK: Every feed

    static func feed(_ label: String) -> String {
        ["defender-alerts": "Defender for Cloud alerts", "defender-plans": "Defender for Cloud plans", "activity-log": "the activity log",
         "directory": "the directory activity log"][label] ?? label
    }

    /// What one read of every feed found, and what it could not read, by feed.
    struct WatchRead {
        var events: [WatchedEvent] = []
        /// Feeds that could not be read, told as a wake, with why and whether it failed for a reason that passes.
        var unreadable: [(label: String, reason: String, passing: Bool)] = []
        /// Feeds with more than one read takes.
        var cut: [String] = []
        var alertsRead = false, activity = ActivityRead(), directoryError: Error? = nil
        /// What the Defender plans said, when read: nil when a plan that raises alerts is on.
        var plansRead = false, planNotice: String? = nil, planError: Error? = nil
        var nothingRead: Bool { !alertsRead && activity.searched.isEmpty }

        func coverage(window: String) -> [String] {
            var lines: [String] = []
            if alertsRead { lines.append("Searched: open high-severity Defender for Cloud alerts of the subscription that reached it \(window).") }
            if !activity.searched.isEmpty {
                lines.append("Searched: the activity log's successful \(GoogleCloud.listed(activity.searched)) operations \(window), for the watched changes.")
            }
            if directoryError == nil { lines.append("Searched: the directory activity log \(window), for access elevated.") }
            for (label, reason, _) in unreadable { lines.append("Could not read \(Azure.feed(label)): \(reason)") }
            if let error = directoryError {
                lines.append("Could not read the directory activity log, so a Global Administrator elevating access is not seen: \(Azure.fix(for: error, .directory) ?? error.localizedDescription)")
            }
            if let error = planError {
                lines.append("Which Defender for Cloud plans are on could not be read, so whether no alerts means none is unknown: \(Azure.fix(for: error, .plans) ?? error.localizedDescription)")
            }
            if cut.contains("defender-alerts") { lines.append("Cut short, with more not read: Defender for Cloud alerts, past \(Azure.maximumPages) pages; use defender-alerts with a severity and since.") }
            if !activity.cut.isEmpty {
                lines.append("Cut short, with more not read: the activity of \(GoogleCloud.listed(activity.cut)); narrow the window, or use activity-log with resourceProvider and operation.")
            }
            if cut.contains("directory") { lines.append("Cut short, with more not read: the directory activity log; narrow the window.") }
            return lines
        }
    }

    /// Every feed from `since` to `until`: the alerts, the Defender plans when `readPlans`, otherwise `planNotice` as
    /// read before, the activity log from `activitySince` within `budget` requests, and the directory's. Each is kept
    /// when another cannot be read; the same for the watch and security-events, so what woke the agents reads back the
    /// same.
    static func watchedEvents(_ service: ServiceClient, since: String, until: String?, activitySince: String? = nil, budget: Int,
                              readPlans: Bool = true, planNotice: String? = nil) async throws -> WatchRead {
        _ = try subscription(service)
        var read = WatchRead()
        let end = until ?? ISO8601DateFormatter().string(from: Date())
        let alerts = await readAlerts(service, since: ServiceAlert.time(since) ?? .distantPast, until: until.flatMap { ServiceAlert.time($0) })
        if let error = alerts.error { read.unreadable.append(("defender-alerts", error.localizedDescription, GoogleWorkspace.isPassing(error))) } else { read.alertsRead = true }
        if alerts.cut { read.cut.append("defender-alerts") }
        if readPlans {
            do {
                let plans = try await Azure.plans(service)
                read.plansRead = true
                if plans.on.isEmpty {
                    read.planNotice = "no Defender for Cloud plan that raises threat alerts is on, so its alerts stay silent whatever happens: turn on plans such as Defender for Servers, Storage or Key Vault in Defender for Cloud's Environment settings."
                }
            } catch {
                read.planError = error
            }
        } else {
            read.planNotice = planNotice
        }
        if let notice = read.planNotice { read.unreadable.append(("defender-plans", notice, false)) }
        read.activity = await readActivity(service, since: activitySince ?? since, until: end, budget: budget)
        if !read.activity.failed.isEmpty {
            let reasons = Array(Set(read.activity.failed.map { $0.error.localizedDescription })).sorted().joined(separator: "; ")
            read.unreadable.append(("activity-log", "\(GoogleCloud.listed(read.activity.failed.map(\.provider))): \(reasons)",
                                    read.activity.failed.allSatisfy { GoogleWorkspace.isPassing($0.error) }))
        }
        if !read.activity.cut.isEmpty { read.cut.append("activity-log") }
        let directory = await readDirectory(service, since: activitySince ?? since, until: end)
        read.directoryError = directory.error
        if directory.cut { read.cut.append("directory") }
        read.events = (alerts.events + read.activity.events + directory.events).sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
        return read
    }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: reads of data, such as blobs downloaded or secrets read, which the activity log does not record (they need diagnostic settings sending resource logs to a Log Analytics workspace, which Microsoft Sentinel reads); sign-ins and Microsoft Entra changes, which Microsoft Entra ID reads; storage accounts opened and network rules changed whose request the log leaves out, which are said when the log shows nothing to judge them by; roles granted below the subscription other than Owner, User Access Administrator and Role Based Access Control Administrator; medium and low alerts; and failed operations, which activity-log finds with failuresOnly."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: open high-severity Defender for Cloud alerts, and activity log entries that open the way in or hide what follows: Owner, Contributor, User Access Administrator or Role Based Access Control Administrator granted on the subscription, Key Vault access changed, diagnostic settings deleted, locks and policy assignments removed, network rules opened to the internet, commands run on VMs, storage opened to public or shared key access, and access elevated by a Global Administrator; saying what it searched, what it could not read and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try ActivityLog.window(input.since, input.until, days: 1)
            let read = try await Azure.watchedEvents(service, since: since, until: until, budget: Azure.eventsRequests)
            if read.nothingRead {
                throw ServiceError.input("Nothing could be read: " + read.unreadable.map { "\(Azure.feed($0.label)): \($0.reason)" }.joined(separator: "; "))
            }
            let window = "from \(since) to \(until)"
            var lines: [String]
            if read.events.isEmpty {
                lines = [read.unreadable.isEmpty && read.cut.isEmpty && read.directoryError == nil ? "No watched events \(window)." : "No watched events \(window) in what could be read; see below for what was not."]
            } else {
                lines = GoogleCloud.inTurn(read.events, most: 80).map(\.line)
                if read.events.count > 80 { lines.append("\(read.events.count - 80) more in the structured result.") }
            }
            lines += read.coverage(window: window)
            lines.append(Azure.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let couldNotRead: [String: String]; let cutShort: [String]; let searched: [String] }
            var unread = Dictionary(read.unreadable.map { ($0.label, $0.reason) }, uniquingKeysWith: { "\($0); \($1)" })
            if let error = read.directoryError { unread["directory"] = error.localizedDescription }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(events: read.events, couldNotRead: unread, cutShort: read.cut,
                                                                                           searched: read.activity.searched))
        }
    }

    /// The watch: each check reads every feed from `since` on, six hours back from the newest seen, as Defender for
    /// Cloud may list an alert hours after its time and the activity log minutes after; within a run of Pion, the
    /// activity log is read only from six hours before the last check that read it whole. An alert is dated when it
    /// reached Defender for Cloud, so one listed late still falls in the window. What a check returned is remembered
    /// while Pion runs and left out of later checks, so what is read again is not news again; when a check finds more
    /// than it can return, it returns each kind in turn, tells once that more follow, and the checks after read again
    /// from the oldest left out until all of it is returned. Nothing a check read is kept when it fails.
    ///
    /// A feed that cannot be read is never dropped unsaid: alerts or activity refused, the sign-in failing, or no
    /// Defender plan that raises alerts turned on, is told as an alert of its own, which wakes the agents to read
    /// security-events, whose result names it and why. It is told once for each time it starts, and again after a
    /// relaunch, dated at the start of the window read so it never moves the watch past what was not yet read; one cut
    /// short is told the same way. A failure that passes, such as Azure being busy, holds the watch back instead, a few
    /// checks at most, and is then told the same way. The directory's activity log needs a role few apps have, so it
    /// is said in security-events, not told as a wake.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 6 * 3_600 }
        static let holdChecks = 6
        /// How often the Defender plans are read again.
        static let replans: TimeInterval = 3_600
        /// The most IDs of what was returned that one account keeps, the newest first.
        static let remembered = 20_000

        /// What the checks of one account keep between them while Pion runs.
        struct Kept: Sendable {
            var inARow: [String: Int] = [:], told: [String: String] = [:]
            /// When the activity log was last read whole, and all it found returned, up to.
            var readUntil: Date? = nil
            var plansRead: Date? = nil, planNotice: String? = nil
            /// What the checks returned, by ID, with when it happened, so a later check reading the same window leaves
            /// it out and returns what one check had no room for instead.
            var delivered: [String: Date] = [:]
            /// By feed, the oldest of what a check found but had no room to return, which the checks after read from.
            /// It moves on, or goes, only with a whole read of its feed: a feed refused, cut short or read in part
            /// keeps the oldest boundary owed, however far the watch has moved on meanwhile.
            var owedFrom: [String: Date] = [:]
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        func alerts(since: Date, on service: ServiceClient, account: UUID?, now: Date = Date()) async throws -> [ServiceAlert] {
            let state = account.map { account in Self.kept.withLock { $0[account] ?? Kept() } } ?? Kept()
            // What a check before had no room for is read again, however far the watch has moved on.
            let from = min(since, state.owedFrom.values.min() ?? since)
            let readPlans = state.plansRead.map { now.timeIntervalSince($0) >= Self.replans } ?? true
            // The activity log and the directory's share a window: from what either is owed, otherwise from six hours
            // before the last whole read.
            var activitySince = from
            if state.owedFrom["activity-log"] == nil, state.owedFrom["directory"] == nil, let readUntil = state.readUntil {
                activitySince = max(from, readUntil.addingTimeInterval(-lookBack))
            }
            // The activity log keeps 90 days and refuses a search reaching further.
            activitySince = max(activitySince, now.addingTimeInterval(-89 * 86_400))
            let format = ISO8601DateFormatter()
            let read = try await Azure.watchedEvents(service, since: format.string(from: from), until: nil, activitySince: format.string(from: activitySince),
                                                     budget: Azure.watchRequests, readPlans: readPlans, planNotice: state.planNotice)
            let passing = Set(read.unreadable.filter(\.passing).map(\.label))
            // Only how many checks in a row each feed failed for now is kept before the check may still fail.
            var inARow: [String: Int] = [:]
            if let account {
                inARow = Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    watched.inARow = watched.inARow.filter { passing.contains($0.key) }
                    for label in passing { watched.inARow[label, default: 0] += 1 }
                    kept[account] = watched
                    return watched.inARow
                }
            }
            // A feed that could not be read for now fails the whole check, so the watch reads the same window again,
            // and nothing else of it is kept: what it read is read again, and the activity log from where it was.
            let held = passing.filter { (inARow[$0] ?? 1) <= Self.holdChecks }.sorted()
            if !held.isEmpty {
                throw ServiceError.input("Could not read \(GoogleCloud.listed(held.map(Azure.feed))) for now; the next check reads the same window again.")
            }
            // The directory's log is said in security-events, never woken for.
            var notices = read.unreadable.map { ($0.label, "unreadable/\($0.label)") } + read.cut.filter { $0 != "directory" }.map { ("more/\($0)", "unchecked/\($0)") }
            let pending = read.events.filter { state.delivered[$0.id] == nil }
            // Which feeds were read whole: every page, nothing refused.
            let complete = ["defender-alerts": read.alertsRead && !read.cut.contains("defender-alerts"),
                            "activity-log": read.activity.failed.isEmpty && read.activity.cut.isEmpty,
                            "directory": read.directoryError == nil && !read.cut.contains("directory")]
            if pending.count > ServiceAlert.most - notices.count { notices.append(("more/backlog", "unchecked/backlog")) }
            let current = Set(notices.map(\.0))
            let update = { (watched: inout Kept) -> (told: [ServiceAlert], chosen: [WatchedEvent]) in
                watched.told = watched.told.filter { current.contains($0.key) }
                let new = notices.filter { watched.told[$0.0] == nil }.map { ($0.0, "\($0.1)/\(UUID().uuidString)") }
                for (label, id) in new { watched.told[label] = id }
                // Dated at the window's start, which is never after the newest seen, so it moves nothing on.
                let told = new.map { ServiceAlert(id: $0.1, time: since) }
                // The rest of what is new, each kind in turn; what has no room waits for the next check.
                let chosen = GoogleCloud.inTurn(pending, most: ServiceAlert.most - told.count)
                let ids = Set(chosen.map(\.id))
                let leftover = Dictionary(grouping: pending.filter { !ids.contains($0.id) }, by: \.feed).compactMapValues { $0.map(\.date).min() }
                var owed: [String: Date] = [:]
                for feed in Set(watched.owedFrom.keys).union(leftover.keys) {
                    // A whole read of the feed accounts for everything it was owed; any other keeps the oldest.
                    let value = complete[feed] == true ? leftover[feed] : [watched.owedFrom[feed], leftover[feed]].compactMap { $0 }.min()
                    if let value { owed[feed] = value }
                }
                watched.owedFrom = owed
                for event in chosen { watched.delivered[event.id] = event.date }
                watched.delivered = watched.delivered.filter { $0.value >= from.addingTimeInterval(-60) }
                if watched.delivered.count > Self.remembered {
                    watched.delivered = Dictionary(uniqueKeysWithValues: watched.delivered.sorted { $0.value > $1.value }.prefix(Self.remembered).map { ($0.key, $0.value) })
                }
                // The activity log counts as read up to now only once all it found has been returned.
                if complete["activity-log"] == true, watched.owedFrom["activity-log"] == nil { watched.readUntil = now }
                if read.plansRead { watched.plansRead = now; watched.planNotice = read.planNotice }
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
            if read.nothingRead, told.isEmpty, let first = read.unreadable.first { throw ServiceError.input(first.reason) }
            return told + chosen.compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
        }
    }
}
