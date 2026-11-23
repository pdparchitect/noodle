import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Okta Audit's alert watch, and security-events, which reads back what woke the agents, the same way for both: the
/// System Log events that hand over the org, open a way in or weaken its defences.
extension Okta {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Limits

    /// The most System Log pages one check of the watch reads, and one call of security-events. The watch asks only for
    /// the watched event types, a thousand to a page, and the System Log has its own low rate limit, so both leave most
    /// of it for investigations.
    static let watchPages = 5, eventsPages = 10, logPage = 1_000

    // MARK: Watched events

    /// Event types the watch asks for by name, and by the start of their name.
    static let watchedTypes = ["user.account.privilege.grant", "group.privilege.grant", "system.api_token.create", "security.threat.detected",
                               "security.attack.start", "user.account.report_suspicious_activity_by_enduser", "application.lifecycle.create"]
    static let watchedPrefixes = ["user.mfa.factor.", "policy.lifecycle.", "policy.rule.", "user.session.impersonation.", "system.idp.lifecycle.",
                                  "zone.", "system.org.rate_limit."]

    /// The System Log filter that asks for every watched type and nothing else, from fixed names only.
    static var watchFilter: String {
        (watchedTypes.map { "eventType eq \"\($0)\"" } + watchedPrefixes.map { "eventType sw \"\($0)\"" }).joined(separator: " or ")
    }

    /// What an event did that the watch wakes for, the most pressing first, or nil for one it does not.
    static func judge(_ event: LogEvent) -> (tier: Int, kind: String, what: String)? {
        let type = event.eventType ?? ""
        let result = event.outcome?.result?.uppercased()
        let succeeded = result == nil || result == "SUCCESS" || result == "ALLOW"
        let users = (event.target ?? []).filter { $0.type == "User" }
        let on = (event.target ?? []).compactMap { $0.alternateId ?? $0.displayName ?? $0.id }.prefix(3).joined(separator: ", ")
        switch type {
        case "user.account.privilege.grant":
            return succeeded ? (0, "admin role granted", "admin role granted to \(on.isEmpty ? "a user" : on)") : nil
        case "group.privilege.grant":
            return succeeded ? (0, "admin role granted", "admin role granted to the group \(on.isEmpty ? "?" : on), and so to its members") : nil
        case "system.api_token.create":
            return succeeded ? (0, "API token created", "API token created, acting as its maker") : nil
        case "security.threat.detected", "security.attack.start":
            return (0, "threat detected", "Okta ThreatInsight detected a threat (\(type))")
        case "user.account.report_suspicious_activity_by_enduser":
            return (0, "suspicious activity reported", "a user reported activity on their account as not theirs")
        case "application.lifecycle.create":
            return succeeded ? (1, "app created", "app created\(on.isEmpty ? "" : ": \(on)")") : nil
        case _ where type.hasPrefix("user.session.impersonation."):
            return result == "FAILURE" ? nil : (0, "impersonation", "an admin impersonating a user (\(type))")
        case _ where type.hasPrefix("user.mfa.factor."):
            // A user enrolling or removing their own factor is routine; someone else doing it is not.
            guard succeeded, let user = users.first, let actor = event.actor?.id, actor != user.id else { return nil }
            return (0, "sign-in factor changed by someone else", "\(type) for \(user.alternateId ?? user.id ?? "?") by someone other than them")
        case _ where type.hasPrefix("policy.lifecycle.") || type.hasPrefix("policy.rule."):
            guard succeeded else { return nil }
            let what = type.hasPrefix("policy.rule.") ? "policy rule" : "policy"
            if type.hasSuffix(".deactivate") || type.hasSuffix(".delete") {
                return (0, "policy or rule turned off", "\(what) turned off (\(type))\(on.isEmpty ? "" : ": \(on)")")
            }
            return (1, "policy or rule changed", "\(what) changed (\(type))\(on.isEmpty ? "" : ": \(on)"); the log does not show whether it weakened sign-on or MFA, so read the policy")
        case _ where type.hasPrefix("system.idp.lifecycle."):
            guard succeeded else { return nil }
            if type.hasSuffix(".create") || type.hasSuffix(".activate") { return (0, "identity provider added", "identity provider added or turned on (\(type)), which can sign users in") }
            if type.hasSuffix(".update") { return (1, "identity provider changed", "identity provider changed (\(type))") }
            return nil
        case _ where type.hasPrefix("zone."):
            return succeeded ? (1, "network zone changed", "network zone changed (\(type)), which policies and blocklists use") : nil
        case _ where type.hasPrefix("system.org.rate_limit."):
            return (2, "org rate limit hit", "an org rate limit was hit (\(type)), which can mean credential stuffing or a runaway integration")
        default:
            return nil
        }
    }

    static func line(_ event: LogEvent, _ what: String) -> String {
        var line = "\(event.published ?? "?") \(what), by \(event.actor?.alternateId ?? event.actor?.id ?? "?")"
        if let ip = event.client?.ipAddress { line += " from \(ip)" }
        return line + " [\(event.uuid ?? "?")]"
    }

    /// A System Log query cut short at the page budget, to go on with: Okta's cursor for its next page and the window
    /// it was asked for, as a cursor is good only with the query it came from. Events published at one moment have no
    /// order Pion could resume by, so only the cursor, never a time, says where the query stopped.
    struct LogQuery: Sendable, Equatable {
        let cursor: String, since: Date, until: Date
        /// The oldest of what its pages found but the checks had no room to return.
        var owed: Date? = nil
    }

    /// What one read of the System Log found, and how far it got.
    struct LogRead {
        var events: [WatchedEvent] = []
        /// Read whole: every page to the end.
        var complete = false
        /// More remained than the pages it may read, or a next page it would not follow.
        var cut = false
        /// For a read cut at its page budget: how to go on with the same query.
        var next: LogQuery? = nil
        /// The query this read went on with, when a check before had cut it short.
        var resumed: LogQuery? = nil
        /// The time of the last event read, oldest first, when cut: everything before it was read.
        var lastRead: Date? = nil
        /// Why it stopped early, when a page failed after others were read.
        var stopped: String? = nil
        var error: Error? = nil
        var pages = 0
    }

    /// The watched events from `since` to `until`, oldest first, or of the query `resuming` from its cursor. Bounded,
    /// with until always given, so Okta's pages end. With `partial`, a page that fails after others keeps what they
    /// held and says so; without, the read fails whole.
    static func readLog(_ service: ServiceClient, since: Date, until: Date, pages: Int, resuming: LogQuery? = nil, partial: Bool = false) async -> LogRead {
        var read = LogRead(resumed: resuming)
        let (since, until) = resuming.map { ($0.since, $0.until) } ?? (since, until)
        do {
            let listing = try await Okta.read(.logs) {
                try await Okta.list(service, ["logs"], query: ["filter": watchFilter, "since": iso(since), "until": iso(until),
                                                              "limit": String(logPage), "sortOrder": "ASCENDING"],
                                    as: LogEvent.self, pages: pages, dropping: ["since"], after: resuming?.cursor, partial: partial)
            }
            read.pages = listing.pages
            read.complete = listing.complete
            read.cut = !listing.complete
            read.stopped = listing.stopped
            if let cursor = listing.cursor, listing.more, listing.stopped == nil {
                read.next = LogQuery(cursor: cursor, since: since, until: until, owed: resuming?.owed)
            }
            if read.cut { read.lastRead = listing.value.compactMap { ServiceAlert.time($0.published) }.max() }
            var seen = Set<String>()
            for event in listing.value {
                guard let id = event.uuid, seen.insert(id).inserted, let time = ServiceAlert.time(event.published), time >= since.addingTimeInterval(-1),
                      time <= until.addingTimeInterval(1), let judged = judge(event) else { continue }
                read.events.append(WatchedEvent(id: safeID("systemlog/", id), time: iso(time), tier: judged.tier, kind: judged.kind, feed: "system-log",
                                                line: line(event, judged.what)))
            }
        } catch {
            read.error = error
        }
        return read
    }

    /// The same digest Azure gives an ID a wake carries.
    static func safeID(_ prefix: String, _ value: String) -> String { Azure.safeID(prefix, value) }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: sign-ins themselves, failed ones and bursts of failed MFA included, which sign-in-events finds with failuresOnly; users made, deactivated or suspended; passwords reset by admins; group memberships and app assignments; a user enrolling or removing their own factors; and admin roles granted through a group rule. Okta ThreatInsight raises threats only when it is on, in Security › General. Policies changed are told, but the log does not show whether a change weakened them."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: admin roles granted to users or groups, API tokens created, sign-in factors changed or reset by someone other than their user, policies and policy rules turned off or changed, admins impersonating users, identity providers and apps added, network zones changed, threats ThreatInsight detected, suspicious activity users reported and org rate limits hit; saying what it searched, whether it read everything and why not, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Okta.window(input.since, input.until, days: 1)
            let read = await Okta.readLog(service, since: since, until: until, pages: Okta.eventsPages, partial: true)
            if let error = read.error { throw error }
            let window = "from \(Okta.iso(since)) to \(Okta.iso(until))"
            var lines: [String]
            if read.events.isEmpty {
                lines = [read.complete ? "No watched events \(window)." : "No watched events in what was read \(window); see below for what was not."]
            } else {
                lines = GoogleCloud.inTurn(read.events, most: 80).map(\.line)
                if read.events.count > 80 { lines.append("\(read.events.count - 80) more in the structured result.") }
            }
            lines.append("Searched: the System Log's watched event types \(window), oldest first, \(read.pages) page\(read.pages == 1 ? "" : "s").")
            if let reason = read.stopped {
                lines.append("Incomplete: stopped at page \(read.pages + 1) because \(reason); the events of the \(read.pages) page\(read.pages == 1 ? "" : "s") before are kept, read up to \(read.lastRead.map(Okta.iso) ?? "the start").")
            } else if read.cut {
                lines.append("Cut short, with more not read: the System Log after \(read.lastRead.map(Okta.iso) ?? "the start"), past \(Okta.eventsPages) pages; give a later since, or use sign-in-events with an eventType.")
            }
            lines.append(Okta.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let complete: Bool; let readUntil: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(events: read.events.sorted { $0.date > $1.date }, complete: read.complete,
                                                      readUntil: read.cut ? read.lastRead.map(Okta.iso) : Okta.iso(until)))
        }
    }

    /// The watch: each check reads the System Log's watched events, oldest first, from an hour before the newest seen,
    /// as Okta publishes some events late, or from an hour before the last check that read it whole, whichever is later.
    /// What a check returned is remembered while Pion runs and left out of later checks, so what is read again is not
    /// news again. A check that reaches its page budget keeps Okta's cursor and the query it belongs to, and the next
    /// check goes on with that query from the cursor, never from a time, so however many events share one moment the
    /// watch moves on through them. A query that ends leaves a boundary, its end less the hour, which the next check
    /// reads from, however far the watch moved on meanwhile. When a check finds more than it can return, it returns each
    /// kind in turn, tells once that more follow, and owes the oldest left out until a later read returns it: the
    /// boundary owed moves on only with what a check read whole and returned.
    ///
    /// A System Log that cannot be read is never dropped unsaid: refused, or the sign-in rejected, it is told as an alert
    /// of its own, which wakes the agents to read security-events, whose result says why. It is told once each time it
    /// starts, and again after a relaunch, dated at the start of the window read so it never moves the watch past what
    /// was not yet read. A cursor Okta rejects is given up and its window read again from its start, told the same way.
    /// A failure that passes, such as Okta rate limiting, holds the watch back instead, a few checks at most, keeping
    /// nothing but how many checks in a row failed, and is then told the same way.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 3_600 }
        static let holdChecks = 6
        /// The most IDs of what was returned that one connection keeps, the newest first.
        static let remembered = 20_000

        /// What the checks of one connection keep between them while Pion runs.
        struct Kept: Sendable {
            /// How many checks in a row failed for a reason that passes.
            var inARow = 0
            var told: [String: String] = [:]
            /// When the System Log was last read whole, and all it found returned, up to.
            var readUntil: Date? = nil
            /// What the checks returned, by ID, with when it happened.
            var delivered: [String: Date] = [:]
            /// The oldest of what a check owes: found but not returned, or not read at all. It moves on, or goes, only
            /// with what a check read and returned.
            var owedFrom: Date? = nil
            /// A query cut short at the page budget, which the next checks go on with until it ends.
            var query: LogQuery? = nil
            /// Where a query that ended reads on from: its end, less the hour, however far the watch moved on while it
            /// was read. It goes once a whole read from there returns all it found.
            var catchUp: Date? = nil
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// Applies `change` to what `account` keeps, or to a scratch copy when there is no account.
        private func update<Result>(_ account: UUID?, _ state: Kept, _ change: (inout Kept) -> Result) -> Result {
            guard let account else { var scratch = state; return change(&scratch) }
            return Self.kept.withLock { kept in
                var watched = kept[account] ?? Kept()
                let result = change(&watched)
                kept[account] = watched
                return result
            }
        }

        /// The notices that are current, each told once while it lasts, dated at the window's start.
        private static func tell(_ notices: [(label: String, id: String)], _ watched: inout Kept, since: Date) -> [ServiceAlert] {
            let current = Set(notices.map(\.label))
            watched.told = watched.told.filter { current.contains($0.key) }
            let new = notices.filter { watched.told[$0.label] == nil }.map { ($0.label, "\($0.id)/\(UUID().uuidString)") }
            for (label, id) in new { watched.told[label] = id }
            return new.map { ServiceAlert(id: $0.1, time: since) }
        }

        /// Whether Okta turned down the request itself, such as a cursor it no longer takes, rather than the sign-in or
        /// for now.
        static func rejects(_ error: Error) -> Bool {
            switch error {
            case ServiceError.refused, ServiceError.notFound: true
            case ServiceError.status(let status, _): (400..<500).contains(status) && status != 408 && status != 429
            default: false
            }
        }

        func alerts(since: Date, on service: ServiceClient, account: UUID?, now: Date = Date()) async throws -> [ServiceAlert] {
            let state = account.map { account in Self.kept.withLock { $0[account] ?? Kept() } } ?? Kept()
            let resuming = state.query
            // A query cut short goes on from its cursor. Otherwise what is owed is read from, however far the watch has
            // moved on, as all before it was read and returned; then a boundary a query left when it ended; otherwise
            // an hour before the last whole read, when that is later than where the watch is.
            var from = since
            if let owed = state.owedFrom { from = owed }
            else if let boundary = state.catchUp { from = boundary }
            else if let readUntil = state.readUntil { from = max(since, readUntil.addingTimeInterval(-lookBack)) }
            // The System Log keeps 90 days.
            from = max(from, now.addingTimeInterval(-89 * 86_400))
            let read = await Okta.readLog(service, since: from, until: now, pages: Okta.watchPages, resuming: resuming)
            let start = resuming?.since ?? from

            if let error = read.error {
                let passing = GoogleWorkspace.isPassing(error)
                let streak = update(account, state) { watched -> Int in
                    watched.inARow = passing ? watched.inARow + 1 : 0
                    return watched.inARow
                }
                // A failure that passes fails the whole check, so the watch reads the same again, and nothing else of it
                // is kept.
                if passing, streak <= Self.holdChecks {
                    throw ServiceError.input("Could not read the System Log for now; the next check reads the same again. \(error.localizedDescription)")
                }
                if let resuming, !passing, Self.rejects(error) {
                    // A cursor Okta no longer takes is given up: its window is read again from its start, told once.
                    return update(account, state) { watched -> [ServiceAlert] in
                        watched.query = nil
                        watched.owedFrom = [watched.owedFrom, resuming.owed, resuming.since].compactMap { $0 }.min()
                        return Self.tell([("again/system-log", "unchecked/system-log")], &watched, since: since)
                    }
                }
                let told = update(account, state) { watched -> [ServiceAlert] in
                    // Nothing was read, so everything from the window's start stays owed, or the query stays to go on with.
                    if watched.query == nil { watched.owedFrom = [watched.owedFrom, from].compactMap { $0 }.min() }
                    return Self.tell([("unreadable/system-log", "unreadable/system-log")], &watched, since: since)
                }
                if told.isEmpty { throw error }
                return told
            }

            // Each event once: what earlier checks returned is left out before the room is counted.
            let pending = read.events.filter { state.delivered[$0.id] == nil }
            var notices: [(label: String, id: String)] = []
            // Cut short with no cursor to go on with: said, and read again from where it stopped.
            if read.cut, read.next == nil { notices.append(("more/system-log", "unchecked/system-log")) }
            // More follow while a check has no room for all it found or reads on through a query; once said, it stays
            // said while anything found is still owed, so it is told once. What is owed after a failure alone is no
            // backlog.
            let owing = state.told["more/backlog"] != nil && (resuming?.owed != nil || state.owedFrom != nil || resuming != nil)
            if pending.count > ServiceAlert.most - notices.count || (read.next != nil && !pending.isEmpty) || owing {
                notices.append(("more/backlog", "unchecked/backlog"))
            }
            let lookBack = lookBack
            let (told, chosen) = update(account, state) { watched -> ([ServiceAlert], [WatchedEvent]) in
                watched.inARow = 0
                let told = Self.tell(notices, &watched, since: since)
                let chosen = GoogleCloud.inTurn(pending, most: ServiceAlert.most - told.count)
                let ids = Set(chosen.map(\.id))
                let leftover = pending.filter { !ids.contains($0.id) }.map(\.date).min()
                if var next = read.next {
                    // Gone on with next time from its cursor; what had no room is kept with it, and its start is the
                    // query's own, so nothing else is owed meanwhile.
                    next.owed = [next.owed, leftover].compactMap { $0 }.min()
                    watched.query = next
                    watched.owedFrom = nil
                    watched.catchUp = nil
                } else if let query = read.resumed, read.complete {
                    // A query gone on with to its end accounts for its window and nothing after it, however far the
                    // watch moved on while it was read: the log is read on from its end, with the hour for what is
                    // published late, or from the oldest it found but had no room for.
                    watched.query = nil
                    let boundary = query.until.addingTimeInterval(-lookBack)
                    if let held = [query.owed, leftover].compactMap({ $0 }).min() {
                        watched.owedFrom = min(held, boundary)
                        watched.catchUp = nil
                    } else {
                        watched.owedFrom = nil
                        watched.catchUp = boundary
                    }
                } else if read.complete {
                    // Read whole from where it was owed, or from the boundary: only what had no room is owed.
                    watched.query = nil
                    watched.owedFrom = leftover
                    watched.catchUp = nil
                    if leftover == nil { watched.readUntil = now }
                } else {
                    // Cut short with no cursor: everything from where reading stopped is owed too.
                    watched.query = nil
                    watched.owedFrom = [leftover, read.lastRead ?? start, read.resumed?.owed].compactMap { $0 }.min()
                    watched.catchUp = nil
                }
                for event in chosen { watched.delivered[event.id] = event.date }
                let oldest = [start, watched.owedFrom, watched.catchUp, watched.query?.since, watched.query?.owed].compactMap { $0 }.min() ?? start
                watched.delivered = watched.delivered.filter { $0.value >= oldest.addingTimeInterval(-60) }
                if watched.delivered.count > Self.remembered {
                    watched.delivered = Dictionary(uniqueKeysWithValues: watched.delivered.sorted { $0.value > $1.value }.prefix(Self.remembered).map { ($0.key, $0.value) })
                }
                return (told, chosen)
            }
            return told + chosen.compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
        }
    }
}
