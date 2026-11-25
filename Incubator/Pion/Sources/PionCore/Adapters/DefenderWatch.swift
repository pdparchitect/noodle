import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Microsoft Defender XDR Detection's alert watch, and security-events, which reads back what woke the agents, the same way
/// for both: new high-severity alerts not yet resolved, and high-severity incidents still open.
extension Defender {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Limits

    /// The most pages of each feed one check of the watch reads, and one call of security-events: Graph throttles each
    /// app in each tenant, so both leave most of it for investigations.
    static let watchPages = 4, eventsPages = 10
    /// How many each page asks for: Graph pages incidents in fewer than alerts.
    static let alertsPage = "100", incidentsPage = "50"

    // MARK: Feeds

    enum Feed: String, CaseIterable, Sendable {
        case alerts, incidents

        var title: String {
            switch self {
            case .alerts: "high-severity alerts"
            case .incidents: "high-severity incidents"
            }
        }

        var need: Need { self == .alerts ? Defender.alertsNeed : Defender.incidentsNeed }
        var path: [String] { ["security", self == .alerts ? "alerts_v2" : "incidents"] }

        /// The search for `since` to `until`, by when each was made, bounded at both ends.
        func query(since: Date, until: Date) -> [String: String?] {
            ["$filter": "severity eq 'high' and createdDateTime ge \(Entra.iso(since)) and createdDateTime le \(Entra.iso(until))", "$top": self == .alerts ? Defender.alertsPage : Defender.incidentsPage]
        }
    }

    /// A query cut short at the page budget, to go on with: the paging value its next link gave and the window it was
    /// asked for, as that value is good only with the query it came from. Alerts made at the same moment have no order
    /// Pion could resume by, so only the paging value, never a time, says where the query stopped.
    struct Continuation: Sendable, Equatable {
        let name: String, value: String, since: Date, until: Date
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
        /// Why the feed has nothing to read, such as a tenant without Defender, said as what to change.
        var off: String? = nil
        /// For a read cut at its page budget: how to go on with the same query.
        var next: Continuation? = nil
        /// The query this read went on with, when a check before had cut it short.
        var resumed: Continuation? = nil
        var pages = 0
        /// Why it stopped early, when a page failed after others were read.
        var stopped: String? = nil
    }

    /// Statuses an alert or incident is no longer open in. Any other, or none, may be open, so it is watched.
    static let closed: Set<String> = ["resolved", "redirected"]

    // MARK: Reading

    /// The watched alerts or incidents of one feed from `since` to `until`, or of the query `continuation` from where
    /// it stopped. With `partial`, a page that fails after others keeps what they held and says so; without, the read
    /// fails whole.
    static func readFeed(_ feed: Feed, _ service: ServiceClient, since: Date, until: Date, pages: Int, from continuation: Continuation? = nil,
                         partial: Bool = false) async -> FeedRead {
        var read = FeedRead(resumed: continuation)
        let (since, until) = continuation.map { ($0.since, $0.until) } ?? (since, until)
        let within = { (time: Date) in time >= since.addingTimeInterval(-1) && time <= until.addingTimeInterval(1) }
        let high = { (severity: String?) in (severity ?? "high").lowercased() == "high" }
        let open = { (status: String?) in !closed.contains((status ?? "").lowercased()) }
        do {
            func listing<Item: Decodable>(_ type: Item.Type) async throws -> Listing<Item> {
                try await Defender.list(service, feed.path, query: feed.query(since: since, until: until), as: Item.self, pages: pages,
                                        from: continuation.map { ($0.name, $0.value) }, partial: partial)
            }
            let found: (pages: Int, more: Bool, stopped: String?, next: (name: String, value: String)?)
            switch feed {
            case .alerts:
                let alerts = try await listing(Alert.self)
                found = (alerts.pages, alerts.more, alerts.stopped, alerts.next)
                for alert in alerts.value {
                    guard high(alert.severity), open(alert.status), let time = ServiceAlert.time(alert.createdDateTime), within(time) else { continue }
                    let kept = KeptAlert(alert)
                    let source = alert.serviceSource ?? "an unknown source"
                    read.events.append(WatchedEvent(id: safeID("alert/", alert.id), time: Entra.iso(time), tier: 0, kind: "high alert from \(source)",
                                                    feed: feed.rawValue,
                                                    line: "\(Entra.iso(time)) High alert from \(source): \(alert.title ?? "untitled") (\(alert.status ?? "status unknown"))\(kept.entities.isEmpty ? "" : " — " + kept.entities.prefix(4).joined(separator: ", "))\(alert.incidentId.map { ", incident \($0)" } ?? "") [\(alert.id)]"))
                }
            case .incidents:
                let incidents = try await listing(Incident.self)
                found = (incidents.pages, incidents.more, incidents.stopped, incidents.next)
                for incident in incidents.value {
                    guard high(incident.severity), open(incident.status), let time = ServiceAlert.time(incident.createdDateTime), within(time) else { continue }
                    read.events.append(WatchedEvent(id: safeID("incident/", incident.id), time: Entra.iso(time), tier: 1, kind: "high incident", feed: feed.rawValue,
                                                    line: "\(Entra.iso(time)) High incident: \(incident.displayName ?? "untitled") (\(incident.status ?? "status unknown")) [\(incident.id)]"))
                }
            }
            read.pages = found.pages
            read.stopped = found.stopped
            read.complete = !found.more && found.stopped == nil
            read.cut = !read.complete
            if let next = found.next, found.more, found.stopped == nil {
                read.next = Continuation(name: next.name, value: next.value, since: since, until: until, owed: continuation?.owed)
            }
        } catch {
            if unlicensed(error) {
                read.off = "\(feed.title) cannot be read: the tenant lacks Microsoft Defender XDR, or has not set it up, so what it would show is not watched."
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
    static let unwatched = "Not watched: alerts and incidents below high severity; alerts resolved, and incidents resolved or redirected, before a check read them; an alert or incident raised to high after it was made, whose creation time the watch has passed; what only the advanced hunting tables hold, which hunt reads; and Defender for Endpoint's machine actions, such as isolations, live response and offboarding, which only Microsoft Defender XDR Containment's machine-actions reads, as reading them takes a permission that could also change devices."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: high-severity alerts that are not resolved, and high-severity incidents that are active, in progress or awaiting action; saying, for each feed, what it searched, what is off, what it could not read and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest creation time, in ISO 8601. The last 24 hours when left out, at most 30 days."),
            "until": .string("The latest creation time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Defender.window(input.since, input.until, days: 1, maximum: 30)
            var reads: [(Feed, FeedRead)] = []
            for feed in Feed.allCases { reads.append((feed, await Defender.readFeed(feed, service, since: since, until: until, pages: Defender.eventsPages, partial: true))) }
            if reads.allSatisfy({ $0.1.error != nil || $0.1.off != nil }), reads.contains(where: { $0.1.error != nil }) {
                throw ServiceError.input("Nothing could be read: " + reads.map { feed, read in
                    "\(feed.title): " + (read.off ?? read.error.map { Defender.fix(for: $0, feed.need) ?? $0.localizedDescription } ?? "")
                }.joined(separator: "; "))
            }
            let events = reads.flatMap(\.1.events)
            let window = "made from \(Entra.iso(since)) to \(Entra.iso(until))"
            let gaps = reads.contains { $0.1.error != nil || $0.1.cut || $0.1.off != nil }
            var lines: [String]
            if events.isEmpty {
                lines = [gaps ? "No watched alerts or incidents \(window) in what could be read; see below for what was not." : "No watched alerts or incidents \(window)."]
            } else {
                lines = GoogleCloud.inTurn(events, most: 80).map(\.line)
                if events.count > 80 { lines.append("\(events.count - 80) more in the structured result.") }
            }
            var unread: [String: String] = [:], off: [String: String] = [:], cut: [String] = []
            for (feed, read) in reads {
                if read.error == nil, read.off == nil { lines.append("Searched: \(feed.title) \(window), \(Defender.plural(read.pages, "page")).") }
                if let error = read.error {
                    lines.append("Could not read \(feed.title), so its silence is unknown: \(Defender.fix(for: error, feed.need) ?? error.localizedDescription)")
                    unread[feed.rawValue] = error.localizedDescription
                }
                if let reason = read.off { lines.append("Off: \(reason)"); off[feed.rawValue] = reason }
                if let reason = read.stopped {
                    lines.append("Incomplete: stopped at page \(read.pages + 1) of \(feed.title) because \(reason); what the pages before held is kept.")
                    cut.append(feed.rawValue)
                } else if read.cut {
                    lines.append("Cut short, with more not read: \(feed.title), past \(Defender.eventsPages) pages; narrow the window, or use \(feed.rawValue) with a status.")
                    cut.append(feed.rawValue)
                }
            }
            lines.append(Defender.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let couldNotRead: [String: String]; let off: [String: String]; let cutShort: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(events: events.sorted { $0.date > $1.date }, couldNotRead: unread, off: off, cutShort: cut,
                                                      complete: reads.allSatisfy { $0.1.complete && $0.1.error == nil }))
        }
    }

    /// The watch: each check reads both feeds, each from six hours before the newest seen or before the last check that
    /// read it whole, whichever is later, as Defender lists some alerts well after they were made. What a check
    /// returned is remembered while Pion runs and left out of later checks, so what is read again is not news again;
    /// when a check finds more than it can return, it returns each kind in turn, tells once that more follow, and the
    /// checks after read again from the oldest left out until all of it is returned. A feed that reaches its page
    /// budget keeps the paging value of its next page and the query it belongs to, and the next check goes on with that
    /// query, never from a time; a query that ends leaves a boundary, its end less the six hours, which the feed reads
    /// on from however far the watch moved on meanwhile. Each feed keeps the oldest of what it owes until it is read
    /// whole and all it found returned. Nothing a check read is kept when it fails.
    ///
    /// A feed that cannot be read is never dropped unsaid: refused, the sign-in rejected, or the tenant without Defender,
    /// it is told as an alert of its own, which wakes the agents to read security-events, whose result names it and
    /// why. It is told once each time it starts, and again after a relaunch, dated at the start of the window read so
    /// it never moves the watch past what was not yet read. A paging value Graph no longer takes is given up and its
    /// window read again from its start, told the same way. A failure that passes, such as Graph throttling, holds the
    /// watch back instead, a few checks at most, keeping nothing but how many checks in a row failed, and is then told
    /// the same way.
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

        /// Whether Graph turned down the request itself, such as a paging value it no longer takes, rather than the
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
                // Never further back than security-events reads.
                return max(from, now.addingTimeInterval(-29 * 86_400))
            }
            var reads: [(feed: Feed, read: FeedRead)] = []
            for feed in Feed.allCases {
                reads.append((feed, await Defender.readFeed(feed, service, since: start(feed), until: now, pages: Defender.watchPages,
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
                        // A query cut short goes on next time from where it stopped. What it owes is kept with it, and its
                        // start stays owed until it ends, so should it fail, it is read again from there.
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
                    // paging value, a query given up, or read only in part, keeps the oldest owed, and owes what it was
                    // asked to read too.
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
