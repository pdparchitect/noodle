import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Vercel Detection's reads of what happened, its alert watch, and security-events, which reads back what woke the
/// agents, the same way for both: high-risk changes in the team's activity log, and attacks the Vercel Firewall
/// detected on its projects.
///
/// Vercel's Audit Log, on Enterprise plans for Owners and the Security role, is exported as a file or sent to an
/// Audit Log Drain and has no API to read it, so Pion reads the team's Activity Log, which every plan keeps and the API
/// lists, instead.
extension Vercel {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Limits

    /// The most pages of the activity log one check of the watch reads, and one call of security-events or activity-log.
    static let watchPages = 4, eventsPages = 10
    /// How many events each page of the activity log asks for; tests ask for fewer.
    @TaskLocal static var activityPage = 100
    /// The most projects whose attacks the watch and security-events read, one request each, most recently changed first.
    static let attackProjects = 20
    /// How far back reads by time may reach.
    static let keptDays = 90.0

    // MARK: The activity log

    /// What one read of the activity log found, and how far it got.
    struct Activity {
        var events: [Value] = []
        var complete = false
        var pages = 0
        /// The time of the oldest event read, when it stopped before the window's start.
        var oldest: Date? = nil
        var stopped: String? = nil
    }

    /// The activity log from `since` to `until`, newest first, page after page: each next page asks for what came at
    /// or before the oldest event the last one gave, and events read twice are kept once. It stops, saying so, at a
    /// page that brings nothing new; when a page after the first fails, what earlier pages held is kept, unless
    /// `partial` is false.
    static func activity(_ service: ServiceClient, since: Date, until: Date, types: [String] = [], principal: String? = nil, projects: [String] = [],
                         pages: Int, partial: Bool = true) async throws -> Activity {
        var read = Activity()
        var seen = Set<String>()
        var upTo = until
        let size = activityPage
        while read.pages < pages {
            let page: [Value]
            do {
                let body = try await get(service, ["v3", "events"], query: [
                    "since": isoMilliseconds(since), "until": isoMilliseconds(upTo), "limit": String(size),
                    "types": types.isEmpty ? nil : types.joined(separator: ","), "principalId": principal,
                    "projectIds": projects.isEmpty ? nil : projects.joined(separator: ","),
                ], as: Value.self)
                guard let events = body["events"]?.items else { throw ServiceError.unreadable }
                page = events
            } catch {
                guard partial, read.pages > 0 else { throw error }
                read.stopped = error.localizedDescription
                return read
            }
            read.pages += 1
            let fresh = page.filter { event in event.text("id").map { seen.insert($0).inserted } ?? false }
            read.events += fresh
            let oldest = page.compactMap { $0.date("createdAt") }.min()
            if page.count < size {
                read.complete = true
                read.oldest = nil
                return read
            }
            guard !fresh.isEmpty, let oldest, oldest > since else {
                if fresh.isEmpty {
                    read.stopped = "Vercel gave the same events again at \(iso(upTo)), more than one page of them at one moment"
                    read.oldest = upTo
                } else { read.complete = true }
                return read
            }
            read.oldest = oldest
            upTo = oldest
        }
        return read
    }

    /// A time as the activity log's query takes it: ISO 8601 with milliseconds.
    static func isoMilliseconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Who did it: the user, app or integration Vercel names, and how.
    static func actor(_ event: Value) -> String {
        let principal = event["principal"]
        let who = principal?.text("username") ?? principal?.text("email") ?? principal?.text("name") ?? principal?.text("clientId")
            ?? event.text("user.username") ?? event.text("user.email") ?? event.text("principalId") ?? event.text("userId") ?? "?"
        let kind = principal?.text("type").flatMap { $0 == "user" ? nil : $0 }
        return who + (kind.map { " (\($0))" } ?? "")
    }

    static func eventLine(_ event: Value) -> String {
        let text = event.text("text").map { String($0.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(240)) } ?? "no text given"
        return "\(event.time("createdAt") ?? "?") \(event.text("type") ?? "event") by \(actor(event)): \(text) [\(event.text("id") ?? "?")]"
    }

    struct ActivityLog: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?; let until: String?; let types: [String]?; let principal: String?; let project: String?; let limit: Int? }
        static let name = "activity-log"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The team's Activity Log, newest first, by event type, who acted, project and time: who created tokens, added or removed members and changed roles, read or changed environment variables, changed the firewall, protection and domains, deployed and rolled back, with Vercel's own sentence for each. Every plan keeps it. Vercel's Enterprise Audit Log is exported or drained, not read through the API, so it is not this."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "types": .array(.string("An event type, such as user-token-created, team-member-add or env-variable-read:cli:env:pull."), "Only these event types."),
            "principal": .string("Only what this user, by their user ID as members gives it, did."),
            "project": .string("Only events about this project, by its name or ID."),
            "limit": .integer("How many events, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = try Vercel.limit(input.limit, default: 50, maximum: 500, "events")
            let (since, until) = try Vercel.window(input.since, input.until, days: 7, maximum: Vercel.keptDays)
            let types = try (input.types ?? []).map { type -> String in
                guard (1...100).contains(type.count), type.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || "-_:".contains($0)) }) else {
                    throw ServiceError.input("Give event types as Vercel names them, such as user-token-created.")
                }
                return type
            }
            let principal = try input.principal.map { try Vercel.id($0, "the user's ID") }
            var project: Value? = nil
            if let named = input.project { project = try await Vercel.project(named, service, need: Vercel.activityNeed) }
            let read = try await Vercel.read(Vercel.activityNeed) {
                try await Vercel.activity(service, since: since, until: until, types: types, principal: principal,
                                          projects: project?.text("id").map { [$0] } ?? [], pages: Vercel.eventsPages)
            }
            let events = read.events.sorted { ($0.date("createdAt") ?? .distantPast) > ($1.date("createdAt") ?? .distantPast) }
            let kept = Array(events.prefix(limit))
            let window = "from \(Vercel.iso(since)) to \(Vercel.iso(until))"
            var text = kept.isEmpty ? "No activity log events match \(window)." : "\(Vercel.plural(kept.count, "event")) \(window), newest first:\n" + kept.map(Vercel.eventLine).joined(separator: "\n")
            if events.count > limit { text += "\nMore events match than the \(kept.count) kept, the newest: narrow the window or the types, or raise the limit." }
            if let reason = read.stopped { text += "\nIncomplete: stopped after \(Vercel.plural(read.pages, "page")) because \(reason); events before \(read.oldest.map(Vercel.iso) ?? "the last read") were not read." }
            else if !read.complete { text += "\nIncomplete: stopped after \(Vercel.plural(read.pages, "page")), the most read at once; events before \(read.oldest.map(Vercel.iso) ?? "the last read") were not read." }
            struct Event: Encodable { let id: String?; let time: String?; let type: String?; let actor: String; let text: String? }
            struct Kept: Encodable { let events: [Event]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(events: kept.map { Event(id: $0.text("id"), time: $0.time("createdAt"), type: $0.text("type"), actor: Vercel.actor($0), text: $0.text("text")) },
                                                                 complete: read.complete && read.stopped == nil && events.count <= limit))
        }
    }

    // MARK: The firewall's actions and attacks

    /// A time Vercel gives as ISO 8601, or as milliseconds since 1970 in a string or number.
    static func when(_ value: Value?) -> Date? {
        guard let value else { return nil }
        if let number = value.number ?? value.text.flatMap(Double.init) { return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1_000 : number) }
        return ServiceAlert.time(value.text)
    }

    struct FirewallEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String; let since: String?; let until: String?; let ip: String?; let action: String?; let limit: Int? }
        static let name = "firewall-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What the Vercel Firewall did on one project, newest first: each action (deny, challenge, log, rate limit, bypass) against one client IP on one host, with how many requests, when, whether it is still going on and the rule, Vercel's own or the team's; and any attack Vercel detected on it, such as a DDoS, with the hosts it hit."
        static let input = JSONSchema.object([
            "project": .string("The project, by its name or ID."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "ip": .string("Only actions against this client IP address."),
            "action": .string("Only this action.", oneOf: ["deny", "challenge", "log", "rate_limit", "bypass"]),
            "limit": .integer("How many actions, at most. 100 when left out.", minimum: 1, maximum: 1_000),
        ], required: ["project"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = try Vercel.limit(input.limit, default: 100, maximum: 1_000, "actions")
            let (since, until) = try Vercel.window(input.since, input.until, days: 1, maximum: 30)
            let ip = try input.ip.map(ServiceInput.ip)
            let action = try input.action.map { try ServiceInput.oneOf($0, ["deny", "challenge", "log", "rate_limit", "bypass"], "action") }
            let project = try await Vercel.project(input.project, service, need: Vercel.firewallNeed)
            guard let projectID = project.text("id") else { throw ServiceError.unreadable }
            var query: [String: String?] = ["projectId": projectID, "startTimestamp": Vercel.milliseconds(since), "endTimestamp": Vercel.milliseconds(until),
                                            "sort": "startTime:desc", "limit": String(min(limit, 500)), "action": action, "ip": ip]
            var actions: [Value] = [], pages = 0, more = false, stopped: String?
            var cursors = Set<String>()
            while pages < 5, actions.count < limit {
                let body: Value
                do { body = try await Vercel.read(Vercel.firewallNeed) { try await Vercel.get(service, ["v1", "security", "firewall", "events"], query: query, as: Value.self) } }
                catch { if pages == 0 { throw error }; stopped = error.localizedDescription; break }
                guard let page = body["actions"]?.items else { if pages == 0 { throw ServiceError.unreadable }; stopped = "a page could not be read"; break }
                pages += 1
                actions += page
                let next = body.text("pagination.next")
                more = next != nil
                guard let next else { break }
                guard cursors.insert(next).inserted else { stopped = "Vercel gave the same next page again"; break }
                query["cursor"] = next
            }
            let kept = actions.prefix(limit).map { item in
                "\(item.text("startTime") ?? "?") → \(item.text("endTime") ?? "?") \(item.text("action") ?? "?") \(item.text("public_ip") ?? "?") on \(item.text("host") ?? "?"): "
                    + "\(item.text("count") ?? "?") requests, \(item.text("action_type") == "system-action" ? "Vercel's own rule" : "rule \(item.text("ruleName") ?? item.text("ruleId") ?? "not named")")"
                    + (item.flag("isActive") == true ? ", still going on" : "")
            }
            var attackLines: [String] = []
            do {
                let anomalies = try await Vercel.attacks(projectID, service, days: max(1, Int(ceil(Date().timeIntervalSince(since) / 86_400))))
                attackLines = anomalies.filter { (Vercel.when($0["startTime"]) ?? .distantFuture) <= until && (Vercel.when($0["endTime"]) ?? .distantFuture) >= since }
                    .map { Vercel.attackLine($0, project: Vercel.projectName(project)) }
            } catch {
                attackLines = ["Attacks could not be read: \(error.localizedDescription)"]
            }
            let window = "from \(Vercel.iso(since)) to \(Vercel.iso(until))"
            var text = kept.isEmpty ? "The firewall took no matching action on \(Vercel.projectName(project)) \(window)."
                : "\(Vercel.plural(kept.count, "firewall action")) on \(Vercel.projectName(project)) \(window), newest first:\n" + kept.joined(separator: "\n")
            text += attackLines.isEmpty ? "\nNo attack detected on it in that window." : "\n" + attackLines.joined(separator: "\n")
            if let stopped { text += "\nIncomplete: stopped after \(Vercel.plural(pages, "page")) because \(stopped)." }
            else if more || actions.count > limit { text += "\nMore actions match than the \(kept.count) kept: narrow the window, give ip or action, or raise the limit." }
            struct Kept: Encodable { let actions: [String]; let attacks: [String]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(actions: Array(kept), attacks: attackLines, complete: !more && stopped == nil && actions.count <= limit))
        }
    }

    /// The attacks Vercel detected on a project in the last `days` days.
    static func attacks(_ projectID: String, _ service: ServiceClient, days: Int) async throws -> [Value] {
        let body = try await read(attacksNeed) {
            try await get(service, ["v1", "security", "firewall", "attack-status"], query: ["projectId": try id(projectID, "the project"), "since": String(max(1, days))], as: Value.self)
        }
        // Vercel answers an empty object when there is nothing to tell.
        guard case .object(let object) = body else { throw ServiceError.unreadable }
        if object["anomalies"] == nil { return [] }
        guard let anomalies = body["anomalies"]?.items else { throw ServiceError.unreadable }
        return anomalies
    }

    static func attackLine(_ anomaly: Value, project: String) -> String {
        let hosts = (anomaly["affectedHostMap"]?.object ?? [:]).keys.sorted()
        let ddos = (anomaly["affectedHostMap"]?.object ?? [:]).values.contains { !($0["ddosAlerts"]?.object ?? [:]).isEmpty }
        let start = when(anomaly["startTime"]).map(iso) ?? "?"
        let end = when(anomaly["endTime"]).map(iso)
        return "\(start) \(ddos ? "DDoS attack" : "traffic anomaly") detected on \(project)\(hosts.isEmpty ? "" : ", hitting \(hosts.prefix(5).joined(separator: ", "))"), "
            + (end.map { "ended \($0)" } ?? "still going on") + (anomaly.text("state").map { " (\($0))" } ?? "")
    }

    // MARK: What is high-risk

    /// The activity log's event types the watch wakes for, with their turn when more are found than a check keeps.
    static let watchedTypes: [String: (tier: Int, kind: String)] = [
        "user-token-created": (0, "access token created"), "oauth-app-token-created": (1, "app token created"),
        "team-member-add": (0, "member added or role changed"), "team-member-join": (0, "member added or role changed"),
        "team-member-role-update": (0, "member added or role changed"), "team-member-confirm-request": (0, "member added or role changed"),
        "user-mfa-removed": (0, "two-factor authentication removed"), "team-mfa-enforcement-updated": (0, "team sign-in rules changed"),
        "team-saml-enforced": (0, "team sign-in rules changed"), "saml-connection-deleted": (0, "team sign-in rules changed"),
        "saml-connection-created": (0, "team sign-in rules changed"), "team-saml-roles": (0, "team sign-in rules changed"),
        "firewall-config-modified": (1, "firewall changed"), "firewall-config-removed": (0, "firewall changed"), "firewall-config-promoted": (1, "firewall changed"),
        "firewall-managed-ruleset-updated": (1, "firewall changed"), "team-firewall-config-modified": (1, "firewall changed"),
        "team-ip-blocking-rules-removed": (0, "firewall changed"),
        "firewall-bypass-created": (0, "firewall bypass added"), "firewall-conditional-bypass-created": (0, "firewall bypass added"),
        "attack-mode-disabled": (1, "Attack Challenge Mode turned off"),
        "project-sso-protection": (0, "deployment protection changed"), "project-password-protection": (0, "deployment protection changed"),
        "password-protection-disabled": (0, "deployment protection changed"), "default-sso-protection": (0, "deployment protection changed"),
        "project-automation-bypass": (0, "protection bypass added"), "alias-protection-bypass-created": (0, "protection bypass added"),
        "project-git-fork-protection-updated": (0, "Git fork protection changed"),
        "env-variable-read:cli:env:pull": (1, "environment variables pulled"), "env-variable-read:cli:pull": (1, "environment variables pulled"),
        "env-variable-read:v0:env:pull": (1, "environment variables pulled"), "shared-env-variable-read": (1, "environment variables pulled"),
        "integration-installation-completed": (1, "integration installed or its scopes changed"), "integration-scope-changed": (1, "integration installed or its scopes changed"),
        "integration-installation-permission-updated": (1, "integration installed or its scopes changed"),
        "deploy-hook-created": (2, "deploy hook or webhook created"), "webhook-created": (2, "deploy hook or webhook created"),
        "log-drain-deleted": (1, "log drain removed or turned off"), "log-drain-disabled": (1, "log drain removed or turned off"),
        "dns-add": (2, "DNS changed"), "dns-update": (2, "DNS changed"), "dns-delete": (2, "DNS changed"),
        "domain-move-out": (1, "domain moved away"), "domain-chown": (1, "domain moved away"), "domain-delete": (1, "domain moved away"),
        "instant-rollback-created": (2, "production rolled back"),
    ]

    // MARK: Feeds

    enum Feed: String, CaseIterable, Sendable {
        case activity, attacks

        var title: String {
            switch self {
            case .activity: "high-risk changes in the activity log"
            case .attacks: "attacks the Vercel Firewall detected"
            }
        }

        var need: Need { self == .activity ? Vercel.activityNeed : Vercel.attacksNeed }
    }

    struct FeedRead {
        var events: [WatchedEvent] = []
        var complete = false
        var error: Error? = nil
        var pages = 0
        var stopped: String? = nil
        /// Where reading stopped, oldest first, when it did not reach the window's start.
        var oldest: Date? = nil
        /// Projects not read, past those it reads at once.
        var unread = 0
    }

    /// The watched events of one feed from `since` to `until`.
    static func readFeed(_ feed: Feed, _ service: ServiceClient, since: Date, until: Date, pages: Int, partial: Bool) async -> FeedRead {
        var read = FeedRead()
        do {
            switch feed {
            case .activity:
                let found = try await activity(service, since: since, until: until, types: watchedTypes.keys.sorted(), pages: pages, partial: partial)
                read.pages = found.pages
                read.complete = found.complete && found.stopped == nil
                read.stopped = found.stopped
                read.oldest = found.complete ? nil : found.oldest
                for event in found.events {
                    guard let id = event.text("id"), let type = event.text("type"), let watched = watchedTypes[type], let time = event.date("createdAt"),
                          time >= since.addingTimeInterval(-1), time <= until.addingTimeInterval(1) else { continue }
                    read.events.append(WatchedEvent(id: safeID("activity/", id), time: iso(time), tier: watched.tier, kind: watched.kind, feed: feed.rawValue,
                                                    line: "\(watched.kind.prefix(1).uppercased() + watched.kind.dropFirst()): \(eventLine(event))"))
                }
            case .attacks:
                let listing = try await projects(service, pages: 1)
                let projects = Array(listing.value.prefix(attackProjects))
                read.unread = max(0, listing.value.count - projects.count) + (listing.more ? 1 : 0)
                let days = max(1, Int(ceil(Date().timeIntervalSince(since) / 86_400)))
                var failures: [Error] = []
                for project in projects {
                    guard let projectID = project.text("id") else { continue }
                    do {
                        for anomaly in try await attacks(projectID, service, days: days) {
                            guard let start = when(anomaly["startTime"]), start <= until.addingTimeInterval(1),
                                  (when(anomaly["endTime"]) ?? .distantFuture) >= since.addingTimeInterval(-1) else { continue }
                            let ddos = (anomaly["affectedHostMap"]?.object ?? [:]).values.contains { !($0["ddosAlerts"]?.object ?? [:]).isEmpty }
                            read.events.append(WatchedEvent(id: safeID("attack/", "\(projectID)|\(Int(start.timeIntervalSince1970))"), time: iso(max(start, since)), tier: 0,
                                                            kind: ddos ? "DDoS attack detected" : "traffic anomaly detected", feed: feed.rawValue,
                                                            line: attackLine(anomaly, project: projectName(project))))
                        }
                    } catch { failures.append(error) }
                    read.pages += 1
                }
                if let failure = failures.first, failures.count == projects.count { throw failure }
                if !failures.isEmpty { read.stopped = "\(plural(failures.count, "project")) could not be read: \(failures[0].localizedDescription)" }
                read.complete = failures.isEmpty
            }
        } catch {
            read.error = error
        }
        return read
    }

    static func safeID(_ prefix: String, _ value: String) -> String { Azure.safeID(prefix, value) }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: activity log events of other types, such as deployments, ordinary environment variable reads in the dashboard, domains bought and project settings beyond protection, which activity-log reads; what Vercel's Enterprise Audit Log alone records, which has no API; firewall actions against single addresses, which firewall-events reads; attacks on projects past the \(attackProjects) most recently changed; and anything the token's user cannot see."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: high-risk changes in the activity log (access tokens created, members added or roles changed, two-factor removed, sign-in rules, firewall, bypass and deployment protection changed, Git fork protection changed, environment variables pulled, integrations installed, log drains removed, domains moved away, DNS changed, production rolled back) and attacks the Vercel Firewall detected on the 20 most recently changed projects; saying, for each feed, what it searched, what it could not read and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Vercel.window(input.since, input.until, days: 1, maximum: 30)
            var reads: [(Feed, FeedRead)] = []
            for feed in Feed.allCases { reads.append((feed, await Vercel.readFeed(feed, service, since: since, until: until, pages: Vercel.eventsPages, partial: true))) }
            if reads.allSatisfy({ $0.1.error != nil }) {
                throw ServiceError.input("Nothing could be read: " + reads.map { feed, read in
                    "\(feed.title): " + (read.error.map { Vercel.fix(for: $0, feed.need) ?? $0.localizedDescription } ?? "")
                }.joined(separator: "; "))
            }
            let events = reads.flatMap(\.1.events)
            let window = "from \(Vercel.iso(since)) to \(Vercel.iso(until))"
            let gaps = reads.contains { $0.1.error != nil || !$0.1.complete }
            var lines: [String]
            if events.isEmpty {
                lines = [gaps ? "No watched changes or attacks \(window) in what could be read; see below for what was not." : "No watched changes or attacks \(window)."]
            } else {
                lines = GoogleCloud.inTurn(events, most: 80).map { "\($0.time) \($0.line)" }
                if events.count > 80 { lines.append("\(events.count - 80) more in the structured result.") }
            }
            var unread: [String: String] = [:], cut: [String] = []
            for (feed, read) in reads {
                if let error = read.error {
                    lines.append("Could not read \(feed.title), so its silence is unknown: \(Vercel.fix(for: error, feed.need) ?? error.localizedDescription)")
                    unread[feed.rawValue] = error.localizedDescription
                    continue
                }
                lines.append("Searched: \(feed.title) \(window), \(Vercel.plural(read.pages, feed == .activity ? "page" : "project")).")
                if let reason = read.stopped {
                    lines.append("Incomplete: \(feed.title) stopped because \(reason); what was read before is kept.")
                    cut.append(feed.rawValue)
                } else if !read.complete {
                    lines.append("Cut short, with more not read: \(feed.title) before \(read.oldest.map(Vercel.iso) ?? "the last read"), past \(Vercel.eventsPages) pages; narrow the window, or use activity-log.")
                    cut.append(feed.rawValue)
                }
                if read.unread > 0 { lines.append("Not read: attacks on projects past the \(Vercel.attackProjects) most recently changed; use firewall-events for one of them.") }
            }
            lines.append(Vercel.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let couldNotRead: [String: String]; let cutShort: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(events: events.sorted { $0.date > $1.date }, couldNotRead: unread, cutShort: cut,
                                                      complete: reads.allSatisfy { $0.1.complete && $0.1.error == nil }))
        }
    }

    /// The watch: each check reads the activity log's watched types and the attacks of the most recently changed
    /// projects, each from an hour before the last check that read it whole, or from the window's start, whichever is
    /// later. What a check returned is remembered while Pion runs and left out of later checks. When the activity log
    /// has more than a check reads, newest first, the check keeps where it stopped, and the next one reads on from there
    /// back to the same start before reading anything newer, so a burst is read through rather than skipped; it tells
    /// once that more follow. When a check finds more than it can return, it returns each kind in turn and the rest
    /// stay owed, read again by later checks until returned.
    ///
    /// A feed that cannot be read is never dropped unsaid: refused for want of a role, or the token rejected, it is told
    /// as an alert of its own, which wakes the agents to read security-events, whose result names it and why. It is told
    /// once each time it starts, dated at the window's start. A failure that passes, such as the rate limit, holds the
    /// watch back instead, a few checks at most, and is then told the same way.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 3_600 }
        static let holdChecks = 6
        static let remembered = 20_000

        struct Kept: Sendable {
            var inARow: [String: Int] = [:], told: [String: String] = [:]
            var readUntil: [String: Date] = [:]
            var delivered: [String: Date] = [:]
            var owedFrom: [String: Date] = [:]
            /// For the activity log cut short: the window it was reading, and how far back it got.
            var resume: (since: Date, until: Date, end: Date)? = nil
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        func alerts(since: Date, on service: ServiceClient, account: UUID?, now: Date = Date()) async throws -> [ServiceAlert] {
            try Vercel.api(service)
            _ = try Vercel.team(service)
            let state = account.map { account in Self.kept.withLock { $0[account] ?? Kept() } } ?? Kept()
            let start = { (feed: Feed) -> Date in
                var from = since
                if let owed = state.owedFrom[feed.rawValue] { from = owed }
                else if let until = state.readUntil[feed.rawValue] { from = max(since, until.addingTimeInterval(-lookBack)) }
                return max(from, now.addingTimeInterval(-29 * 86_400))
            }
            var reads: [(feed: Feed, read: FeedRead, since: Date, end: Date)] = []
            for feed in Feed.allCases {
                if feed == .activity, let resume = state.resume {
                    reads.append((feed, await Vercel.readFeed(feed, service, since: resume.since, until: resume.until, pages: Vercel.watchPages, partial: false), resume.since, resume.end))
                } else {
                    let from = start(feed)
                    reads.append((feed, await Vercel.readFeed(feed, service, since: from, until: now, pages: Vercel.watchPages, partial: false), from, now))
                }
            }
            let failed = reads.filter { $0.read.error != nil }
            let passing = failed.filter { GoogleWorkspace.isPassing($0.read.error!) }.map(\.feed.rawValue)
            if !passing.isEmpty, let account {
                let held = Self.kept.withLock { kept -> Bool in
                    var watched = kept[account] ?? Kept()
                    for label in passing { watched.inARow[label, default: 0] += 1 }
                    kept[account] = watched
                    return passing.contains { (watched.inARow[$0] ?? 0) <= Self.holdChecks }
                }
                if held {
                    throw ServiceError.input("Could not read \(GoogleCloud.listed(failed.map(\.feed.title))) for now; the next check reads the same window again. \(failed[0].read.error!.localizedDescription)")
                }
            } else if !passing.isEmpty {
                throw failed[0].read.error!
            }
            var seen = Set<String>()
            let pending = reads.flatMap(\.read.events).filter { seen.insert($0.id).inserted && state.delivered[$0.id] == nil }
            var notices: [(label: String, id: String)] = []
            for (feed, read, _, _) in reads {
                if read.error != nil { notices.append(("unreadable/\(feed.rawValue)", "unreadable/\(feed.rawValue)")) }
                else if !read.complete { notices.append(("more/\(feed.rawValue)", "unchecked/\(feed.rawValue)")) }
            }
            if pending.count > ServiceAlert.most - notices.count { notices.append(("more/backlog", "unchecked/backlog")) }
            let current = Set(notices.map(\.label))
            let update = { (watched: inout Kept) -> (told: [ServiceAlert], chosen: [WatchedEvent]) in
                watched.told = watched.told.filter { current.contains($0.key) }
                let new = notices.filter { watched.told[$0.label] == nil }.map { ($0.label, "\($0.id)/\(UUID().uuidString)") }
                for (label, id) in new { watched.told[label] = id }
                let told = new.map { ServiceAlert(id: $0.1, time: since) }
                let chosen = GoogleCloud.inTurn(pending, most: ServiceAlert.most - told.count)
                let ids = Set(chosen.map(\.id))
                let leftover = Dictionary(grouping: pending.filter { !ids.contains($0.id) }, by: \.feed).compactMapValues { $0.map(\.date).min() }
                for (feed, read, from, end) in reads {
                    let label = feed.rawValue
                    watched.inARow[label] = read.error == nil ? 0 : watched.inARow[label]
                    if read.error != nil {
                        // Nothing was read, so all from the window's start stays owed; a read on from where it stopped goes on.
                        if feed != .activity || watched.resume == nil { watched.owedFrom[label] = [watched.owedFrom[label], from].compactMap { $0 }.min() }
                        continue
                    }
                    if feed == .activity, !read.complete, let oldest = read.oldest, read.stopped == nil {
                        // Read on next time from where it stopped, back to the same start, before anything newer.
                        watched.resume = (from, oldest, end)
                        watched.owedFrom[label] = leftover[label].map { min($0, from) } ?? from
                        continue
                    }
                    if feed == .activity { watched.resume = nil }
                    if read.complete {
                        if let owed = leftover[label] { watched.owedFrom[label] = owed } else {
                            watched.owedFrom[label] = nil
                            watched.readUntil[label] = end
                        }
                    } else {
                        watched.owedFrom[label] = [leftover[label], from].compactMap { $0 }.min()
                    }
                }
                for event in chosen { watched.delivered[event.id] = event.date }
                let oldest = (reads.map(\.since) + Array(watched.owedFrom.values)).min() ?? since
                watched.delivered = watched.delivered.filter { $0.value >= oldest.addingTimeInterval(-60) }
                if watched.delivered.count > Self.remembered {
                    watched.delivered = Dictionary(uniqueKeysWithValues: watched.delivered.sorted { $0.value > $1.value }.prefix(Self.remembered).map { ($0.key, $0.value) })
                }
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

    // MARK: Check access

    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Says whose token this is, the team's plan and the user's role in it, warning when the role can change things, and tries each thing this tool reads once: deployments, the activity log, projects, environment variable names, the firewall and its attacks, members, tokens, integrations and domains, saying what to change for what it cannot read. It sends only reads."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try Vercel.api(service)
            let team = try Vercel.team(service)
            var lines = ["· Team \(team.value), reached at https://\(Vercel.host) and nowhere else."]
            let role = await Vercel.whoAmI(service, &lines)
            switch role?.uppercased() {
            case "VIEWER"?, "VIEWER_FOR_PLUS"?: lines.append("✓ The Viewer role only reads.")
            case let other?: lines.append("⚠ The \(other) role can change things in the team. This token is sent only with reads, but Vercel's tokens cannot be narrowed: anyone holding it can do what the role allows. Give Pion Detection's member the Viewer role.")
            case nil: break
            }
            var firstProject: String?
            lines.append(await Vercel.probe(Vercel.projectsNeed) {
                firstProject = try await Vercel.list(service, ["v10", "projects"], key: "projects", size: 1, cursor: "from", pages: 1).value.first?.text("id")
            })
            lines.append(await Vercel.probe(Vercel.deploymentsNeed) { _ = try await Vercel.list(service, ["v7", "deployments"], key: "deployments", size: 1, pages: 1) })
            lines.append(await Vercel.probe(Vercel.activityNeed) {
                _ = try await Vercel.activity(service, since: Date().addingTimeInterval(-3_600), until: Date(), pages: 1, partial: false)
            })
            if let firstProject {
                lines.append(await Vercel.probe(Vercel.envNeed) {
                    _ = try Vercel.variables(try await Vercel.exchange(service, ["v10", "projects", try Vercel.id(firstProject, "the project"), "env"]).data)
                })
                lines.append(await Vercel.probe(Vercel.firewallNeed) { do { _ = try await Vercel.firewall(firstProject, service) } catch ServiceError.notFound {} })
                lines.append(await Vercel.probe(Vercel.attacksNeed) { _ = try await Vercel.attacks(firstProject, service, days: 1) })
            } else {
                lines.append("· Environment variables, the firewall and its attacks were not tried: the token sees no project.")
            }
            lines.append(await Vercel.probe(Vercel.membersNeed) {
                _ = try await Vercel.list(service, ["v3", "teams", try await Vercel.teamID(service), "members"], key: "members", size: 1, pages: 1)
            })
            lines.append(await Vercel.probe(Vercel.tokensNeed) { _ = try await Vercel.list(service, ["v6", "user", "tokens"], key: "tokens", size: 1, pages: 1) })
            lines.append(await Vercel.probe(Vercel.integrationsNeed) {
                _ = try await Vercel.get(service, ["v1", "integrations", "configurations"], query: ["view": "account"], as: Value.self)
            })
            lines.append(await Vercel.probe(Vercel.domainsNeed) { _ = try await Vercel.list(service, ["v5", "domains"], key: "domains", size: 1, pages: 1) })
            lines.append("· Vercel's Enterprise Audit Log has no API; activity-log reads the Activity Log, which every plan keeps.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
