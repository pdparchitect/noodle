import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Duo Detection's alert watch, and security-events, which reads back what woke the agents, the same way for both:
/// fraud users reported and attempts Duo denied from where it should not be reached, administrator changes that open a
/// way around Duo or hand it over, and what Trust Monitor surfaced.
extension Duo {
    typealias WatchedEvent = GoogleCloud.WatchedEvent

    // MARK: Watched events

    /// The authentication log's reasons the watch asks for: a user reporting fraud, and denials that mean someone tried
    /// from where policy forbids or too often.
    static let watchedReasons = ["user_marked_fraud", "anonymous_ip", "location_restricted", "denied_network", "frequent_attempts", "rooted_device"]

    /// What an attempt was that the watch wakes for, the most pressing first.
    static func judge(_ log: AuthLog) -> (tier: Int, kind: String, what: String)? {
        let who = log.user?.name ?? log.user?.key ?? "a user"
        let from = [log.access_device?.ip, AuthLog.place(log.access_device?.location)].compactMap { $0 }.joined(separator: " in ")
        let at = from.isEmpty ? "" : " from \(from)"
        switch log.reason {
        case "user_marked_fraud": return (0, "fraud reported", "\(who) reported a login attempt\(at) as fraud")
        case _ where log.result?.lowercased() == "fraud": return (0, "fraud reported", "\(who) reported a login attempt\(at) as fraud")
        case "anonymous_ip": return (1, "denied from an anonymous network", "Duo denied \(who) an attempt from an anonymous network\(at)")
        case "location_restricted": return (1, "denied from a restricted location", "Duo denied \(who) an attempt from a restricted location\(at)")
        case "denied_network": return (1, "denied from a denied network", "Duo denied \(who) an attempt from a network policy denies\(at)")
        case "frequent_attempts": return (1, "denied for frequent attempts", "Duo denied \(who) for too many attempts\(at), which can mean push fatigue")
        case "rooted_device": return (2, "denied for a rooted phone", "Duo denied \(who) an approval from a jailbroken or rooted phone")
        default: return nil
        }
    }

    /// What an administrator log entry was that the watch wakes for, the most pressing first.
    static func judge(_ entry: AdminLog) -> (tier: Int, kind: String, what: String)? {
        let on = entry.object?.text?.nilIfEmpty
        let action = entry.action ?? ""
        let detail = entry.change?.lowercased() ?? ""
        switch action {
        case "bypass_create": return (0, "bypass code created", "bypass code created for \(on ?? "a user"), letting them skip the second factor")
        case "bypass_view": return (1, "bypass code viewed", "a bypass code of \(on ?? "a user") was viewed")
        case "user_update", "group_update":
            let status = (entry.fields["status"] as? String)?.lowercased()
            guard status == "bypass" else { return nil }
            return (0, "set to bypass", "\(action == "group_update" ? "the group" : "") \(on ?? "a user") set to bypass status, so the second factor is skipped".trimmingCharacters(in: .whitespaces))
        case "admin_create": return (0, "administrator added", "administrator added: \(on ?? "?")")
        case "admin_update": return (1, "administrator changed", "administrator changed: \(on ?? "?")\(detail.contains("role") ? ", including their role" : "")")
        case "admin_single_sign_on_update", "admin_single_sign_on_cert_create", "admin_single_sign_on_cert_update", "update_admin_factor_restrictions":
            return (0, "administrator sign-in changed", "how administrators sign in was changed (\(action))")
        case "integration_skey_view", "integration_skey_bulk_view":
            return (0, "secret key viewed", "the secret key of the application \(on ?? "?") was viewed (\(action))")
        case "integration_create":
            return detail.contains("adminapi") ? (0, "Admin API application created", "Admin API application created: \(on ?? "?"), whose keys can act on Duo")
                : (1, "application created", "application created: \(on ?? "?")")
        case "integration_update":
            return detail.contains("adminapi_") ? (0, "Admin API permissions changed", "permissions of the Admin API application \(on ?? "?") changed") : nil
        case "policy_create", "policy_update", "policy_delete", "policy_bulk_delete", "integration_policy_assign", "integration_policy_unassign",
             "integration_group_policy_add", "integration_group_policy_remove", "integration_group_policy_update":
            return (1, "policy changed", "policy changed (\(action))\(on.map { ": \($0)" } ?? ""); the log does not show whether it weakened Duo, so read the policy")
        case "customer_update": return (1, "global settings changed", "global settings changed")
        case "phone_associate": return (1, "phone added by an administrator", "an administrator added a phone to \(on ?? "a user")")
        case "adminapi_request_ip_denied": return (1, "Admin API request from a denied network", "an Admin API request came from a network the application does not allow")
        case "admin_lockout": return (1, "administrator locked out", "administrator \(on ?? "?") locked out after failed logins")
        default: return nil
        }
    }

    /// A Trust Monitor event as the watch reads it.
    struct TrustEvent: Decodable, Sendable {
        struct Explanation: Decodable, Sendable { let type: String?; let summary: String? }
        let sekey: String?, type: String?, state: String?, surfaced_timestamp: Loose?, triaged_as_interesting: Bool?
        let explanations: [Explanation]?, enabled_by: Loose?, enabled_for: Loose?, surfaced_auth: AuthLog?
    }
    struct TrustPage: Decodable { let events: [TrustEvent]? }

    static func judge(_ event: TrustEvent) -> (tier: Int, kind: String, what: String) {
        let why = (event.explanations ?? []).compactMap { $0.summary ?? $0.type }.prefix(3).joined(separator: "; ")
        switch event.type {
        case "bypass_status":
            return (0, "Trust Monitor: bypass status", "Trust Monitor: bypass status enabled for \(event.enabled_for?.text ?? "?") by \(event.enabled_by?.text ?? "?")")
        case "device_registration":
            return (1, "Trust Monitor: device registration", "Trust Monitor: a risky device registration\(why.isEmpty ? "" : " (\(why))")")
        default:
            let who = event.surfaced_auth?.user?.name ?? "a user"
            return (0, "Trust Monitor: anomalous authentication", "Trust Monitor: an anomalous authentication by \(who)\(why.isEmpty ? "" : " (\(why))")")
        }
    }

    // MARK: Reading

    /// What one read of the three feeds found, and how far each got.
    struct FeedRead {
        var events: [WatchedEvent] = []
        /// By feed, why it could not be read.
        var errors: [String: Error] = [:]
        /// Feeds that had more than one read takes.
        var cut: [String] = []
        /// Whether Trust Monitor is missing from the account's edition.
        var noTrustMonitor = false
    }

    static let authFeed = "authentication log", adminFeed = "administrator log", trustFeed = "Trust Monitor"

    /// Reads each feed once from `since` to `until`: the authentication log's watched reasons, newest first, a page of a
    /// thousand; the administrator log's thousand earliest entries from since; and Trust Monitor's events. Duo rate limits
    /// its logs per account, so each feed is read once a check.
    static func readFeeds(_ service: ServiceClient, since: Date, until: Date) async -> FeedRead {
        var read = FeedRead()
        let window: [String: String?] = ["mintime": milliseconds(since), "maxtime": milliseconds(until)]
        do {
            var query = window
            query["limit"] = "1000"
            query["sort"] = "ts:desc"
            let page = try await Duo.read(.logs) {
                try await get(service, ["admin", "v2", "logs", "authentication"], query: query, repeated: ["reasons": watchedReasons], as: AuthLogPage.self).value
            }
            if page.metadata?.next_offset?.value != nil { read.cut.append(authFeed) }
            for log in page.authlogs ?? [] {
                guard let txid = log.txid, let time = log.time, let judged = judge(log) else { continue }
                read.events.append(WatchedEvent(id: "auth/" + txid, time: iso(time), tier: judged.tier, kind: judged.kind, feed: "auth-log",
                                                line: "\(iso(time)) \(judged.what) [\(txid)]"))
            }
        } catch { read.errors[authFeed] = error }
        do {
            let entries = try await adminLog(service, since: since)
            if entries.count >= adminLogPage { read.cut.append(adminFeed) }
            for entry in entries {
                guard let time = entry.time, time <= until.addingTimeInterval(1), let judged = judge(entry) else { continue }
                let id = Okta.safeID("admin/", [entry.timestamp?.text ?? iso(time), entry.action ?? "", entry.username ?? "", entry.object?.text ?? "", entry.change ?? ""].joined(separator: "|"))
                read.events.append(WatchedEvent(id: id, time: iso(time), tier: judged.tier, kind: judged.kind, feed: "admin-log",
                                                line: "\(iso(time)) \(judged.what), by \(entry.username?.nilIfEmpty ?? "Duo")"))
            }
        } catch { read.errors[adminFeed] = error }
        do {
            var query = window
            query["limit"] = "200"
            let page = try await get(service, ["admin", "v1", "trust_monitor", "events"], query: query, as: TrustPage.self).value
            for event in page.events ?? [] {
                guard let key = event.sekey, let time = event.surfaced_timestamp?.date else { continue }
                let judged = judge(event)
                read.events.append(WatchedEvent(id: "trust/" + key, time: iso(time), tier: judged.tier, kind: judged.kind, feed: "trust-monitor",
                                                line: "\(iso(time)) \(judged.what) [\(key)]"))
            }
        } catch ServiceError.forbidden {
            // Trust Monitor answers 403 on an edition without it; the logs say whether the permission is the cause.
            read.noTrustMonitor = true
        } catch { read.errors[trustFeed] = error }
        return read
    }

    /// What security-events and the watch say they do not cover.
    static let unwatched = "Not watched: successful logins, which auth-logs finds, even with a bypass code or from a new place; denials for other reasons, such as a wrong passcode or a user who did not answer; users or devices added, removed or disabled; and calls and SMS sent, which telephony-logs reads. Policies and settings changed are told, but the log does not show whether a change weakened them."

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What the alert watch wakes for, for a window, newest first and each kind in turn: fraud users reported; attempts denied from anonymous networks, restricted locations or denied networks, for too many attempts or from rooted phones; bypass codes created or viewed; users or groups set to bypass; administrators added or changed and how they sign in; Admin API applications created, their permissions changed or any application's secret key viewed; policies and global settings changed; phones added by administrators; and Trust Monitor's events; saying what it read, what it could not and why, and what it does not watch."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 180 days."),
            "until": .string("The latest time, in ISO 8601, included. Now when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Duo.window(input.since, input.until, days: 1)
            let read = await Duo.readFeeds(service, since: since, until: until)
            if read.errors.count == 3, let error = read.errors[Duo.authFeed] { throw error }
            let window = "from \(Duo.iso(since)) to \(Duo.iso(until))"
            var lines: [String]
            if read.events.isEmpty {
                lines = [read.errors.isEmpty && read.cut.isEmpty ? "No watched events \(window)." : "No watched events in what was read \(window); see below for what was not."]
            } else {
                lines = GoogleCloud.inTurn(read.events, most: 80).map(\.line)
                if read.events.count > 80 { lines.append("\(read.events.count - 80) more in the structured result.") }
            }
            let readFeeds = [Duo.authFeed, Duo.adminFeed, Duo.trustFeed].filter { read.errors[$0] == nil && !($0 == Duo.trustFeed && read.noTrustMonitor) }
            lines.append("Read \(window): \(readFeeds.joined(separator: ", ")).")
            for (feed, error) in read.errors.sorted(by: { $0.key < $1.key }) { lines.append("Not read: the \(feed): \(error.localizedDescription)") }
            if read.noTrustMonitor { lines.append("Trust Monitor: Duo refused it, so this edition most likely lacks it (it is part of Duo Premier and Duo Advantage); check-access says whether a permission is the cause.") }
            if read.cut.contains(Duo.authFeed) { lines.append("Cut short: more denied or fraudulent attempts than the 1000 newest read; use auth-logs with a reason and an earlier until for the rest.") }
            if read.cut.contains(Duo.adminFeed) { lines.append("Cut short: the administrator log had more than the 1000 earliest entries read from since; use admin-logs with a later since for the rest.") }
            lines.append(Duo.unwatched)
            struct Kept: Encodable { let events: [WatchedEvent]; let complete: Bool; let unread: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(events: read.events.sorted { $0.date > $1.date }, complete: read.errors.isEmpty && read.cut.isEmpty,
                                                      unread: read.errors.keys.sorted() + read.cut))
        }
    }

    /// The watch: each check reads the three feeds once from `since`, which the app sets an hour before the newest alert
    /// it has seen, and returns what it has not returned before, each kind in turn when there is more than one check
    /// returns. A feed Duo refuses, or one with more than a check reads, is told as an alert of its own, once while it
    /// lasts, which wakes the agents to read security-events, whose result says why. A failure that passes, such as Duo
    /// rate limiting, fails the check so the next reads the same again, a few checks at most before it too is told.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        var lookBack: TimeInterval { 3_600 }
        static let holdChecks = 6

        /// What the checks of one connection keep between them while Pion runs.
        struct Kept: Sendable {
            var inARow = 0
            /// The notices current, by label, each told once while it lasts.
            var told: Set<String> = []
            /// What the checks returned, by ID, with when it happened.
            var delivered: [String: Date] = [:]
        }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// Applies `change` to what `account` keeps, or to a scratch copy when there is no account.
        private func update<Result>(_ account: UUID?, _ change: (inout Kept) -> Result) -> Result {
            guard let account else { var scratch = Kept(); return change(&scratch) }
            return Self.kept.withLock { kept in
                var watched = kept[account] ?? Kept()
                let result = change(&watched)
                kept[account] = watched
                return result
            }
        }

        func alerts(since: Date, on service: ServiceClient, account: UUID?, now: Date = Date()) async throws -> [ServiceAlert] {
            let from = max(since, now.addingTimeInterval(-(Duo.logDays - 1) * 86_400))
            let read = await Duo.readFeeds(service, since: from, until: now)
            let passing = read.errors.values.filter(GoogleWorkspace.isPassing)
            if !passing.isEmpty {
                let streak = update(account) { watched -> Int in watched.inARow += 1; return watched.inARow }
                if streak <= Self.holdChecks {
                    throw ServiceError.input("Could not read Duo's logs for now; the next check reads the same again. \(passing[0].localizedDescription)")
                }
            }
            var notices = read.errors.keys.map { "unreadable/\($0)" }
            notices += read.cut.map { "more/\($0)" }
            let delivered = account.map { account in Self.kept.withLock { $0[account]?.delivered ?? [:] } } ?? [:]
            let pending = read.events.filter { delivered[$0.id] == nil }
            return update(account) { watched -> [ServiceAlert] in
                if passing.isEmpty { watched.inARow = 0 }
                let current = Set(notices)
                let new = current.subtracting(watched.told).sorted()
                watched.told = current
                let told = new.map { ServiceAlert(id: "\($0.replacingOccurrences(of: " ", with: "-"))/\(UUID().uuidString)", time: from) }
                let chosen = GoogleCloud.inTurn(pending, most: ServiceAlert.most - told.count)
                for event in chosen { watched.delivered[event.id] = event.date }
                watched.delivered = watched.delivered.filter { $0.value >= from.addingTimeInterval(-60) }
                return told + chosen.compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
            }
        }
    }
}

private extension String {
    /// Nil for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
