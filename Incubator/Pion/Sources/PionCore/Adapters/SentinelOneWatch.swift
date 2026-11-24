import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// SentinelOne Audit's alert watch, and security-events, which reads back what woke the agents, the same way for both:
/// new unresolved threats of malicious or suspicious confidence; network disconnects and threat mitigations a person
/// issued, from the activity log; and agents newly disconnected from the network, by anyone or by policy.
extension SentinelOne {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Limits

    /// The most pages of each feed one check of the watch reads, and one call of security-events.
    static let watchPages = 4, eventsPages = 10
    /// How many each page asks for.
    static let watchPage = 500
    /// The most disconnected agents the watch reads; a console with more is told it was cut short.
    static let disconnectedPages = 5, disconnectedPage = 1_000

    // MARK: Feeds

    /// The feeds read by time. Disconnected agents are read as they stand, as SentinelOne keeps no time an agent was
    /// disconnected on the agent itself.
    enum Feed: String, CaseIterable, Sendable {
        case threats, actions

        var title: String {
            switch self {
            case .threats: "unresolved malicious and suspicious threats"
            case .actions: "network disconnects and threat mitigations a person issued"
            }
        }

        var need: Need { self == .threats ? SentinelOne.threatsNeed : SentinelOne.activitiesNeed }
    }

    static let disconnectedTitle = "agents disconnected from the network"

    /// A search cut short at the page budget, to go on with: its cursor, and the query it belongs to, as a cursor is
    /// good only with the query it came from. Threats detected at the same moment have no order Pion could resume by,
    /// so only the cursor, never a time, says where the search stopped.
    struct Continuation: Sendable, Equatable {
        let cursor: String
        let since: Date, until: Date
        let query: [String: String]
        /// For the activity log: which of the query's types are network disconnects, the rest being mitigations.
        var disconnectTypes: Set<Int> = []
        /// The oldest of what its pages found but the checks had no room to return.
        var owed: Date? = nil
    }

    /// What one read of one feed found, and how far it got.
    struct FeedRead {
        var events: [WatchedEvent] = []
        var complete = false
        var cut = false
        var error: Error? = nil
        /// Why the feed has nothing to read, such as a console whose activity types name none Pion recognises.
        var off: String? = nil
        var next: Continuation? = nil
        var resumed: Continuation? = nil
        var pages = 0
        var stopped: String? = nil
    }

    // MARK: Reading

    /// The activity types the watch reads, by what each type says it records: a person disconnecting an agent from the
    /// network, or a mitigation of a threat (kill, quarantine, release, remediate, roll back). A type whose words say
    /// reconnecting or releasing from the network is neither.
    static func watchedTypes(_ types: [ActivityType]) -> (disconnect: Set<Int>, mitigation: Set<Int>) {
        var disconnect = Set<Int>(), mitigation = Set<Int>()
        for type in types {
            let words = type.words
            let undoing = ["reconnect", "release", "removed from", "un-quarantin", "unquarantin"].contains(where: words.contains)
            if words.contains("network"), words.contains("disconnect") || (words.contains("quarantin") && !undoing) {
                if !undoing { disconnect.insert(type.id) }
            } else if ["kill", "quarantin", "remediat", "rollback", "roll back"].contains(where: words.contains), words.contains("threat") || words.contains("mitigat") {
                mitigation.insert(type.id)
            }
        }
        return (disconnect, mitigation)
    }

    static func feedQuery(_ feed: Feed, since: Date, until: Date, types: [Int] = []) -> [String: String] {
        var query = ["createdAt__gte": iso(since), "createdAt__lte": iso(until), "sortBy": "createdAt", "sortOrder": "desc"]
        switch feed {
        case .threats: query["incidentStatuses"] = "unresolved"
        case .actions: query["activityTypes"] = types.sorted().map(String.init).joined(separator: ",")
        }
        return query
    }

    /// The watched threats or actions of one feed from `since` to `until`, or of the search `continuation` from where it
    /// stopped. With `partial`, a page that fails after others keeps what they held and says so; without, the read
    /// fails whole.
    static func readFeed(_ feed: Feed, _ service: ServiceClient, since: Date, until: Date, pages: Int, from continuation: Continuation? = nil,
                         partial: Bool = false) async -> FeedRead {
        var read = FeedRead(resumed: continuation)
        let (since, until) = continuation.map { ($0.since, $0.until) } ?? (since, until)
        let within = { (time: Date) in time >= since.addingTimeInterval(-1) && time <= until.addingTimeInterval(1) }
        do {
            let found: (pages: Int, more: Bool, stopped: String?, next: String?)
            var query: [String: String], disconnectTypes = continuation?.disconnectTypes ?? []
            switch feed {
            case .threats:
                query = continuation?.query ?? feedQuery(.threats, since: since, until: until)
                let threats = try await list(service, ["threats"], query: query, as: Threat.self, size: watchPage, pages: pages, from: continuation?.cursor, partial: partial)
                found = (threats.pages, threats.more, threats.stopped, threats.next)
                for threat in threats.value {
                    // Resolved, or of a confidence below suspicious, is not watched; a status or confidence SentinelOne
                    // does not give is.
                    if let status = threat.incidentStatus, status != "unresolved" { continue }
                    if let confidence = threat.confidence, !["malicious", "suspicious"].contains(confidence) { continue }
                    guard let time = ServiceAlert.time(threat.created), within(time) else { continue }
                    let level = threat.confidence ?? "unknown-confidence"
                    read.events.append(WatchedEvent(id: safeID("threat/", threat.id), time: iso(time), tier: threat.confidence == "suspicious" ? 1 : 0,
                                                    kind: "\(level) threat", feed: feed.rawValue,
                                                    line: "\(iso(time)) \(level.capitalized) threat: \(threat.title) (\([threat.info("classification"), threat.info("mitigationStatus").map { "mitigation \($0)" }].compactMap { $0 }.joined(separator: ", ")))\(threat.computer.map { " on \($0)" } ?? "")\(threat.agentID.map { " [agent \($0)]" } ?? "") [\(threat.id)]"))
                }
            case .actions:
                if let continuation { query = continuation.query } else {
                    let (disconnect, mitigation) = watchedTypes(try await activityTypes(service))
                    guard !(disconnect.isEmpty && mitigation.isEmpty) else {
                        read.off = "\(feed.title) cannot be read: the console's activity types name none Pion recognises as a network disconnect or a threat mitigation, so they are not watched; activity-types lists the types."
                        read.complete = true
                        return read
                    }
                    disconnectTypes = disconnect
                    query = feedQuery(.actions, since: since, until: until, types: Array(disconnect.union(mitigation)))
                }
                let asked = Set((query["activityTypes"] ?? "").split(separator: ",").compactMap { Int($0) })
                let entries = try await list(service, ["activities"], query: query, as: Activity.self, size: watchPage, pages: pages, from: continuation?.cursor, partial: partial)
                found = (entries.pages, entries.more, entries.stopped, entries.next)
                for entry in entries.value {
                    // Only what a person issued: what the agent or a policy did on its own names no user.
                    guard let type = entry.type, asked.contains(type), entry.user != nil, let time = ServiceAlert.time(entry.created), within(time) else { continue }
                    let disconnect = disconnectTypes.contains(type)
                    read.events.append(WatchedEvent(id: safeID("activity/", entry.id), time: iso(time), tier: disconnect ? 0 : 1,
                                                    kind: disconnect ? "network disconnect by a person" : "threat mitigation by a person", feed: feed.rawValue,
                                                    line: "\(iso(time)) \(disconnect ? "Network disconnect" : "Threat mitigation"): \(entry.line)"))
                }
            }
            read.pages = found.pages
            read.stopped = found.stopped
            read.complete = !found.more && found.stopped == nil
            read.cut = !read.complete
            if let next = found.next, found.more, found.stopped == nil {
                read.next = Continuation(cursor: next, since: since, until: until, query: query, disconnectTypes: disconnectTypes, owed: continuation?.owed)
            }
        } catch {
            if unlicensed(error) {
                read.off = "\(feed.title) cannot be read: the console lacks the SentinelOne licence it needs, so what it would show is not watched."
                read.complete = true
            } else {
                read.error = error
            }
        }
        return read
    }

    /// The agents disconnected from the network or with a disconnect pending, every one, or why not all could be read.
    struct DisconnectedRead {
        var agents: [String] = []
        var complete = false
        var error: Error? = nil
        var stopped: String? = nil
    }

    static func readDisconnected(_ service: ServiceClient) async -> DisconnectedRead {
        do {
            let listing = try await list(service, ["agents"], query: ["networkStatuses": "disconnected,disconnecting"], as: Agent.self, size: disconnectedPage,
                                         pages: disconnectedPages, partial: false)
            let agents = listing.value.filter { ["disconnected", "disconnecting", nil].contains($0.network) }.map(\.id)
            return DisconnectedRead(agents: Array(Set(agents)).sorted(), complete: listing.complete,
                                    stopped: listing.complete ? nil : listing.stopped ?? "more than \(disconnectedPages * disconnectedPage) are disconnected")
        } catch { return DisconnectedRead(error: error) }
    }

    /// The same digest Azure gives an ID a wake carries.
    static func safeID(_ prefix: String, _ value: String) -> String { Azure.safeID(prefix, value) }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: threats resolved, or of confidence n/a, before a check read them; a threat set back to unresolved after the watch passed the time it was detected; STAR custom-rule alerts and Singularity's unified alerts, which this tool does not read; what the agents or a policy did on their own, such as automatic mitigation, though an agent a policy disconnected shows among those disconnected; an agent disconnected and reconnected between two checks, or while Pion was not running; network disconnects and mitigations of an activity type Pion does not recognise from the console's own names for them (activity-types lists them); and anything outside the service user's scope."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: unresolved threats of malicious or suspicious confidence, and network disconnects and threat mitigations a person issued; and the agents disconnected from the network or with a disconnect pending now, with when the watch first saw each; saying, for each feed, what it searched, what is off, what it could not read and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try SentinelOne.window(input.since, input.until, days: 1, maximum: 30)
            var reads: [(Feed, FeedRead)] = []
            for feed in Feed.allCases { reads.append((feed, await SentinelOne.readFeed(feed, service, since: since, until: until, pages: SentinelOne.eventsPages, partial: true))) }
            let disconnected = await SentinelOne.readDisconnected(service)
            if reads.allSatisfy({ $0.1.error != nil || $0.1.off != nil }), reads.contains(where: { $0.1.error != nil }), let error = disconnected.error {
                throw ServiceError.input("Nothing could be read: " + reads.map { feed, read in
                    "\(feed.title): " + (read.off ?? read.error.map { SentinelOne.fix(for: $0, feed.need) ?? $0.localizedDescription } ?? "")
                }.joined(separator: "; ") + "; \(SentinelOne.disconnectedTitle): " + (SentinelOne.fix(for: error, SentinelOne.agentsNeed) ?? error.localizedDescription))
            }
            let events = reads.flatMap(\.1.events)
            let window = "from \(SentinelOne.iso(since)) to \(SentinelOne.iso(until))"
            let gaps = reads.contains { $0.1.error != nil || $0.1.cut || $0.1.off != nil }
            var lines: [String]
            if events.isEmpty {
                lines = [gaps ? "No watched threats or actions \(window) in what could be read; see below for what was not." : "No watched threats or actions \(window)."]
            } else {
                lines = GoogleCloud.inTurn(events, most: 80).map(\.line)
                if events.count > 80 { lines.append("\(events.count - 80) more in the structured result.") }
            }
            var unread: [String: String] = [:], off: [String: String] = [:], cut: [String] = []
            for (feed, read) in reads {
                if read.error == nil, read.off == nil { lines.append("Searched: \(feed.title) \(window), \(SentinelOne.plural(read.pages, "page")).") }
                if let error = read.error {
                    lines.append("Could not read \(feed.title), so its silence is unknown: \(SentinelOne.fix(for: error, feed.need) ?? error.localizedDescription)")
                    unread[feed.rawValue] = error.localizedDescription
                }
                if let reason = read.off { lines.append("Off: \(reason)"); off[feed.rawValue] = reason }
                if let reason = read.stopped {
                    lines.append("Incomplete: stopped at page \(read.pages + 1) of \(feed.title) because \(reason); what the pages before held is kept.")
                    cut.append(feed.rawValue)
                } else if read.cut {
                    lines.append("Cut short, with more not read: \(feed.title), past \(SentinelOne.eventsPages) pages; narrow the window, or use \(feed == .threats ? "threats" : "activities").")
                    cut.append(feed.rawValue)
                }
            }
            let firstSeen = service.account.flatMap { account in NewSecurityEvents.kept.withLock { $0[account]?.disconnectedSince } } ?? [:]
            if let error = disconnected.error {
                lines.append("Could not read \(SentinelOne.disconnectedTitle), so whether any agent is disconnected is unknown: \(SentinelOne.fix(for: error, SentinelOne.agentsNeed) ?? error.localizedDescription)")
                unread["disconnected"] = error.localizedDescription
            } else {
                let described = disconnected.agents.prefix(40).map { id in "\(id)\(firstSeen[id].map { " (the watch first saw it disconnected at \(SentinelOne.iso($0)))" } ?? "")" }
                lines.append(disconnected.agents.isEmpty ? "No agent is disconnected from the network or has a disconnect pending\(disconnected.complete ? "" : " in what was read")."
                             : "Disconnected from the network or with a disconnect pending now, \(SentinelOne.plural(disconnected.agents.count, "agent")): \(described.joined(separator: ", "))\(disconnected.agents.count > 40 ? ", …" : ""). agent reads each one.")
                if let stopped = disconnected.stopped { lines.append("Incomplete: \(SentinelOne.disconnectedTitle) \(stopped)."); cut.append("disconnected") }
            }
            lines.append(SentinelOne.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let disconnected: [String]; let couldNotRead: [String: String]; let off: [String: String]; let cutShort: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(events: events.sorted { $0.date > $1.date }, disconnected: disconnected.agents, couldNotRead: unread, off: off, cutShort: cut,
                                                      complete: reads.allSatisfy { $0.1.complete && $0.1.error == nil } && disconnected.complete))
        }
    }

    /// The watch: each check reads threats and the activity log, each from six hours before the newest seen or before
    /// the last check that read it whole, whichever is later, as SentinelOne lists some after they happened. What a
    /// check returned is remembered while Pion runs and left out of later checks, so what is read again is not news
    /// again; when a check finds more than it can return, it returns each kind in turn, tells once that more follow,
    /// and the checks after read again from the oldest left out until all of it is returned. A feed that reaches its
    /// page budget keeps the cursor of its next page and the query it belongs to, and the next check goes on with that
    /// query, never from a time; a search that ends leaves a boundary, its end less the six hours, which the feed reads
    /// on from however far the watch moved on meanwhile. Each feed keeps the oldest of what it owes until it is read
    /// whole and all it found returned. Nothing a check read is kept when it fails.
    ///
    /// Disconnected agents are compared with those the last whole read found: the first whole read after Pion starts
    /// only learns them, and each later one returns agents newly disconnected or pending, dated when the check found
    /// them.
    ///
    /// A feed that cannot be read is never dropped unsaid: refused for want of a permission, the token rejected, or the
    /// console without what the feed needs, it is told as an alert of its own, which wakes the agents to read
    /// security-events, whose result names it and why. It is told once each time it starts, and again after a
    /// relaunch, dated at the start of the window read so it never moves the watch past what was not yet read. A cursor
    /// SentinelOne no longer takes is given up and its window read again from its start, told the same way. A failure
    /// that passes, such as the rate limit, holds the watch back instead, a few checks at most, keeping nothing but how
    /// many checks in a row failed, and is then told the same way.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 6 * 3_600 }
        static let holdChecks = 6
        static let remembered = 20_000

        struct Kept: Sendable {
            var inARow: [String: Int] = [:], told: [String: String] = [:]
            var readUntil: [String: Date] = [:]
            var delivered: [String: Date] = [:]
            var owedFrom: [String: Date] = [:]
            var continuations: [String: Continuation] = [:]
            var catchUp: [String: Date] = [:]
            /// The agents the last whole read found disconnected or pending, with when the watch first saw each; nil
            /// until a whole read since Pion started.
            var disconnectedSince: [String: Date]? = nil
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// Whether SentinelOne turned down the request itself, such as a cursor it no longer takes, rather than the
        /// token or for now.
        static func rejects(_ error: Error) -> Bool {
            switch error {
            case ServiceError.refused, ServiceError.notFound: true
            case ServiceError.status(let status, _): (400..<500).contains(status) && status != 408 && status != 429
            default: false
            }
        }

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
            _ = try SentinelOne.console(service)
            let state = account.map { account in Self.kept.withLock { $0[account] ?? Kept() } } ?? Kept()
            let lookBack = lookBack
            let start = { (feed: Feed) -> Date in
                if let search = state.continuations[feed.rawValue] { return search.since }
                var from = since
                if let owed = state.owedFrom[feed.rawValue] { from = owed }
                else if let boundary = state.catchUp[feed.rawValue] { from = boundary }
                else if let until = state.readUntil[feed.rawValue] { from = max(since, until.addingTimeInterval(-lookBack)) }
                // Never further back than security-events reads.
                return max(from, now.addingTimeInterval(-29 * 86_400))
            }
            var reads: [(feed: Feed, read: FeedRead)] = []
            for feed in Feed.allCases {
                reads.append((feed, await SentinelOne.readFeed(feed, service, since: start(feed), until: now, pages: SentinelOne.watchPages,
                                                               from: state.continuations[feed.rawValue])))
            }
            let disconnected = await SentinelOne.readDisconnected(service)
            let failed = reads.filter { $0.read.error != nil }.map { ($0.feed.rawValue, $0.feed.title, $0.read.error!) }
                + (disconnected.error.map { [("disconnected", SentinelOne.disconnectedTitle, $0)] } ?? [])
            let passing = Set(failed.filter { GoogleWorkspace.isPassing($0.2) }.map(\.0))
            let held = holding(passing, account: account)
            if !held.isEmpty {
                let titles = failed.filter { held.contains($0.0) }.map(\.1)
                let said = failed.first { held.contains($0.0) }?.2.localizedDescription ?? ""
                throw ServiceError.input("Could not read \(GoogleCloud.listed(titles)) for now; the next check reads the same window again. \(said)")
            }
            var disconnectedEvents: [WatchedEvent] = []
            if disconnected.complete, let known = state.disconnectedSince {
                for id in disconnected.agents where known[id] == nil {
                    disconnectedEvents.append(WatchedEvent(id: SentinelOne.safeID("disconnected/", "\(id)@\(SentinelOne.iso(now))"), time: SentinelOne.iso(now), tier: 0,
                                                           kind: "agent disconnected", feed: "disconnected",
                                                           line: "\(SentinelOne.iso(now)) Agent \(id) newly disconnected from the network or with a disconnect pending"))
                }
            }
            var seen = Set<String>()
            let events = (reads.flatMap(\.read.events) + disconnectedEvents).filter { seen.insert($0.id).inserted }
            let pending = events.filter { state.delivered[$0.id] == nil }
            var notices: [(label: String, id: String)] = []
            var backlog = false
            for (feed, result) in reads {
                let label = feed.rawValue
                if result.error != nil { notices.append((label, "unreadable/\(label)")) }
                if result.error != nil, result.resumed != nil, Self.rejects(result.error!) { notices.append(("again/\(label)", "unchecked/\(label)")) }
                if result.off != nil { notices.append(("off/\(label)", "unreadable/\(label)")) }
                if let next = result.next {
                    backlog = backlog || next.owed != nil || pending.contains { $0.feed == label } || (result.resumed == nil && state.owedFrom[label] != nil)
                } else if result.cut { notices.append(("more/\(label)", "unchecked/\(label)")) }
            }
            if disconnected.error != nil { notices.append(("disconnected", "unreadable/disconnected")) }
            else if !disconnected.complete { notices.append(("more/disconnected", "unchecked/disconnected")) }
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
                let told = new.map { ServiceAlert(id: $0.1, time: since) }
                let chosen = GoogleCloud.inTurn(pending, most: ServiceAlert.most - told.count)
                let ids = Set(chosen.map(\.id))
                let leftover = Dictionary(grouping: pending.filter { !ids.contains($0.id) }, by: \.feed).compactMapValues { $0.map(\.date).min() }
                var owed: [String: Date] = [:], continuations: [String: Continuation] = [:], readTo: [String: Date] = [:], catchUp: [String: Date] = [:]
                for feed in starts.keys {
                    let result = results[feed]
                    if var next = result?.next {
                        next.owed = [next.owed, leftover[feed]].compactMap { $0 }.min()
                        continuations[feed] = next
                        if let start = starts[feed] { owed[feed] = start }
                        if let boundary = watched.catchUp[feed] { catchUp[feed] = boundary }
                        continue
                    }
                    if let search = result?.resumed, complete[feed] == true {
                        let boundary = search.until.addingTimeInterval(-lookBack)
                        if let held = [search.owed, leftover[feed]].compactMap({ $0 }).min() { owed[feed] = min(held, boundary) } else { catchUp[feed] = boundary }
                        continue
                    }
                    let value: Date? = if complete[feed] == true { leftover[feed] }
                        else { [watched.owedFrom[feed], result?.resumed?.owed, leftover[feed], starts[feed]].compactMap { $0 }.min() }
                    if let value { owed[feed] = value } else if complete[feed] == true { readTo[feed] = now }
                }
                for (feed, boundary) in watched.catchUp where catchUp[feed] == nil && owed[feed] == nil && readTo[feed] == nil && starts[feed] != nil {
                    catchUp[feed] = boundary
                }
                watched.owedFrom = owed
                watched.continuations = continuations
                watched.catchUp = catchUp
                if disconnected.complete {
                    var known: [String: Date] = [:]
                    let returned = Set(chosen.filter { $0.feed == "disconnected" }.map(\.id))
                    for id in disconnected.agents {
                        if let first = watched.disconnectedSince?[id] { known[id] = first }
                        else if watched.disconnectedSince == nil || returned.contains(SentinelOne.safeID("disconnected/", "\(id)@\(SentinelOne.iso(now))")) { known[id] = now }
                    }
                    watched.disconnectedSince = known
                }
                for event in chosen { watched.delivered[event.id] = event.date }
                let oldest = (Array(starts.values) + Array(owed.values) + Array(catchUp.values) + continuations.values.compactMap(\.owed)).min() ?? since
                watched.delivered = watched.delivered.filter { $0.value >= oldest.addingTimeInterval(-60) }
                if watched.delivered.count > Self.remembered {
                    watched.delivered = Dictionary(uniqueKeysWithValues: watched.delivered.sorted { $0.value > $1.value }.prefix(Self.remembered).map { ($0.key, $0.value) })
                }
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
            if reads.allSatisfy({ $0.read.error != nil }), disconnected.error != nil, told.isEmpty, let first = failed.first?.2 { throw first }
            return told + chosen.compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
        }
    }
}
