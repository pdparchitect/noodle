import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Cloudflare Audit's alert watch, and security-events, which reads back what woke the agents, the same way for both:
/// high-risk changes in the account audit log, and bursts of blocked Access logins.
extension Cloudflare {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Limits

    /// The most pages of each feed one check of the watch reads, and one call of security-events.
    static let watchPages = 4, eventsPages = 10
    /// How many each page of the audit log asks for; tests ask for fewer.
    @TaskLocal static var watchPage = 500
    /// How many blocked logins, from one address or for one person within one hour, make a burst.
    static let burst = 10

    // MARK: Feeds

    enum Feed: String, CaseIterable, Sendable {
        case audit, access

        var title: String {
            switch self {
            case .audit: "high-risk changes in the account audit log"
            case .access: "bursts of blocked Access logins"
            }
        }

        var need: Need { self == .audit ? Cloudflare.auditNeed : Cloudflare.accessLogsNeed }
    }

    /// A search cut short at the page budget, to go on with: the page it stopped before, and the query it belongs to,
    /// whose window is fixed, so its pages hold the same entries however many arrive after it. Only the audit log is
    /// read on this way; bursts are counted over a window read whole.
    struct Continuation: Sendable, Equatable {
        let resume: Resume
        let since: Date, until: Date
        let query: [String: String]
        /// The oldest of what its pages found but the checks had no room to return.
        var owed: Date? = nil
    }

    /// What one read of one feed found, and how far it got.
    struct FeedRead {
        var events: [WatchedEvent] = []
        var complete = false
        var cut = false
        var error: Error? = nil
        /// Why the feed has nothing to read, such as an account without Zero Trust.
        var off: String? = nil
        var next: Continuation? = nil
        var resumed: Continuation? = nil
        var pages = 0
        var stopped: String? = nil
    }

    // MARK: What is high-risk

    /// The words of a name, such as an action's type: split at anything but letters and digits and where a lowercase
    /// letter meets a capital, lowercased, so "unpause" is never read as "pause" nor "rec_del" as "rec".
    static func tokens(_ value: String) -> Set<String> {
        var spaced = ""
        var last: Character?
        for character in value {
            if let last, last.isLowercase, character.isUppercase { spaced.append(" ") }
            spaced.append(character)
            last = character
        }
        return Set(spaced.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
    }

    /// What a change left something in, when the entry says so outright: true for off (enabled false, paused true, a
    /// mode or status of off or disabled), false for on, nil when it does not say.
    static func resultingOff(_ value: Value?) -> Bool? {
        guard let value, case .object = value else { return nil }
        if let enabled = value["enabled"]?.flag { return !enabled }
        if let paused = value["paused"]?.flag { return paused }
        for key in ["mode", "status"] {
            guard let text = value[key]?.text?.lowercased() else { continue }
            if ["off", "disabled", "disable", "paused"].contains(text) { return true }
            if ["on", "enabled", "enable", "active", "block", "challenge", "managed_challenge", "js_challenge"].contains(text) { return false }
        }
        return nil
    }

    /// The kind and turn of an audit log entry the watch wakes for, or nil for one it does not, by the words of its
    /// action, its resource and what it changed, as Cloudflare names them. The action is read word by word, inverse
    /// verbs first, so undoing something (unpause, enable, unblock, unrevoke, restore) is never read as doing it; a
    /// state the entry gives outright for what the change left, such as enabled or paused, is preferred to the verb.
    /// Pion cannot tell whether a change to an Access policy loosened it, so every change to Access policies and
    /// applications is watched; a DNS change whose record Cloudflare does not name is watched too, as it cannot be told
    /// apart from one on the apex, MX or NS.
    static func risk(_ entry: Item) -> (kind: String, tier: Int)? {
        if entry.flag("action.result") == false { return nil }
        let verbs = tokens(entry.text("action.type") ?? "")
        let resource = (entry.text("resource.type") ?? "").lowercased()
        let both = verbs.sorted().joined(separator: " ") + " " + resource
        func any(_ words: Set<String>) -> Bool { !verbs.isDisjoint(with: words) }
        // Undoing comes first: these say the opposite of the verbs they contain.
        let undoing = any(["unpause", "enable", "enabled", "unblock", "unrevoke", "restore", "restored", "undelete", "resume", "activate", "reactivate"])
        let made = !undoing && any(["create", "created", "add", "added", "new", "post", "insert"])
        let removed = !undoing && any(["delete", "deleted", "del", "remove", "removed", "destroy"])
        let parsed = entry.text("newValue").flatMap { try? JSONDecoder().decode(Value.self, from: Data($0.utf8)) }
        let stated = resultingOff(entry.fields["newValueJson"]) ?? resultingOff(parsed) ?? resultingOff(entry.fields["metadata"])
        let turnedOff = stated ?? (!undoing && any(["disable", "disabled", "pause", "paused", "deactivate", "suspend"]))
        if both.contains("token") {
            if any(["roll", "rolled", "regenerate"]) { return ("API token rolled", 0) }
            if made { return ("API token made", 0) }
            return nil
        }
        if both.contains("member") || any(["invite"]) {
            return made || any(["invite", "update", "edit", "role", "roles"]) ? ("member added or roles changed", 0) : nil
        }
        // IP Access rules are the firewall's, not Access's.
        if ["firewall", "waf", "ruleset", "access_rule", "rate_limit", "security_level", "page_shield", "bot_management"].contains(where: resource.contains) {
            return removed || turnedOff ? ("firewall or WAF rule turned off or deleted", 0) : nil
        }
        if both.contains("access") && ["policy", "policies", "app", "group", "rule"].contains(where: both.contains) {
            return made || removed || any(["update", "edit", "set", "change"]) ? ("Access policy or application changed", 0) : nil
        }
        if both.contains("gateway") || both.contains("teams") {
            if both.contains("rule") || both.contains("polic") { return removed || turnedOff ? ("Gateway rule turned off or deleted", 0) : nil }
            return nil
        }
        if both.contains("device") || both.contains("warp") {
            if any(["unrevoke"]) { return ("WARP device unrevoked", 1) }
            if any(["revoke", "revoked"]) { return ("WARP device revoked", 1) }
            if any(["register", "registered", "enrol", "enroll", "enrolled"]) || (made && resource.contains("device")) { return ("WARP device enrolled", 1) }
            return nil
        }
        if both.contains("tunnel") { return made ? ("tunnel made", 1) : nil }
        if verbs.contains("rec") || resource.contains("dns") {
            let zone = entry.text("metadata.zone_name")?.lowercased()
            let types = ["metadata.type", "newValueJson.type", "oldValueJson.type"].compactMap { entry.text($0)?.uppercased() }
            let names = ["metadata.name", "newValueJson.name", "oldValueJson.name"].compactMap { entry.text($0)?.lowercased() }
            if types.contains(where: { ["MX", "NS"].contains($0) }) { return ("DNS change on an MX or NS record", 1) }
            if let zone, names.contains(zone) { return ("DNS change on a zone's apex", 1) }
            if types.isEmpty && names.isEmpty { return ("DNS change whose record is not named", 1) }
            return nil
        }
        return nil
    }

    static func auditQuery(since: Date, until: Date) -> [String: String] {
        ["since": iso(since), "before": iso(until), "direction": "desc"]
    }

    // MARK: Reading

    /// The watched entries of one feed from `since` to `until`, or of the search `continuation` from where it stopped.
    /// With `partial`, a page that fails after others keeps what they held and says so; without, the read fails whole.
    static func readFeed(_ feed: Feed, _ service: ServiceClient, since: Date, until: Date, pages: Int, from continuation: Continuation? = nil,
                         partial: Bool = false) async -> FeedRead {
        var read = FeedRead(resumed: continuation)
        let (since, until) = continuation.map { ($0.since, $0.until) } ?? (since, until)
        let within = { (time: Date) in time >= since.addingTimeInterval(-1) && time <= until.addingTimeInterval(1) }
        do {
            let account = try account(service)
            switch feed {
            case .audit:
                let query = continuation?.query ?? auditQuery(since: since, until: until)
                let entries = try await list(service, ["accounts", account, "audit_logs"], query: query, as: Item.self, size: watchPage, pages: pages,
                                             from: continuation?.resume, partial: partial)
                for entry in entries.value {
                    guard let (kind, tier) = risk(entry), let time = ServiceAlert.time(entry.text("when")), within(time) else { continue }
                    read.events.append(WatchedEvent(id: safeID("audit/", entry.id), time: iso(time), tier: tier, kind: kind, feed: feed.rawValue,
                                                    line: "\(iso(time)) \(kind.prefix(1).uppercased() + kind.dropFirst()): \(auditLine(entry))"))
                }
                read.pages = entries.pages
                read.stopped = entries.stopped
                read.complete = entries.complete
                read.cut = !entries.complete
                if let next = entries.next, entries.more, entries.stopped == nil {
                    read.next = Continuation(resume: next, since: since, until: until, query: query, owed: continuation?.owed)
                }
            case .access:
                let logins = try await accessLogins(service, since: since, until: until, pages: pages, partial: partial)
                read.events = bursts(logins.value.filter { $0.allowed == false }).filter { within($0.date) }
                read.pages = logins.pages
                read.stopped = logins.stopped
                read.complete = logins.complete
                read.cut = !logins.complete
            }
        } catch {
            if unlicensed(error) {
                read.off = "\(feed.title) cannot be read: the account does not have \(feed == .access ? "Cloudflare Access" : "what this needs"), so \(feed == .access ? "its logins are" : "it is") not watched."
                read.complete = true
            } else {
                read.error = error
            }
        }
        return read
    }

    /// Blocked logins grouped by address and by person within each hour, each group of at least `burst` one event,
    /// dated at the login that made it a burst, so a group read again with more in it is the same event.
    static func bursts(_ blocked: [AccessLogin]) -> [WatchedEvent] {
        var groups: [String: [AccessLogin]] = [:]
        for login in blocked {
            guard let time = login.date else { continue }
            let hour = iso(Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / 3_600) * 3_600))
            if let ip = login.ip { groups["address \(ip)@\(hour)", default: []].append(login) }
            if let email = login.email { groups["person \(email)@\(hour)", default: []].append(login) }
        }
        // A burst from one address by one person is told once, by its address.
        let byAddress = Set(groups.filter { $0.key.hasPrefix("address ") }.map { key, logins in
            (key.split(separator: "@").last.map(String.init) ?? "") + "|" + logins.map(\.id).sorted().joined(separator: ",")
        })
        return groups.compactMap { key, logins -> WatchedEvent? in
            guard logins.count >= burst else { return nil }
            if key.hasPrefix("person "), byAddress.contains((key.split(separator: "@").last.map(String.init) ?? "") + "|" + logins.map(\.id).sorted().joined(separator: ",")) { return nil }
            let sorted = logins.sorted { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
            guard let time = sorted[burst - 1].date else { return nil }
            let byAddress = key.hasPrefix("address ")
            let who = String(key.dropFirst(byAddress ? 8 : 7).split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).dropLast().joined(separator: "@"))
            let apps = Array(Set(sorted.compactMap(\.app))).sorted().prefix(5)
            let countries = Array(Set(sorted.compactMap(\.country))).sorted().prefix(5)
            return WatchedEvent(id: safeID("access/", key), time: iso(time), tier: 0, kind: "burst of blocked Access logins", feed: Feed.access.rawValue,
                                line: "\(iso(time)) Burst of blocked Access logins: \(sorted.count) blocked \(byAddress ? "from \(who)" : "for \(who)") in the hour from \(key.split(separator: "@").last ?? "?")\(apps.isEmpty ? "" : ", to \(apps.joined(separator: ", "))")\(countries.isEmpty ? "" : ", from \(countries.joined(separator: ", "))")")
        }
    }

    /// The same digest Azure gives an ID a wake carries.
    static func safeID(_ prefix: String, _ value: String) -> String { Azure.safeID(prefix, value) }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: changes in the audit log of kinds Pion does not recognise from Cloudflare's own names for their action and resource, or that Cloudflare logged as failed; whether a change to an Access policy loosened it, as every change to Access policies and applications is told alike; DNS changes on records other than a zone's apex, MX and NS; firewall and Gateway rules made or loosened without being turned off or deleted; blocked Access logins fewer than \(burst) from one address or for one person within an hour, and allowed logins; Gateway's own DNS, HTTP and network decisions, firewall events at the edge, and Cloudflare's Security Center insights, which this watch does not read; changes made through the account's tokens before they reached the audit log; and anything in zones or accounts the token does not cover."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: high-risk changes in the account audit log (API tokens made or rolled, members and roles added, DNS changes on a zone's apex, MX or NS, firewall, WAF and Gateway rules turned off or deleted, Access policies and applications changed, WARP devices enrolled, revoked or unrevoked, and tunnels made) and bursts of blocked Access logins; saying, for each feed, what it searched, what is off, what it could not read and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Cloudflare.window(input.since, input.until, days: 1, maximum: 30)
            var reads: [(Feed, FeedRead)] = []
            for feed in Feed.allCases { reads.append((feed, await Cloudflare.readFeed(feed, service, since: since, until: until, pages: Cloudflare.eventsPages, partial: true))) }
            if reads.allSatisfy({ $0.1.error != nil || $0.1.off != nil }), reads.contains(where: { $0.1.error != nil }) {
                throw ServiceError.input("Nothing could be read: " + reads.map { feed, read in
                    "\(feed.title): " + (read.off ?? read.error.map { Cloudflare.fix(for: $0, feed.need) ?? $0.localizedDescription } ?? "")
                }.joined(separator: "; "))
            }
            let events = reads.flatMap(\.1.events)
            let window = "from \(Cloudflare.iso(since)) to \(Cloudflare.iso(until))"
            let gaps = reads.contains { $0.1.error != nil || $0.1.cut || $0.1.off != nil }
            var lines: [String]
            if events.isEmpty {
                lines = [gaps ? "No watched changes or login bursts \(window) in what could be read; see below for what was not." : "No watched changes or login bursts \(window)."]
            } else {
                lines = GoogleCloud.inTurn(events, most: 80).map(\.line)
                if events.count > 80 { lines.append("\(events.count - 80) more in the structured result.") }
            }
            var unread: [String: String] = [:], off: [String: String] = [:], cut: [String] = []
            for (feed, read) in reads {
                if read.error == nil, read.off == nil { lines.append("Searched: \(feed.title) \(window), \(Cloudflare.plural(read.pages, "page")).") }
                if let error = read.error {
                    lines.append("Could not read \(feed.title), so its silence is unknown: \(Cloudflare.fix(for: error, feed.need) ?? error.localizedDescription)")
                    unread[feed.rawValue] = error.localizedDescription
                }
                if let reason = read.off { lines.append("Off: \(reason)"); off[feed.rawValue] = reason }
                if let reason = read.stopped {
                    lines.append("Incomplete: stopped at page \(read.pages + 1) of \(feed.title) because \(reason); what the pages before held is kept.")
                    cut.append(feed.rawValue)
                } else if read.cut {
                    lines.append("Cut short, with more not read: \(feed.title), past \(Cloudflare.eventsPages) pages; narrow the window, or use \(feed == .audit ? "audit-log" : "access-logs").")
                    cut.append(feed.rawValue)
                }
            }
            lines.append(Cloudflare.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let couldNotRead: [String: String]; let off: [String: String]; let cutShort: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(events: events.sorted { $0.date > $1.date }, couldNotRead: unread, off: off, cutShort: cut,
                                                      complete: reads.allSatisfy { $0.1.complete && $0.1.error == nil }))
        }
    }

    /// The watch: each check reads the audit log and the Access logins, each from six hours before the newest seen or
    /// before the last check that read it whole, whichever is later, as Cloudflare lists some after they happened.
    /// What a check returned is remembered while Pion runs and left out of later checks, so what is read again is not
    /// news again; when a check finds more than it can return, it returns each kind in turn, tells once that more
    /// follow, and the checks after read again from the oldest left out until all of it is returned. When the audit
    /// log reaches its page budget, its search keeps the page it stopped before and the query it belongs to, whose
    /// window is fixed, and the next check goes on with that query, never from a time; a search that ends leaves a
    /// boundary, its end less the six hours, which the feed reads on from however far the watch moved on meanwhile.
    /// Each feed keeps the oldest of what it owes until it is read whole and all it found returned. Nothing a check
    /// read is kept when it fails.
    ///
    /// A feed that cannot be read is never dropped unsaid: refused for want of a permission, the token rejected, or the
    /// account without Access, it is told as an alert of its own, which wakes the agents to read security-events,
    /// whose result names it and why. It is told once each time it starts, and again after a relaunch, dated at the
    /// start of the window read so it never moves the watch past what was not yet read. A page Cloudflare no longer
    /// answers is given up and its window read again from its start, told the same way. A failure that passes, such
    /// as the rate limit, holds the watch back instead, a few checks at most, keeping nothing but how many checks in a
    /// row failed, and is then told the same way.
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
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// Whether Cloudflare turned down the request itself, such as a page it no longer answers, rather than the token
        /// or for now.
        static func rejects(_ error: Error) -> Bool {
            switch error {
            case ServiceError.refused, ServiceError.notFound: true
            case ServiceError.input(let reason): reason.hasPrefix("Cloudflare's answer could not be relied on")
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
            try Cloudflare.api(service)
            _ = try Cloudflare.account(service)
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
                reads.append((feed, await Cloudflare.readFeed(feed, service, since: start(feed), until: now, pages: Cloudflare.watchPages,
                                                              from: state.continuations[feed.rawValue])))
            }
            let failed = reads.filter { $0.read.error != nil }.map { ($0.feed.rawValue, $0.feed.title, $0.read.error!) }
            let passing = Set(failed.filter { GoogleWorkspace.isPassing($0.2) }.map(\.0))
            let held = holding(passing, account: account)
            if !held.isEmpty {
                let titles = failed.filter { held.contains($0.0) }.map(\.1)
                let said = failed.first { held.contains($0.0) }?.2.localizedDescription ?? ""
                throw ServiceError.input("Could not read \(GoogleCloud.listed(titles)) for now; the next check reads the same window again. \(said)")
            }
            var seen = Set<String>()
            let events = reads.flatMap(\.read.events).filter { seen.insert($0.id).inserted }
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
            if reads.allSatisfy({ $0.read.error != nil }), told.isEmpty, let first = failed.first?.2 { throw first }
            return told + chosen.compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
        }
    }
}
