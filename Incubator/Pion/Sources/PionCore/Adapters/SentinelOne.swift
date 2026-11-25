import Foundation
import NoodleCore
import NoodleToolConnections

/// SentinelOne: its agents and the endpoints they run on, the threats they found with their indicators, storylines,
/// timelines and notes, the activity log of who did what, sites, groups and exclusions, read with a service user's API
/// token. Each account is one management console. SentinelOne Detection only reads; SentinelOne Containment, a tool of its
/// own with a service user and token of its own, disconnects agents from the network, mitigates threats, sets their
/// status and verdict, blocks hashes and starts scans.
///
/// SentinelOne has no sign-in for an admin: each tool sends its own service user's API token, as
/// `Authorization: ApiToken <token>`, and may do exactly what that user's role allows in that user's scope. Detection's
/// user holds the Viewer role; Containment's a custom role with only the actions it takes. check-access reads the
/// token's own user, its role and scope, and sends no change.
///
/// Every console is its own host under sentinelone.net, such as usea1-acme.sentinelone.net. Pion sends nothing to
/// any other host: every request, and every next page, which SentinelOne gives as a cursor rather than an address,
/// goes to the console the connection names, under /web/api/v2.1.
///
/// Both tools' guide is Incubator/Pion/docs/tools/sentinelone.md. Change it with the setup steps, roles or operations here.
public enum SentinelOne {
    public static let preset = ToolDefinition(
        id: "9d1c01e9-bb44-4a66-876a-e60b48337ca3", name: "SentinelOne Detection",
        summary: "Agents, threats with their indicators, timelines and notes, the activity log, sites, groups and exclusions in SentinelOne, read-only.",
        defaultInstructions: """
        Use SentinelOne Detection to see endpoints as SentinelOne's agents do. agents finds agents by computer name, \
        network status, infection, OS, site or group, and agent reads one in full: whether it is disconnected from the \
        network, infected and with how many active threats, its OS, addresses, when last active, and its unresolved \
        threats. threats lists threats by computer, agent, incident status, confidence and time, and threat reads one \
        with its file, hashes, process, storyline, MITRE indicators, every mitigation action and its status, notes and \
        timeline. activities reads the activity log, who did what and when, by agent, threat, user, type and time; \
        activity-types names the types. sites, groups and exclusions list them: exclusions say who added each and when, \
        and an exclusion an attacker added hides what they do, so read new ones closely. Each agent's and threat's \
        numeric ID is what SentinelOne Containment acts on. The alert watch checks every five minutes and wakes you \
        with a note naming security-events, which reads what it found for the note's window: new unresolved malicious \
        or suspicious threats, agents newly disconnected from the network, and network disconnects and threat \
        mitigations a person issued. A note may name a feed the watch could not read: security-events says why, so tell \
        the champion and treat that feed's silence as unknown. When a tool is refused or something you need seems \
        missing, run check-access and tell the champion exactly what it says to change. Silence is not proof: every \
        result says when it stopped before reading everything or matched more than it kept, and the token sees only \
        its service user's scope. Record each finding as evidence, citing the agent and threat. These tools only read: \
        recommend disconnecting an endpoint or other responses to the champion, or use SentinelOne Containment, with \
        the agent or threat, why, and how to undo it.
        """,
        iconName: "sentinelone",
        configuration: .connection(.init(endpointTemplate: "https://{console}/web/api/v2.1", fields: [consoleField],
                                         tokenHeader: "Authorization", tokenScheme: "ApiToken", adapter: "sentinelone")),
        setup: setup)

    static let consoleField = ToolField(key: "console", title: "Console address", placeholder: "usea1-acme.sentinelone.net", kind: .host)
    /// The only domain Pion sends a token to.
    static let consoleDomain = "sentinelone.net"
    static let consoleStep = "For the console address, give your console's host as your browser shows it, such as `usea1-acme.sentinelone.net`: a host under `sentinelone.net`. Pion reaches no other host, so an on-premises or other console is refused. Then ask an agent to run check-access."

    static let setup = [
        "In the SentinelOne console, open **Settings › Users › Service Users** and choose **Actions › Create New Service User**. Name it Pion Detection, kept for this tool alone, and give it an expiration date.",
        "Give it the **Viewer** role, which only reads, at the scope agents should see: the account, or only the sites to investigate. Nothing else: Audit sends no change, and check-access warns of any role but Viewer.",
        "Copy the **API token** it shows and give it here; SentinelOne shows it only once. Pion sends it as `Authorization: ApiToken <token>`. The token ends on the date set: make a new one for the same user before then.",
        consoleStep,
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        Agents(), AgentDetails(), Threats(), ThreatDetails(), Activities(), ActivityTypes(), Sites(), Groups(), Exclusions(), SecurityEvents(),
        CheckAccess(),
        ContainmentAgent(), ContainmentThreat(), ActionStatus(), DisconnectAgent(), ReconnectAgent(), InitiateScan(), KillThreat(),
        QuarantineThreat(), UnquarantineThreat(), RemediateThreat(), RollbackThreat(), ResolveThreat(), UpdateThreatStatus(), BlockHash(),
        UnblockHash(), ContainmentCheckAccess(),
    ]

    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents(),
                                                 // SentinelOne limits each token's requests a second per endpoint.
                                                 simultaneousRequests: 4)

    // MARK: Limits

    /// The most pages one listing reads.
    static let maximumPages = 10
    /// How far back searches by time may reach.
    static let keptDays = 365.0

    // MARK: Requests

    /// The console the connection reaches, or a refusal, before anything is sent: https, no port, a host under
    /// sentinelone.net, and the management API's path.
    static func console(_ service: ServiceClient) throws -> String {
        let suffix = "." + consoleDomain
        guard service.base.scheme?.lowercased() == "https", let host = service.base.host?.lowercased(), service.base.port == nil, service.base.user == nil,
              host.hasSuffix(suffix), host.count > suffix.count, !host.dropLast(suffix.count).hasSuffix("."),
              service.base.path == "/web/api/v2.1" else {
            throw ServiceError.input("Nothing was sent: this connection's console address is not a SentinelOne console under \(consoleDomain), which is all Pion reaches. Give the console's host, such as usea1-acme.sentinelone.net, in Settings › Tools.")
        }
        return host
    }

    /// How long Pion itself waits, at most, for SentinelOne's rate limit before trying once more.
    static let patience = 20.0
    /// How Pion waits; tests pass time without it.
    @TaskLocal static var pause: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    /// What SentinelOne said when it refused: the title and detail of each error it listed, or the usual fields.
    static func reason(_ data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(Errors.self, from: data), let problems = envelope.problems { return String(problems.prefix(300)) }
        return ServiceClient.reason(data)
    }

    /// One request to the connection's console, with every answer back for the caller to judge.
    static func raw(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET",
                    body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        _ = try console(service)
        var answer = try await service.exchange(path, query: query, method: method, body: body, returning: Set(300...599))
        // The transport has tried a 429 again on its own back-off; when SentinelOne says how long to wait and it is
        // soon, wait once more. A 429 means it did nothing with the request, so even a change may go again.
        if answer.response.statusCode == 429, let wait = CrowdStrike.retryWait(answer.response), wait <= patience {
            await pause(wait)
            answer = try await service.exchange(path, query: query, method: method, body: body, returning: Set(300...599))
        }
        return answer
    }

    static func exchange(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET",
                         body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        let answer = try await raw(service, path, query: query, method: method, body: body)
        try check(answer)
        return answer
    }

    /// Throws for any answer but a success, in SentinelOne's own words.
    static func check(_ answer: (data: Data, response: HTTPURLResponse)) throws {
        let status = answer.response.statusCode, said = reason(answer.data)
        switch status {
        case 200..<300: return
        case 429:
            let wait = CrowdStrike.retryWait(answer.response).map { "SentinelOne asked to wait \(Int($0.rounded(.up))) seconds before trying again" }
            throw ServiceError.rateLimited([wait, said].compactMap { $0 }.joined(separator: "; "))
        case 401: throw ServiceError.rejected(said)
        case 403: throw ServiceError.forbidden(said)
        case 404: throw ServiceError.notFound
        case 400, 405, 409, 412, 422: throw said.map(ServiceError.refused) ?? ServiceError.status(status)
        default: throw ServiceError.status(status, said)
        }
    }

    /// One error SentinelOne gave, read loosely, as an entry without a message is an error all the same.
    struct Problem: Decodable, Sendable {
        let code: Int?, title: String?, detail: String?
        /// The ID the error is about, when it names one in a field of its own.
        let id: String?
        enum Keys: String, CodingKey { case code, title, detail, id }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            code = ((try? container.decodeIfPresent(Int.self, forKey: .code)) ?? nil)
                ?? ((try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil).flatMap { Int($0) }
            id = ((try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil)
                ?? ((try? container.decodeIfPresent(Int.self, forKey: .id)) ?? nil).map(String.init)
            title = ((try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            detail = ((try? container.decodeIfPresent(String.self, forKey: .detail)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        }
        /// Whether its code says not found: exactly 404. SentinelOne's API reference documents no code of its own for
        /// an entity that does not exist, so none of its seven-digit codes is taken for one.
        var notFoundCode: Bool { code == 404 }
        var said: String {
            let words = [title, detail].compactMap { $0 }.joined(separator: ": ")
            return words.isEmpty ? code.map { "error \($0) without a message" } ?? "an error without a message or code" : words
        }
    }

    struct Pagination: Decodable, Sendable {
        let nextCursor: String?
        let totalItems: Int?
        enum Keys: String, CodingKey { case nextCursor, totalItems }
        /// Each field null, left out, or of its own type: a count that is not a whole number, or a cursor that is not
        /// text, makes the whole answer unreadable rather than one without them.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            totalItems = try container.decodeIfPresent(Int.self, forKey: .totalItems)
        }
    }

    /// SentinelOne's answer for a list: its data, paging and errors. A list it leaves out is unreadable, never an
    /// empty one, unless its paging says nothing matched; a list that comes with any error is never taken as whole.
    struct Envelope<Item: Decodable>: Decodable {
        let data: [Item]?
        let pagination: Pagination?
        let errors: [Problem]?

        var hasErrors: Bool { !(errors ?? []).isEmpty }
        var problems: String? { hasErrors ? (errors ?? []).prefix(3).map(\.said).joined(separator: "; ") : nil }

        func items() throws -> [Item] {
            if let problems { throw ServiceError.refused(problems) }
            if let data { return data }
            if pagination?.totalItems == 0 { return [] }
            throw ServiceError.unreadable
        }
    }

    /// Only the errors and paging of an answer, whatever its data.
    struct Errors: Decodable {
        let errors: [Problem]?
        let pagination: Pagination?
        var problems: String? { (errors ?? []).isEmpty ? nil : (errors ?? []).prefix(3).map(\.said).joined(separator: "; ") }
    }

    /// SentinelOne's answer for one thing, such as an action's count or the token's user.
    struct Single<Item: Decodable>: Decodable {
        let data: Item?
        let errors: [Problem]?
        var problems: String? { (errors ?? []).isEmpty ? nil : (errors ?? []).prefix(3).map(\.said).joined(separator: "; ") }
    }

    static func decode<Value: Decodable>(_ data: Data, as: Value.Type = Value.self) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) } catch { throw ServiceError.unreadable }
    }

    static func get<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], as: Item.Type) async throws -> Envelope<Item> {
        try decode(try await exchange(service, path, query: query).data)
    }

    // MARK: Paging

    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// How many SentinelOne said match, when it said.
        var total: Int? = nil
        /// Why it stopped before the end, when not for its page or item limit, such as a page that failed.
        var stopped: String? = nil
        var stoppedAt: Int? = nil
        /// The cursor of the next page, when it stopped at its page or item limit with more to read; good only with
        /// the query it came from.
        var next: String? = nil
        var complete: Bool { !more && stopped == nil }
    }

    /// The items and paging of one page of a plain list.
    static func page<Item: Decodable>(_ data: Data) throws -> (items: [Item], pagination: Pagination?) {
        let envelope: Envelope<Item> = try decode(data)
        return (try envelope.items(), envelope.pagination)
    }

    /// A listing, page after page of `size`, up to `pages` or until `limit` items are kept. Each next page asks the same
    /// path with the same query and the cursor the last page gave; `from` goes on with a cursor a listing stopped at
    /// before, which must come with the query it came from. It ends at a page without a cursor, and stops, saying so,
    /// where SentinelOne said more match than it gave, gave a cursor Pion will not follow, or the same one again.
    ///
    /// When a page after the first fails, what earlier pages held is kept and the listing says where and why it
    /// stopped, unless `partial` is false, for a reader that must have all or nothing.
    static func list<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?], as: Item.Type, size: Int,
                                      pages: Int = maximumPages, limit: Int? = nil, from: String? = nil, partial: Bool = true,
                                      extract: ((Data) throws -> (items: [Item], pagination: Pagination?))? = nil) async throws -> Listing<Item> {
        var cursor = from
        var found = Listing<Item>()
        func stop(_ reason: String) -> Listing<Item> {
            found.more = true
            found.next = nil
            found.stoppedAt = found.pages + 1
            found.stopped = reason
            return found
        }
        while found.pages < pages {
            var asked = query
            asked["limit"] = String(size)
            if let cursor { asked["cursor"] = cursor }
            let items: [Item], pagination: Pagination?
            do {
                let data = try await exchange(service, path, query: asked).data
                let read: (items: [Item], pagination: Pagination?) = try extract?(data) ?? page(data)
                (items, pagination) = (read.items, read.pagination)
            } catch {
                guard partial, found.pages > 0 else { throw error }
                return stop(error.localizedDescription)
            }
            found.pages += 1
            found.value += items
            if let total = pagination?.totalItems { found.total = total }
            if let next = pagination?.nextCursor, !next.isEmpty {
                guard let token = CrowdStrike.token(next) else { return stop("SentinelOne gave a next page Pion does not follow") }
                guard token != cursor else { return stop("SentinelOne gave the same next page again") }
                guard !items.isEmpty else { return stop("SentinelOne gave an empty page that said more follow") }
                found.more = true
                found.next = token
                cursor = token
                if let limit, found.value.count >= limit { return found }
            } else {
                if from == nil, let total = found.total, found.value.count < total {
                    return stop("SentinelOne said \(total) match but gave no next page after \(found.value.count)")
                }
                found.more = false
                found.next = nil
                return found
            }
        }
        return found
    }

    static func stopped<Item>(_ listing: Listing<Item>, _ name: String) -> String {
        if let reason = listing.stopped {
            return "\nIncomplete: stopped at page \(listing.stoppedAt ?? listing.pages + 1) reading \(name) because \(reason); what the \(plural(listing.pages, "page")) before held is kept."
        }
        return listing.more ? "\nIncomplete: stopped after \(plural(listing.pages, "page")) reading \(name), the most read at once; more remain\(listing.total.map { ", of \($0) SentinelOne said match" } ?? "")." : ""
    }

    /// What SentinelOne says of one thing asked for by its exact ID.
    enum Lookup<Item> {
        case present(Item)
        /// SentinelOne said plainly it holds none: an answer with no next page, no errors, an empty list and a count of
        /// none or no count; or a 404 whose every error has code 404 and names this very ID in its id field.
        case absent
        /// Anything else, which shows neither: errors, another item, the same one twice, or an answer that could not
        /// be read.
        case inconclusive(String)
    }

    /// One thing by its exact ID through a list filtered to it; `query` holds the filter.
    static func lookup<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?], id: String, idOf: (Item) -> String?,
                                        what: String) async throws -> Lookup<Item> {
        let answer = try await raw(service, path, query: query)
        if answer.response.statusCode != 404 { try check(answer) }
        guard let envelope = try? JSONDecoder().decode(Envelope<Item>.self, from: answer.data) else {
            if answer.response.statusCode == 404 { return .inconclusive("SentinelOne answered 404 for \(what) \(id) without saying that \(what) was not found") }
            return .inconclusive("SentinelOne's answer for \(what) \(id) could not be read")
        }
        // A 404 is absence only when every error it carries has a not-found code and names this very ID in its own id
        // field. Wording is never read: a 404 for a route echoes the request's address, IDs included.
        if answer.response.statusCode == 404 {
            let errors = envelope.errors ?? []
            let names = !errors.isEmpty && errors.allSatisfy { $0.notFoundCode && $0.id == id }
            guard (envelope.data ?? []).isEmpty, names else {
                return .inconclusive("SentinelOne answered 404 for \(what) \(id) without saying that \(what) was not found\(envelope.problems.map { " (it said: \($0))" } ?? "")")
            }
            return .absent
        }
        if let problems = envelope.problems { return .inconclusive("SentinelOne's answer for \(what) \(id) carried errors: \(problems)") }
        guard let data = envelope.data else { return .inconclusive("SentinelOne's answer for \(what) \(id) gave no list") }
        // Only a whole, consistent answer shows absence or a single match: one with a next page may hold the ID on a
        // page not read, whatever count it gives, and one that counts none while giving items contradicts itself.
        if !(envelope.pagination?.nextCursor ?? "").isEmpty { return .inconclusive("SentinelOne's answer for \(what) \(id) said more follow on another page") }
        if envelope.pagination?.totalItems == 0, !data.isEmpty { return .inconclusive("SentinelOne's answer for \(what) \(id) counted none but gave \(plural(data.count, "item"))") }
        let named = data.filter { idOf($0) == id }
        let others = data.filter { idOf($0) != id }.compactMap(idOf)
        if !others.isEmpty || named.count != data.count { return .inconclusive("SentinelOne answered for \(others.isEmpty ? "something without an ID" : others.prefix(3).joined(separator: ", ")), not \(what) \(id) alone") }
        if let total = envelope.pagination?.totalItems, total != data.count { return .inconclusive("SentinelOne counted \(total) for \(what) \(id) but gave \(plural(data.count, "item"))") }
        switch named.count {
        case 0: return .absent
        case 1: return .present(named[0])
        default: return .inconclusive("SentinelOne's answer names \(what) \(id) \(named.count) times")
        }
    }

    /// A window of at most `maximum` days, since before until; `days` back from now when since is left out.
    static func window(_ since: String?, _ until: String?, days: Double, maximum: Double = keptDays) throws -> (since: Date, until: Date) {
        try CrowdStrike.window(since, until, days: days, maximum: maximum)
    }

    static func iso(_ date: Date) -> String { Entra.iso(date) }

    // MARK: Refusals

    /// What one thing a tool reads or does needs: the permission, as the console's role editor groups it.
    struct Need: Sendable {
        let title: String
        let permission: String
    }

    static let agentsNeed = Need(title: "Agents", permission: "Endpoints: View")
    static let threatsNeed = Need(title: "Threats", permission: "Threats: View")
    static let activitiesNeed = Need(title: "The activity log", permission: "Activity: View")
    static let sitesNeed = Need(title: "Sites", permission: "Sites: View")
    static let groupsNeed = Need(title: "Groups", permission: "Groups: View")
    static let exclusionsNeed = Need(title: "Exclusions", permission: "Exclusions: View")
    static let userNeed = Need(title: "The token's own user", permission: "the service user's own details, which every role reads")

    /// Whether SentinelOne refused for want of a licence or module, rather than a permission.
    static func unlicensed(_ error: Error) -> Bool {
        let said: String
        switch error {
        case ServiceError.forbidden(let reason?), ServiceError.refused(let reason): said = reason.lowercased()
        default: return false
        }
        return said.contains("licen") || said.contains("not entitled") || said.contains("entitlement") || said.contains("sku") || said.contains("add-on")
    }

    /// What to change when a request was refused; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        switch error {
        case ServiceError.rejected:
            return "SentinelOne did not accept the API token: it expired, was revoked or regenerated, or its service user was deleted. Make a new token for the service user in Settings › Users › Service Users (Actions › Generate API Token), and give it in Settings › Tools."
        case ServiceError.forbidden where unlicensed(error):
            return "this needs a SentinelOne licence or module the console lacks, so it cannot be read."
        case ServiceError.forbidden:
            return "the service user's role lacks \(need.permission), or what was asked lies outside its scope (its account or sites). Change the role or scope in Settings › Users › Service Users, then try again."
        default: return nil
        }
    }

    /// A request, with a refusal said as what to change.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("SentinelOne refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows the token's user, role and scope.")
        }
    }

    // MARK: Inputs

    /// An ID as SentinelOne gives agents, threats, sites, groups, users and blocklist entries: digits only.
    static func id(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...30).contains(value.count) && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber) ? value : nil
    }

    static func requireID(_ value: String, _ name: String) throws -> String {
        guard let id = id(value) else { throw ServiceError.input("Give \(name) as SentinelOne gives it: digits only, such as 1234567890123456789.") }
        return id
    }

    /// A computer name as a filter takes it: no comma, which SentinelOne reads as one more value to match.
    static func computerName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...255).contains(value.count), !value.contains(","),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.$ ").contains) else {
            throw ServiceError.input("Give the computer's name as SentinelOne shows it, such as LT-0423: letters, digits, dots, hyphens and underscores, without commas.")
        }
        return value
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// A field's value as text: text itself, or a number or flag written out.
    static func text(_ fields: [String: CellValue]?, _ key: String) -> String? {
        switch fields?[key] {
        case .text(let value)?: value.isEmpty ? nil : value
        case .number?, .flag?: fields?[key]?.shown
        default: nil
        }
    }

    static func flag(_ fields: [String: CellValue]?, _ key: String) -> Bool? { if case .flag(let value)? = fields?[key] { return value }; return nil }
    static func number(_ fields: [String: CellValue]?, _ key: String) -> Int? { if case .number(let value)? = fields?[key], value.rounded() == value { return Int(value) }; return nil }
    static func list(_ fields: [String: CellValue]?, _ key: String) -> [String] {
        switch fields?[key] {
        case .list(let list)?: list.filter { !$0.isEmpty }
        case .text(let text)?: text.isEmpty ? [] : [text]
        default: []
        }
    }
}

// MARK: - Agents

extension SentinelOne {
    /// An agent as SentinelOne describes it, read field by field so a field it leaves out or gives in another shape is
    /// unknown rather than a failure; only its ID must be there, and an agent without one is unreadable.
    struct Agent: Sendable, Decodable {
        let fields: [String: CellValue]
        let id: String

        init?(_ fields: [String: CellValue]) {
            guard let raw = SentinelOne.text(fields, "id"), let id = SentinelOne.id(raw) else { return nil }
            self.fields = fields
            self.id = id
        }

        init(from decoder: Decoder) throws {
            guard let agent = Agent(try [String: CellValue](from: decoder)) else { throw ServiceError.unreadable }
            self = agent
        }

        func text(_ key: String) -> String? { SentinelOne.text(fields, key) }
        var name: String? { text("computerName") }
        var named: String { "\(name ?? "an unnamed agent") [\(id)]" }
        /// Whether Disconnect from Network is in force: connected, connecting, disconnected or disconnecting.
        var network: String? { text("networkStatus")?.lowercased() }
        var osType: String? { text("osType")?.lowercased() }
        /// Whether the agent is in touch with the console now.
        var active: Bool? { SentinelOne.flag(fields, "isActive") }
        var infected: Bool? { SentinelOne.flag(fields, "infected") }
        var activeThreats: Int? { SentinelOne.number(fields, "activeThreats") }
        var scanStatus: String? { text("scanStatus")?.lowercased() }

        var line: String {
            var parts = [[text("osName"), text("osRevision")].compactMap { $0 }.joined(separator: " ")].filter { !$0.isEmpty }
            if parts.isEmpty { parts.append("OS unknown") }
            parts.append("network \(SentinelOne.network(network))")
            parts.append(active.map { $0 ? "in touch with the console" : "not in touch with the console" } ?? "whether in touch with the console unknown")
            switch infected {
            case true?: parts.append("infected, \(activeThreats.map { SentinelOne.plural($0, "active threat") } ?? "active threats not given")")
            case false?: parts.append("not infected")
            case nil: parts.append("infection unknown")
            }
            parts.append("agent \(text("agentVersion") ?? "version unknown")")
            if let site = text("siteName") { parts.append("site \(site)\(text("groupName").map { ", group \($0)" } ?? "")") }
            if let ip = text("lastIpToMgmt") { parts.append("IP to console \(ip)") }
            if let ip = text("externalIp") { parts.append("external IP \(ip)") }
            if SentinelOne.flag(fields, "isDecommissioned") == true { parts.append("decommissioned") }
            if SentinelOne.flag(fields, "isUninstalled") == true { parts.append("uninstalled") }
            parts.append("last active \(text("lastActiveDate") ?? "unknown")")
            return "\(named): " + parts.joined(separator: ", ")
        }
    }

    /// A network status, said plainly: pending is not done, and none given is unknown.
    static func network(_ status: String?) -> String {
        switch status {
        case "connected": "connected (not disconnected from the network)"
        case "disconnected": "disconnected from the network"
        case "disconnecting": "disconnect pending (asked for, not yet in force)"
        case "connecting": "reconnect pending (still disconnected until the agent reconnects)"
        case let other?: "\(other) (a status Pion does not know)"
        case nil: "not given, so unknown"
        }
    }

    static let networkStatuses = ["connected", "connecting", "disconnected", "disconnecting"]
    static let osTypes = ["windows", "macos", "linux"]

    /// One agent by its exact ID.
    static func agent(_ id: String, _ service: ServiceClient) async throws -> Lookup<Agent> {
        try await read(agentsNeed) {
            try await lookup(service, ["agents"], query: ["ids": id], id: id, idOf: { (agent: Agent) in agent.id }, what: "agent")
        }
    }

    struct Agents: ServiceOperation {
        struct Input: Decodable, Sendable { let name: String?, networkStatus: String?, infected: Bool?, osType: String?, siteId: String?, groupId: String?, activeSince: String?, limit: Int? }
        static let name = "agents"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Find agents by part of their computer name, network status, infection, OS, site or group, most recently active first, with each one's ID, OS, whether it is disconnected from the network, infected and in touch with the console, and when last active, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "name": .string("All or part of the computer's name, such as LT-04."),
            "networkStatus": .string("Whether Disconnect from Network is in force.", oneOf: SentinelOne.networkStatuses),
            "infected": .boolean("Only infected agents, or only clean ones."),
            "osType": .string("The OS.", oneOf: SentinelOne.osTypes),
            "siteId": .string("A site's ID, as sites lists it."),
            "groupId": .string("A group's ID, as groups lists it."),
            "activeSince": .string("Only agents active since this time, in ISO 8601."),
            "limit": .integer("How many agents, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["sortBy": "lastActiveDate", "sortOrder": "desc"]
            if let name = input.name { query["computerName__contains"] = try SentinelOne.computerName(name) }
            if let status = input.networkStatus { query["networkStatuses"] = try ServiceInput.oneOf(status, SentinelOne.networkStatuses, "networkStatus") }
            if let infected = input.infected { query["infected"] = infected ? "true" : "false" }
            if let os = input.osType { query["osTypes"] = try ServiceInput.oneOf(os, SentinelOne.osTypes, "osType") }
            if let site = input.siteId { query["siteIds"] = try SentinelOne.requireID(site, "the site's ID") }
            if let group = input.groupId { query["groupIds"] = try SentinelOne.requireID(group, "the group's ID") }
            if let since = input.activeSince { query["lastActiveDate__gte"] = try ServiceInput.time(since) }
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 agents.") }
            let listing = try await SentinelOne.read(SentinelOne.agentsNeed) {
                try await SentinelOne.list(service, ["agents"], query: query, as: Agent.self, size: min(limit, 500), limit: limit)
            }
            let agents = Array(listing.value.prefix(limit))
            var text = agents.isEmpty ? "No agent matches\(listing.complete ? "" : " in what was read")."
                : "\(SentinelOne.plural(agents.count, "agent")), most recently active first:\n" + agents.prefix(40).map(\.line).joined(separator: "\n")
            if agents.count > 40 { text += "\n\(agents.count - 40) more in the structured result." }
            let cut = listing.value.count > limit || (listing.more && listing.stopped == nil)
            text += cut ? "\nMore agents match than the \(agents.count) kept\(listing.total.map { " (SentinelOne says \($0) match)" } ?? ""): narrow the name, status or site." : SentinelOne.stopped(listing, "agents")
            struct Kept: Encodable { let agents: [[String: CellValue]]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(agents: agents.map(\.fields), total: listing.total, complete: listing.complete && !cut))
        }
    }

    struct AgentDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "agent"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "One agent in full by its ID: whether it is disconnected from the network, in touch with the console and infected, its OS, addresses, users, scan status and when last active, and its unresolved threats, saying what it could not read."
        static let input = JSONSchema.object(["id": .string("The agent's ID, as agents or a threat gives it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try SentinelOne.requireID(input.id, "the agent's ID")
            let agent: Agent
            switch try await SentinelOne.agent(id, service) {
            case .present(let found): agent = found
            case .absent:
                return try ServiceResult(text: "SentinelOne has no agent \(id) in this token's scope: it may have been removed, lie in a site the service user cannot see, or the ID was mistyped.", structured: ["found": false])
            case .inconclusive(let why): throw ServiceError.input("Agent \(id) could not be read: \(why).")
            }
            var lines = [agent.line]
            lines.append("Disconnect from Network: \(SentinelOne.network(agent.network)).")
            lines.append("Domain \(agent.text("domain") ?? "not given"); last logged-in user \(agent.text("lastLoggedInUserName") ?? "not given"); machine type \(agent.text("machineType") ?? "not given"); mitigation mode \(agent.text("mitigationMode") ?? "not given").")
            lines.append("Scan: \(agent.scanStatus ?? "status not given")\(agent.text("scanStartedAt").map { ", started \($0)" } ?? "")\(agent.text("scanFinishedAt").map { ", finished \($0)" } ?? "").")
            lines.append("Registered \(agent.text("registeredAt") ?? "unknown"); UUID \(agent.text("uuid") ?? "not given").")
            var gaps: [String] = []
            var threatLines: [String] = []
            do {
                let threats = try await SentinelOne.threats(query: ["agentIds": id, "incidentStatuses": "unresolved"], limit: 20, pages: 1, service)
                threatLines = threats.value.prefix(20).map(\.line)
                lines.append(threatLines.isEmpty ? "No unresolved threat on it\(threats.complete ? "" : " in what was read")." : "Its unresolved threats, newest first:\n" + threatLines.joined(separator: "\n"))
                if threats.more { lines.append("More unresolved threats than the \(threatLines.count) shown\(threats.total.map { " (SentinelOne says \($0))" } ?? ""): use threats with this agent.") }
            } catch { gaps.append("its threats (\(error.localizedDescription))") }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")).") }
            lines.append("Read at \(SentinelOne.iso(Date())).")
            struct Kept: Encodable { let found: Bool; let agent: [String: CellValue]; let threats: [String]; let couldNotRead: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(found: true, agent: agent.fields, threats: threatLines, couldNotRead: gaps))
        }
    }
}

// MARK: - Threats

extension SentinelOne {
    /// A threat as SentinelOne gives it; only its ID must be there, and anything else it leaves out is unknown.
    struct Threat: Decodable, Sendable {
        /// One mitigation action taken on it and where it stands.
        struct Mitigation: Decodable, Sendable {
            let action: String?, status: String?, started: String?, ended: String?, updated: String?
            enum Keys: String, CodingKey { case action, status, mitigationStartedAt, mitigationEndedAt, lastUpdate }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                func text(_ key: Keys) -> String? { ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
                action = text(.action); status = text(.status); started = text(.mitigationStartedAt); ended = text(.mitigationEndedAt); updated = text(.lastUpdate)
            }
            /// The action, as Pion names it: kill, quarantine, un-quarantine, remediate or rollback-remediation.
            var kind: String? { action.map(SentinelOne.mitigationKind) }
            var outcome: Outcome { SentinelOne.outcome(status) }
            var time: String? { ended ?? updated ?? started }
            var line: String { "\(action ?? "an action not named") \(status ?? "status not given")\(time.map { " at \($0)" } ?? "")" }
            /// What tells one record from another, to see what changed.
            var signature: String { [action, status, started, ended, updated].map { $0 ?? "-" }.joined(separator: "|") }
        }
        struct Indicator: Decodable, Sendable {
            let category: String?, description: String?, techniques: [String]
            enum Keys: String, CodingKey { case category, description, tactics }
            struct Tactic: Decodable { let name: String?; let techniques: [Technique]? }
            struct Technique: Decodable { let name: String? }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                category = (try? container.decodeIfPresent(String.self, forKey: .category)) ?? nil
                description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
                let tactics = ((try? container.decodeIfPresent([Tactic].self, forKey: .tactics)) ?? nil) ?? []
                techniques = tactics.flatMap { tactic -> [String] in
                    let names = (tactic.techniques ?? []).compactMap(\.name)
                    return names.isEmpty ? [tactic.name].compactMap { $0 } : names.map { "\(tactic.name ?? "?"): \($0)" }
                }
            }
        }

        let id: String
        let info: [String: CellValue]?
        let agent: [String: CellValue]?
        let detection: [String: CellValue]?
        /// Every mitigation action and its status, or nil when SentinelOne gave none in a shape Pion reads.
        let mitigations: [Mitigation]?
        let indicators: [Indicator]?

        enum Keys: String, CodingKey { case id, threatInfo, agentRealtimeInfo, agentDetectionInfo, mitigationStatus, indicators }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let raw = ((try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil)
            guard let raw, let id = SentinelOne.id(raw) else { throw ServiceError.unreadable }
            self.id = id
            info = (try? container.decodeIfPresent([String: CellValue].self, forKey: .threatInfo)) ?? nil
            agent = (try? container.decodeIfPresent([String: CellValue].self, forKey: .agentRealtimeInfo)) ?? nil
            detection = (try? container.decodeIfPresent([String: CellValue].self, forKey: .agentDetectionInfo)) ?? nil
            mitigations = (try? container.decodeIfPresent([Mitigation].self, forKey: .mitigationStatus)) ?? nil
            indicators = (try? container.decodeIfPresent([Indicator].self, forKey: .indicators)) ?? nil
        }

        func info(_ key: String) -> String? { SentinelOne.text(info, key) }
        var title: String { info("threatName") ?? id }
        var created: String? { info("createdAt") }
        var incidentStatus: String? { info("incidentStatus")?.lowercased() }
        var verdict: String? { info("analystVerdict")?.lowercased() }
        var confidence: String? { info("confidenceLevel")?.lowercased() }
        var agentID: String? { SentinelOne.text(agent, "agentId").flatMap(SentinelOne.id) }
        var computer: String? { SentinelOne.text(agent, "agentComputerName") }
        var osType: String? { SentinelOne.text(agent, "agentOsType")?.lowercased() }

        var line: String {
            var line = "\(created ?? "?") \(title)"
            if let computer { line += " on \(computer)" }
            if let agentID { line += " [agent \(agentID)]" }
            let details = [info("classification"), confidence.map { "confidence \($0)" }, info("mitigationStatus").map { "mitigation \($0)" },
                           "incident \(incidentStatus ?? "status unknown")", verdict.map { "verdict \($0)" }].compactMap { $0 }
            line += " (\(details.joined(separator: ", ")))"
            if let path = info("filePath") { line += " — \(path)" }
            return line + " [\(id)]"
        }
    }

    enum Outcome: String, Sendable { case done, pending, failed, unknown }

    /// A mitigation action's name, as Pion names it, however SentinelOne writes it.
    static func mitigationKind(_ action: String) -> String {
        let plain = action.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        switch plain {
        case "rollback", "rollback-remediation", "roll-back": return "rollback-remediation"
        case "unquarantine", "un-quarantine", "release-from-quarantine": return "un-quarantine"
        default: return plain
        }
    }

    /// Where an action stands, by the words SentinelOne uses: done only when it says it succeeded or completed.
    static func outcome(_ status: String?) -> Outcome {
        guard let status = status?.lowercased() else { return .unknown }
        if status.contains("fail") || status.contains("error") { return .failed }
        if status.contains("pend") || status.contains("progress") || status.contains("queue") || status.contains("waiting") { return .pending }
        if status == "success" || status.contains("succe") || status.contains("complete") { return .done }
        return .unknown
    }

    static let incidentStatuses = ["unresolved", "in_progress", "resolved"]
    static let confidenceLevels = ["malicious", "suspicious", "n/a"]
    static let verdicts = ["true_positive", "false_positive", "suspicious", "undefined"]

    /// Threats matching a query, newest first, read whole across pages, at most `limit`.
    static func threats(query: [String: String?], limit: Int, pages: Int = maximumPages, _ service: ServiceClient) async throws -> Listing<Threat> {
        var asked = query
        asked["sortBy"] = "createdAt"
        asked["sortOrder"] = "desc"
        return try await read(threatsNeed) {
            try await list(service, ["threats"], query: asked, as: Threat.self, size: min(limit, 1_000), pages: pages, limit: limit)
        }
    }

    /// One threat by its exact ID.
    static func threat(_ id: String, _ service: ServiceClient) async throws -> Lookup<Threat> {
        try await read(threatsNeed) {
            try await lookup(service, ["threats"], query: ["ids": id], id: id, idOf: { (threat: Threat) in threat.id }, what: "threat")
        }
    }

    struct Threats: ServiceOperation {
        struct Input: Decodable, Sendable { let computerName: String?, agentId: String?, incidentStatus: String?, confidence: String?, since: String?, until: String?, limit: Int? }
        static let name = "threats"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Threats agents detected, newest first, by computer, agent, incident status, confidence and time, with each one's classification, confidence, mitigation status, incident status, analyst verdict and file, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "computerName": .string("All or part of the computer's name."),
            "agentId": .string("The agent's ID."),
            "incidentStatus": .string("The incident status.", oneOf: SentinelOne.incidentStatuses),
            "confidence": .string("The confidence level.", oneOf: SentinelOne.confidenceLevels),
            "since": .string("The earliest time it was detected, in ISO 8601. The last 7 days when left out, at most a year."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many threats, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try SentinelOne.window(input.since, input.until, days: 7)
            var query: [String: String?] = ["createdAt__gte": SentinelOne.iso(since), "createdAt__lte": SentinelOne.iso(until)]
            if let name = input.computerName { query["computerName__contains"] = try SentinelOne.computerName(name) }
            if let agent = input.agentId { query["agentIds"] = try SentinelOne.requireID(agent, "the agent's ID") }
            if let status = input.incidentStatus { query["incidentStatuses"] = try ServiceInput.oneOf(status, SentinelOne.incidentStatuses, "incidentStatus") }
            if let confidence = input.confidence { query["confidenceLevels"] = try ServiceInput.oneOf(confidence, SentinelOne.confidenceLevels, "confidence") }
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 threats.") }
            let listing = try await SentinelOne.threats(query: query, limit: limit, service)
            let threats = Array(listing.value.prefix(limit))
            let window = "detected from \(SentinelOne.iso(since)) to \(SentinelOne.iso(until))"
            var text = threats.isEmpty ? "No threats \(window) match\(listing.complete ? "" : " in what was read")."
                : "\(SentinelOne.plural(threats.count, "threat")) \(window), newest first:\n" + threats.prefix(30).map(\.line).joined(separator: "\n")
            if threats.count > 30 { text += "\n\(threats.count - 30) more in the structured result." }
            let cut = listing.value.count > limit || (listing.more && listing.stopped == nil)
            text += cut ? "\nMore threats match than the \(threats.count) kept, the newest\(listing.total.map { " (SentinelOne says \($0) match)" } ?? ""): narrow the window, computer or status." : SentinelOne.stopped(listing, "threats")
            struct Kept: Encodable { let id: String; let line: String; let agent: String?; let incidentStatus: String?; let verdict: String?; let confidence: String?; let sha1: String?; let sha256: String? }
            struct All: Encodable { let threats: [Kept]; let since: String; let until: String; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: All(threats: threats.map { Kept(id: $0.id, line: $0.line, agent: $0.agentID, incidentStatus: $0.incidentStatus, verdict: $0.verdict,
                                                                                           confidence: $0.confidence, sha1: $0.info("sha1"), sha256: $0.info("sha256")) },
                                                                 since: SentinelOne.iso(since), until: SentinelOne.iso(until), total: listing.total, complete: listing.complete && !cut))
        }
    }

    /// An entry of the activity log, or of a threat's timeline, which SentinelOne gives in the same shape.
    struct Activity: Decodable, Sendable {
        let id: String
        let type: Int?
        let fields: [String: CellValue]
        let data: [String: CellValue]?

        enum Keys: String, CodingKey { case data }

        init(from decoder: Decoder) throws {
            let fields = try [String: CellValue](from: decoder)
            guard let raw = SentinelOne.text(fields, "id"), let id = SentinelOne.id(raw) else { throw ServiceError.unreadable }
            self.id = id
            self.fields = fields
            type = SentinelOne.number(fields, "activityType") ?? SentinelOne.text(fields, "activityType").flatMap { Int($0) }
            data = (try? decoder.container(keyedBy: Keys.self).decodeIfPresent([String: CellValue].self, forKey: .data)) ?? nil
        }

        func text(_ key: String) -> String? { SentinelOne.text(fields, key) }
        var created: String? { text("createdAt") }
        var user: String? { text("userId").flatMap(SentinelOne.id) }
        /// Who did it, as the entry names them: the user's name in its data, or their ID.
        var who: String? { SentinelOne.text(data, "username") ?? SentinelOne.text(data, "userName") ?? user.map { "user \($0)" } }

        var line: String {
            var line = "\(created ?? "?") type \(type.map(String.init) ?? "?"): \(String((text("primaryDescription") ?? "no description").prefix(300)))"
            if let secondary = text("secondaryDescription") { line += " — \(String(secondary.prefix(200)))" }
            if let who { line += " (by \(who))" }
            var about: [String] = []
            if let agent = text("agentId") { about.append("agent \(agent)") }
            if let threat = text("threatId") { about.append("threat \(threat)") }
            if !about.isEmpty { line += " [\(about.joined(separator: ", "))]" }
            return line + " [\(id)]"
        }
    }

    struct Note: Decodable, Sendable {
        let text: String?, createdAt: String?, creator: String?
        enum Keys: String, CodingKey { case text, createdAt, creator }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
            createdAt = (try? container.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
            creator = (try? container.decodeIfPresent(String.self, forKey: .creator)) ?? nil
        }
    }

    struct ThreatDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "threat"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "One threat in full by its ID: the endpoint and agent, file, hashes, process and user, storyline, classification and confidence, MITRE indicators, every mitigation action and where it stands, incident status and verdict, its notes, and its newest timeline entries, saying what it could not read."
        static let input = JSONSchema.object(["id": .string("The threat's ID, as threats lists it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try SentinelOne.requireID(input.id, "the threat's ID")
            let threat: Threat
            switch try await SentinelOne.threat(id, service) {
            case .present(let found): threat = found
            case .absent:
                return try ServiceResult(text: "SentinelOne has no threat \(id) in this token's scope: it may have been deleted, lie in a site the service user cannot see, or the ID was mistyped.", structured: ["found": false])
            case .inconclusive(let why): throw ServiceError.input("Threat \(id) could not be read: \(why).")
            }
            var lines = [threat.line]
            lines.append("Endpoint \(threat.computer ?? "not given") [agent \(threat.agentID ?? "not given")], \(threat.osType ?? "OS not given"), network \(SentinelOne.network(SentinelOne.text(threat.agent, "agentNetworkStatus")?.lowercased())); last logged-in user \(SentinelOne.text(threat.detection, "agentLastLoggedInUserName") ?? "not given").")
            lines.append("File \(threat.info("filePath") ?? "not given"); SHA1 \(threat.info("sha1") ?? "not given"); SHA256 \(threat.info("sha256") ?? "not given"); MD5 \(threat.info("md5") ?? "not given").")
            lines.append("Process \(threat.info("originatorProcess") ?? "not given"), as \(threat.info("processUser") ?? "a user not given"); storyline \(threat.info("storyline") ?? "not given"); detected by \(threat.info("initiatedBy") ?? threat.info("detectionType") ?? "not given")\(SentinelOne.list(threat.info, "engines").isEmpty ? "" : " (\(SentinelOne.list(threat.info, "engines").joined(separator: ", ")))").")
            lines.append("Incident status \(threat.incidentStatus ?? "not given"); analyst verdict \(threat.verdict ?? "not given"); mitigation status \(threat.info("mitigationStatus") ?? "not given")\(threat.info("mitigationStatusDescription").map { " (\($0))" } ?? "").")
            if let mitigations = threat.mitigations {
                lines.append(mitigations.isEmpty ? "Mitigation actions: none listed." : "Mitigation actions: " + mitigations.map(\.line).joined(separator: "; ") + ".")
            } else { lines.append("Mitigation actions: not given, so unknown.") }
            let techniques = (threat.indicators ?? []).flatMap(\.techniques)
            if let indicators = threat.indicators {
                lines.append(indicators.isEmpty ? "Indicators: none listed." : "Indicators: " + indicators.prefix(20).map { "\($0.category ?? "?"): \(String(($0.description ?? "").prefix(200)))" }.joined(separator: "; ") + ".")
                if !techniques.isEmpty { lines.append("MITRE: " + Array(NSOrderedSet(array: techniques)).compactMap { $0 as? String }.prefix(20).joined(separator: "; ") + ".") }
            } else { lines.append("Indicators: not given.") }
            var gaps: [String] = []
            var notes: [String] = []
            do {
                let listing = try await SentinelOne.read(SentinelOne.threatsNeed) {
                    try await SentinelOne.list(service, ["threats", id, "notes"], query: [:], as: Note.self, size: 100, pages: 2)
                }
                notes = listing.value.map { "\($0.createdAt ?? "?") \($0.creator ?? "someone not named"): \(String(($0.text ?? "").prefix(500)))" }
                lines.append(notes.isEmpty ? "Notes: none\(listing.complete ? "" : " in what was read")." : "Notes:\n" + notes.joined(separator: "\n"))
                if !listing.complete { lines.append(String(SentinelOne.stopped(listing, "notes").dropFirst())) }
            } catch { gaps.append("its notes (\(error.localizedDescription))") }
            var timeline: [String] = []
            do {
                let listing = try await SentinelOne.read(SentinelOne.threatsNeed) {
                    try await SentinelOne.list(service, ["threats", id, "timeline"], query: ["sortBy": "createdAt", "sortOrder": "desc"], as: Activity.self, size: 50, pages: 1)
                }
                timeline = listing.value.map(\.line)
                lines.append(timeline.isEmpty ? "Timeline: no entries." : "Timeline, newest first:\n" + timeline.joined(separator: "\n"))
                if listing.more { lines.append("More timeline entries than the \(timeline.count) shown\(listing.total.map { " (SentinelOne says \($0))" } ?? ""): activities with this threat reads them.") }
            } catch { gaps.append("its timeline (\(error.localizedDescription))") }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")).") }
            struct Kept: Encodable {
                let found: Bool; let id: String; let line: String; let agent: String?; let incidentStatus: String?; let verdict: String?
                let mitigations: [String]?; let techniques: [String]; let notes: [String]; let timeline: [String]; let couldNotRead: [String]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(found: true, id: threat.id, line: threat.line, agent: threat.agentID, incidentStatus: threat.incidentStatus, verdict: threat.verdict,
                                                      mitigations: threat.mitigations?.map(\.line), techniques: techniques, notes: notes, timeline: timeline, couldNotRead: gaps))
        }
    }
}

// MARK: - Activity log

extension SentinelOne {
    struct ActivityType: Decodable, Sendable {
        let id: Int
        let action: String?, descriptionTemplate: String?
        enum Keys: String, CodingKey { case id, action, descriptionTemplate }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard let id = ((try? container.decodeIfPresent(Int.self, forKey: .id)) ?? nil) ?? ((try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil).flatMap({ Int($0) }) else {
                throw ServiceError.unreadable
            }
            self.id = id
            action = (try? container.decodeIfPresent(String.self, forKey: .action)) ?? nil
            descriptionTemplate = (try? container.decodeIfPresent(String.self, forKey: .descriptionTemplate)) ?? nil
        }
        var words: String { "\(action ?? "") \(descriptionTemplate ?? "")".lowercased() }
    }

    static func activityTypes(_ service: ServiceClient) async throws -> [ActivityType] {
        try await read(activitiesNeed) { try await get(service, ["activities", "types"], as: ActivityType.self).items() }
    }

    struct Activities: ServiceOperation {
        struct Input: Decodable, Sendable { let agentId: String?, threatId: String?, userId: String?, types: [Int]?, since: String?, until: String?, limit: Int? }
        static let name = "activities"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The activity log, newest first: who did what and when, by agent, threat, user, activity type and time, each entry with its type, description and who did it, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "agentId": .string("Only entries about this agent."),
            "threatId": .string("Only entries about this threat."),
            "userId": .string("Only entries by this user, by ID."),
            "types": .array(.integer("An activity type, as activity-types lists it."), "Only these activity types, at most 50."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most a year."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many entries, at most. 100 when left out.", minimum: 1, maximum: 1_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try SentinelOne.window(input.since, input.until, days: 1)
            var query: [String: String?] = ["createdAt__gte": SentinelOne.iso(since), "createdAt__lte": SentinelOne.iso(until), "sortBy": "createdAt", "sortOrder": "desc"]
            if let agent = input.agentId { query["agentIds"] = try SentinelOne.requireID(agent, "the agent's ID") }
            if let threat = input.threatId { query["threatIds"] = try SentinelOne.requireID(threat, "the threat's ID") }
            if let user = input.userId { query["userIds"] = try SentinelOne.requireID(user, "the user's ID") }
            if let types = input.types {
                guard (1...50).contains(types.count), types.allSatisfy({ (0...1_000_000).contains($0) }) else { throw ServiceError.input("Give between 1 and 50 activity types, as activity-types lists them.") }
                query["activityTypes"] = types.map(String.init).joined(separator: ",")
            }
            let limit = input.limit ?? 100
            guard (1...1_000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 1,000 entries.") }
            let listing = try await SentinelOne.read(SentinelOne.activitiesNeed) {
                try await SentinelOne.list(service, ["activities"], query: query, as: Activity.self, size: min(limit, 1_000), limit: limit)
            }
            let entries = Array(listing.value.prefix(limit))
            let window = "from \(SentinelOne.iso(since)) to \(SentinelOne.iso(until))"
            var text = entries.isEmpty ? "No activity \(window) matches\(listing.complete ? "" : " in what was read")."
                : "\(SentinelOne.plural(entries.count, "entry")) \(window), newest first:\n" + entries.prefix(50).map(\.line).joined(separator: "\n")
            if entries.count > 50 { text += "\n\(entries.count - 50) more in the structured result." }
            let cut = listing.value.count > limit || (listing.more && listing.stopped == nil)
            text += cut ? "\nMore entries match than the \(entries.count) kept, the newest\(listing.total.map { " (SentinelOne says \($0) match)" } ?? ""): narrow the window or types." : SentinelOne.stopped(listing, "the activity log")
            struct Kept: Encodable { let entries: [String]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(entries: entries.map(\.line), total: listing.total, complete: listing.complete && !cut))
        }
    }

    struct ActivityTypes: ServiceOperation {
        struct Input: Decodable, Sendable { let contains: String? }
        static let name = "activity-types"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The activity log's types, by number, with what each records, optionally only those whose name contains some words, for activities' types."
        static let input = JSONSchema.object(["contains": .string("Only types whose name or description contains this, such as network or quarantine.")])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let words = try input.contains.map { try ServiceInput.quoted($0, "the words").lowercased() }
            let types = try await SentinelOne.activityTypes(service).filter { words == nil || $0.words.contains(words!) }.sorted { $0.id < $1.id }
            let lines = types.map { "\($0.id): \($0.action ?? "not named")\($0.descriptionTemplate.map { " — \(String($0.prefix(200)))" } ?? "")" }
            return try ServiceResult(text: lines.isEmpty ? "No activity type matches." : lines.joined(separator: "\n"), structured: ["types": lines])
        }
    }
}

// MARK: - Sites, groups and exclusions

extension SentinelOne {
    struct Sites: ServiceOperation {
        struct Input: Decodable, Sendable { let limit: Int? }
        static let name = "sites"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The sites this token sees, with each one's ID, account, state, type and licences, saying when more matched than it kept."
        static let input = JSONSchema.object(["limit": .integer("How many sites, at most. 200 when left out.", minimum: 1, maximum: 1_000)])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 200
            guard (1...1_000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 1,000 sites.") }
            let listing = try await SentinelOne.read(SentinelOne.sitesNeed) { try await SentinelOne.sites(service, query: [:], limit: limit) }
            let sites = Array(listing.value.prefix(limit))
            let lines = sites.map { site in
                "\(SentinelOne.text(site, "name") ?? "unnamed") [\(SentinelOne.text(site, "id") ?? "?")]: account \(SentinelOne.text(site, "accountName") ?? "?"), \(SentinelOne.text(site, "state") ?? "state unknown"), \(SentinelOne.text(site, "siteType") ?? "type unknown"), \(SentinelOne.text(site, "activeLicenses") ?? "?") of \(SentinelOne.text(site, "totalLicenses") ?? "?") licences used"
            }
            var text = sites.isEmpty ? "This token sees no sites\(listing.complete ? "" : " in what was read")." : "\(SentinelOne.plural(sites.count, "site")):\n" + lines.joined(separator: "\n")
            text += listing.more && listing.stopped == nil ? "\nThere are more sites than the \(sites.count) kept\(listing.total.map { " (SentinelOne says \($0))" } ?? "")." : SentinelOne.stopped(listing, "sites")
            struct Kept: Encodable { let sites: [[String: CellValue]]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(sites: sites, total: listing.total, complete: listing.complete))
        }
    }

    /// Sites, which SentinelOne gives inside its data, beside the licences of all of them.
    static func sites(_ service: ServiceClient, query: [String: String?], limit: Int, pages: Int = maximumPages) async throws -> Listing<[String: CellValue]> {
        struct Inner: Decodable { let sites: [[String: CellValue]]? }
        return try await list(service, ["sites"], query: query, as: [String: CellValue].self, size: min(limit, 1_000), pages: pages, limit: limit) { data in
            let envelope: Single<Inner> = try decode(data)
            if let problems = envelope.problems { throw ServiceError.refused(problems) }
            guard let sites = envelope.data?.sites else { throw ServiceError.unreadable }
            guard sites.allSatisfy({ SentinelOne.text($0, "id").flatMap(SentinelOne.id) != nil }) else { throw ServiceError.unreadable }
            let paged: Errors? = try? decode(data)
            return (sites, paged?.pagination)
        }
    }

    struct Groups: ServiceOperation {
        struct Input: Decodable, Sendable { let siteId: String?, limit: Int? }
        static let name = "groups"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Groups of agents, with each one's ID, site, type, how many agents it holds and whether it is the site's default, optionally of one site, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "siteId": .string("Only this site's groups."),
            "limit": .integer("How many groups, at most. 200 when left out.", minimum: 1, maximum: 1_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = [:]
            if let site = input.siteId { query["siteIds"] = try SentinelOne.requireID(site, "the site's ID") }
            let limit = input.limit ?? 200
            guard (1...1_000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 1,000 groups.") }
            let listing = try await SentinelOne.read(SentinelOne.groupsNeed) {
                try await SentinelOne.list(service, ["groups"], query: query, as: [String: CellValue].self, size: min(limit, 300), limit: limit)
            }
            let groups = Array(listing.value.prefix(limit))
            let lines = groups.map { group in
                "\(SentinelOne.text(group, "name") ?? "unnamed") [\(SentinelOne.text(group, "id") ?? "?")]: site \(SentinelOne.text(group, "siteId") ?? "?"), \(SentinelOne.text(group, "type") ?? "type unknown"), \(SentinelOne.text(group, "totalAgents") ?? "?") agents\(SentinelOne.flag(group, "isDefault") == true ? ", the site's default" : "")"
            }
            var text = groups.isEmpty ? "No groups\(listing.complete ? "" : " in what was read")." : "\(SentinelOne.plural(groups.count, "group")):\n" + lines.joined(separator: "\n")
            text += listing.more && listing.stopped == nil ? "\nThere are more groups than the \(groups.count) kept\(listing.total.map { " (SentinelOne says \($0))" } ?? "")." : SentinelOne.stopped(listing, "groups")
            struct Kept: Encodable { let groups: [[String: CellValue]]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(groups: groups, total: listing.total, complete: listing.complete))
        }
    }

    static let exclusionTypes = ["path", "white_hash", "certificate", "browser", "file_type"]

    struct Exclusions: ServiceOperation {
        struct Input: Decodable, Sendable { let type: String?, osType: String?, limit: Int? }
        static let name = "exclusions"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Exclusions, newest first: what each lets the agents ignore (a path, hash, certificate, browser or file type), its mode, OS and scope, and who added it and when. An exclusion an attacker added hides what they do. Says when it read only part."
        static let input = JSONSchema.object([
            "type": .string("Only this kind.", oneOf: SentinelOne.exclusionTypes),
            "osType": .string("Only this OS.", oneOf: SentinelOne.osTypes),
            "limit": .integer("How many to show, at most. 200 when left out.", minimum: 1, maximum: 1_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = [:]
            if let type = input.type { query["type"] = try ServiceInput.oneOf(type, SentinelOne.exclusionTypes, "type") }
            if let os = input.osType { query["osTypes"] = try ServiceInput.oneOf(os, SentinelOne.osTypes, "osType") }
            let limit = input.limit ?? 200
            guard (1...1_000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 1,000 exclusions.") }
            // Read whole, then newest first, so the newest are those shown whatever order SentinelOne lists them in.
            let listing = try await SentinelOne.read(SentinelOne.exclusionsNeed) {
                try await SentinelOne.list(service, ["exclusions"], query: query, as: [String: CellValue].self, size: 1_000)
            }
            let sorted = listing.value.sorted { (ServiceAlert.time(SentinelOne.text($0, "createdAt")) ?? .distantPast) > (ServiceAlert.time(SentinelOne.text($1, "createdAt")) ?? .distantPast) }
            let shown = Array(sorted.prefix(limit))
            let lines = shown.map { item in
                "\(SentinelOne.text(item, "createdAt") ?? "?") \(SentinelOne.text(item, "type") ?? "type unknown") \(String((SentinelOne.text(item, "value") ?? "?").prefix(300))): \(SentinelOne.text(item, "osType") ?? "OS unknown"), mode \(SentinelOne.text(item, "mode") ?? SentinelOne.text(item, "pathExclusionType") ?? "not given"), scope \(SentinelOne.text(item, "scopeName") ?? SentinelOne.text(item, "scopePath") ?? "not given"), added by \(SentinelOne.text(item, "userName") ?? SentinelOne.text(item, "userId") ?? "someone not named")\(SentinelOne.text(item, "description").map { " — \(String($0.prefix(200)))" } ?? "") [\(SentinelOne.text(item, "id") ?? "?")]"
            }
            var text = shown.isEmpty ? "No exclusions\(listing.complete ? "" : " in what was read")." : "\(SentinelOne.plural(shown.count, "exclusion")), newest first\(listing.complete ? "" : " of what was read"):\n" + lines.prefix(60).joined(separator: "\n")
            if shown.count > 60 { text += "\n\(shown.count - 60) more in the structured result." }
            if sorted.count > limit { text += "\n\(sorted.count - limit) older exclusions were read but not kept." }
            text += SentinelOne.stopped(listing, "exclusions")
            if !listing.complete { text += "\nAs not every exclusion was read, the newest may be among those not read." }
            struct Kept: Encodable { let exclusions: [[String: CellValue]]; let read: Int; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(exclusions: shown, read: sorted.count, total: listing.total, complete: listing.complete))
        }
    }
}

// MARK: - Access

extension SentinelOne {
    /// The token's own service user, its scope and roles, as SentinelOne gives them.
    struct Me: Sendable {
        let id: String?, email: String?, name: String?, scope: String?, lowestRole: String?, tokenExpires: String?
        /// Each role it holds, where: the role's name and the account or site it holds it in.
        let roles: [(role: String, at: String?)]

        var roleNames: [String] { Array(Set(roles.map { $0.role.lowercased() } + [lowestRole?.lowercased()].compactMap { $0 })).sorted() }

        var lines: [String] {
            var lines = ["· The token is service user \(name ?? "not named") (\(email ?? "no email given"), ID \(id ?? "not given")), scope \(scope ?? "not given")."]
            lines.append(roles.isEmpty ? "· Its roles were not given\(lowestRole.map { "; its lowest role is \($0)" } ?? "")." : "· Its roles: \(roles.map { "\($0.role)\($0.at.map { " in \($0)" } ?? "")" }.joined(separator: "; ")).")
            lines.append("· Its token expires \(tokenExpires ?? "at a time SentinelOne did not give").")
            return lines
        }
    }

    static func me(_ service: ServiceClient) async throws -> Me {
        struct Role: Decodable { let roleName: String?; let name: String?; let accountName: String? }
        struct SiteRole: Decodable { let name: String?; let roles: [String]? }
        struct Token: Decodable { let expiresAt: String? }
        struct User: Decodable {
            let fields: [String: CellValue]
            let scopeRoles: [Role]?, siteRoles: [SiteRole]?, apiToken: Token?
            enum Keys: String, CodingKey { case scopeRoles, siteRoles, apiToken }
            init(from decoder: Decoder) throws {
                fields = try [String: CellValue](from: decoder)
                let container = try decoder.container(keyedBy: Keys.self)
                scopeRoles = (try? container.decodeIfPresent([Role].self, forKey: .scopeRoles)) ?? nil
                siteRoles = (try? container.decodeIfPresent([SiteRole].self, forKey: .siteRoles)) ?? nil
                apiToken = (try? container.decodeIfPresent(Token.self, forKey: .apiToken)) ?? nil
            }
        }
        let answer: Single<User> = try decode(try await exchange(service, ["user"]).data)
        if let problems = answer.problems { throw ServiceError.refused(problems) }
        guard let user = answer.data else { throw ServiceError.unreadable }
        let roles = (user.scopeRoles ?? []).compactMap { role in role.roleName.map { ($0, role.name ?? role.accountName) } }
            + (user.siteRoles ?? []).flatMap { site in (site.roles ?? []).map { ($0, site.name) } }
        return Me(id: text(user.fields, "id"), email: text(user.fields, "email"), name: text(user.fields, "fullName"), scope: text(user.fields, "scope"),
                  lowestRole: text(user.fields, "lowestRole"), tokenExpires: user.apiToken?.expiresAt, roles: roles.map { (role: $0.0, at: $0.1) })
    }

    /// The token's user, said as lines, or why it could not be read.
    static func whoAmI(_ service: ServiceClient) async -> (me: Me?, lines: [String]) {
        do {
            let me = try await me(service)
            return (me, me.lines)
        } catch {
            return (nil, ["✗ The token's own user could not be read: " + (fix(for: error, userNeed) ?? error.localizedDescription)])
        }
    }

    /// Tries a read once, and says whether it works.
    static func probe(_ need: Need, _ path: [String], _ query: [String: String?], required: Bool, _ service: ServiceClient,
                      extract: ((Data) throws -> (items: [[String: CellValue]], pagination: Pagination?))? = nil) async -> (works: Bool, line: String) {
        do {
            _ = try await list(service, path, query: query, as: [String: CellValue].self, size: 1, pages: 1, extract: extract)
            return (true, "✓ \(need.title) (\(need.permission))")
        } catch {
            return (false, "\(required ? "✗" : "⚠") \(need.title): " + (fix(for: error, need) ?? error.localizedDescription))
        }
    }

    /// Tries each thing Detection reads once and says what works and what to change, with the token's user, role and
    /// scope. It sends only reads.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Reads the token's own service user, its role, scope and when the token expires, warning of any role but Viewer; tries each thing this tool reads once and says what works and what to change; and names the console it reaches. It sends only reads."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let host = try SentinelOne.console(service)
            var lines = ["· Console \(host), reached at https://\(host)/web/api/v2.1 and nowhere else."]
            let (me, said) = await SentinelOne.whoAmI(service)
            lines += said
            if let me {
                let roles = me.roleNames
                if roles.isEmpty { lines.append("? Whether it holds only Viewer could not be told: SentinelOne gave no role. Check it in Settings › Users › Service Users.") }
                else if roles.allSatisfy({ $0 == "viewer" }) { lines.append("✓ It holds only the Viewer role, which reads and changes nothing.") }
                else { lines.append("⚠ It holds \(roles.filter { $0 != "viewer" }.joined(separator: ", ")), not only Viewer: Detection's service user should hold only Viewer, so it can change nothing. Change its role in Settings › Users › Service Users.") }
            }
            let reads: [(Need, [String], [String: String?], Bool)] = [
                (SentinelOne.agentsNeed, ["agents"], [:], true),
                (SentinelOne.threatsNeed, ["threats"], [:], true),
                (SentinelOne.activitiesNeed, ["activities"], [:], false),
                (SentinelOne.groupsNeed, ["groups"], [:], false),
                (SentinelOne.exclusionsNeed, ["exclusions"], [:], false),
            ]
            var working: [String] = []
            for (need, path, query, required) in reads {
                let (works, line) = await SentinelOne.probe(need, path, query, required: required, service)
                lines.append(line)
                if works { working.append(need.title) }
            }
            do {
                _ = try await SentinelOne.sites(service, query: [:], limit: 1, pages: 1)
                lines.append("✓ \(SentinelOne.sitesNeed.title) (\(SentinelOne.sitesNeed.permission))")
            } catch { lines.append("⚠ \(SentinelOne.sitesNeed.title): " + (SentinelOne.fix(for: error, SentinelOne.sitesNeed) ?? error.localizedDescription)) }
            if ![SentinelOne.agentsNeed, SentinelOne.threatsNeed, SentinelOne.activitiesNeed].allSatisfy({ working.contains($0.title) }) {
                lines.append("· The alert watch reads threats, agents disconnected from the network and the activity log; what it cannot read it says once, and security-events says why.")
            }
            lines.append("· Pion Detection's service user should hold only the Viewer role, at the account or sites to investigate: check it in Settings › Users › Service Users.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
