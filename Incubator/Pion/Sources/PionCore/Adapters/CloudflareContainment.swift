import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Cloudflare Containment: responding in one account, with a token of its own holding only the edit permissions its
/// actions take, kept apart from Audit's so the audit token stays read-only. Every action that blocks or unblocks
/// traffic, revokes sessions or devices, or gives them back waits for the champion's approval, and each says what
/// recovering from it involves.
///
/// Pion reads what it acts on whole first, by its exact ID or value, and refuses what is already as asked. It removes
/// only what it made: an IP Access rule, or an item in its own Gateway list, is Pion's only by Pion's own record of
/// what it made, bound to the connection, the account and the zone or list, and kept with what Cloudflare said it made,
/// which must still hold before Pion removes it. A change is confirmed only when Cloudflare's answer names the same
/// object with the approved values and a read afterwards shows it; anything else is reported unverified, with the
/// request's details and the IDs kept.
///
/// Tightening an Access policy is left out: Cloudflare evaluates an application's policies in an order each must hold
/// uniquely, so putting a block first means renumbering the application's other policies, a change to what Pion does
/// not own and cannot restore exactly. revoke-access-sessions, and suspending the person at their identity provider,
/// reach the same end reversibly.
extension Cloudflare {
    public static let containment = ToolDefinition(
        id: "aa7d6d7e-fd6e-4b8a-a5a4-118e441e43b9", name: "Cloudflare Containment",
        summary: "Block an IP address, network or country at the edge and remove what it blocked, revoke a person's Access sessions, block a domain or IP address in Gateway and remove it, and revoke a WARP device, in Cloudflare.",
        defaultInstructions: """
        Use Cloudflare Containment to respond in a Cloudflare account. Find the target with Cloudflare Audit first, then \
        read it here and record it as evidence before acting. block-ip, block-asn and block-country add an IP Access \
        rule that blocks an address or range, a network or a country, for the whole account or one zone, and give its \
        ID; Pion keeps a record of each rule it makes, and unblock removes one by that ID only if the record says Pion \
        made it and Cloudflare still holds it as made. revoke-access-sessions ends every Access session a person has, \
        so they must sign in again. gateway-block adds a domain or IP address to Pion's own Gateway list, which a Gateway \
        rule Pion makes blocks for every device using Gateway, and gateway-unblock removes one Pion added. revoke-device \
        cuts a WARP device registration off from Zero Trust; giving one back is done in the Zero Trust dashboard, as \
        Pion cannot verify who revoked a registration. All of these are held \
        for the champion's approval: give the exact target, and in --approval-reason why, the expected effect and how \
        to undo it, with the Investigation as --approval-conversation. access-user, device and action-status read \
        without approval. Pion refuses a malformed value, a target it cannot read whole, one already as asked, a value \
        any IP Access rule already holds, and a rule or item it has no record of making. A result Pion could not \
        verify is never reported done and keeps the request's details. Run check-access when something is refused, and \
        tell the champion exactly what it says to change.
        """,
        iconName: "cloudflare",
        configuration: .connection(.init(endpointTemplate: "https://api.cloudflare.com/client/v4", fields: [accountField],
                                         tokenHeader: "Authorization", tokenScheme: "Bearer", adapter: "cloudflare-containment")),
        setup: containmentSetup)

    /// Containment's token permissions, as the dashboard's Create Custom Token lists them: only what its actions take.
    static let containmentPermissions = ["Account › Account Firewall Access Rules › Edit", "Account › Zero Trust › Edit"]
    /// Needed only to block or unblock in one zone rather than the whole account.
    static let containmentZonePermissions = ["Zone › Firewall Services › Edit", "Zone › Zone › Read"]

    static let containmentSetup = [
        "In the Cloudflare dashboard, open **Manage Account › Account API Tokens** and choose **Create Token › Create Custom Token**. Name it Pion Containment, kept for this tool alone, apart from Pion Audit's.",
        "Give it only \(containmentPermissions.map { "**\($0)**" }.joined(separator: " and ")). Cloudflare accepts nothing narrower for Gateway lists and WARP devices, and Zero Trust › Edit can change all of Zero Trust, so leave it out if agents should not block in Gateway, revoke devices or sessions. To block in one zone rather than the whole account, add \(containmentZonePermissions.map { "**\($0)**" }.joined(separator: " and ")) for that zone.",
        "Under **Account Resources** include only this account, and under **Zone Resources** only the zones it may act on. Optionally limit **Client IP Address Filtering** and set a **TTL**; then create the token and give it here. Pion sends it as `Authorization: Bearer <token>`.",
        accountStep,
    ]

    public static let containmentAdapter = OperationAdapter(operations: [
        ContainmentAccessUser(), ContainmentDevice(), ActionStatus(), BlockIP(), BlockASN(), BlockCountry(), Unblock(),
        RevokeAccessSessions(), GatewayBlock(), GatewayUnblock(), RevokeDevice(), ContainmentCheckAccess(),
    ], simultaneousRequests: 2)

    // MARK: What it needs

    static let accountRulesNeed = Need(title: "The account's IP Access rules", permission: "Account › Account Firewall Access Rules › Edit")
    static let zoneRulesNeed = Need(title: "The zone's IP Access rules", permission: "Zone › Firewall Services › Edit", zone: true)
    static let zoneLookupNeed = Need(title: "Zones", permission: "Zone › Zone › Read", zone: true)
    static let editZeroTrustNeed = Need(title: "Zero Trust", permission: "Account › Zero Trust › Edit", zeroTrust: true)

    /// How long to wait between reads of something just asked for, before saying where it stands.
    @TaskLocal static var pauses: [Double] = [1, 2, 3]

    static let notePrefix = "Pion, after the champion's approval: "

    /// A reason as Cloudflare keeps it beside what Pion made, for people reading the dashboard: one line, up to 200
    /// characters.
    static func approvalNote(_ value: String) throws -> String {
        let words = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (3...200).contains(words.count) else { throw ServiceError.input("Nothing was changed: give a reason of up to 200 characters saying why, as the approval request does.") }
        return notePrefix + words
    }

    /// What a change's request was, for a result that could not be verified.
    static func requested(_ method: String, _ path: [String], _ details: String) -> String {
        "Request: \(method) \(basePath)/\(path.joined(separator: "/")) \(details)."
    }

    /// A change, sent once, with Cloudflare's answer read whole: its result, or why it does not plainly say it
    /// succeeded.
    static func change(_ service: ServiceClient, _ path: [String], method: String, body: Data?, query: [String: String?] = [:], need: Need) async throws -> (result: Value?, problem: String?) {
        let answer = try await read(need) { try await exchange(service, path, query: query, method: method, body: body) }
        guard let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: answer.data) else { return (nil, "Cloudflare's answer could not be read") }
        if let problems = envelope.problems { return (envelope.result, "Cloudflare's answer carried errors: \(problems)") }
        guard envelope.success == true else { return (envelope.result, "Cloudflare's answer did not say it succeeded") }
        return (envelope.result, nil)
    }

    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
}

// MARK: - Pion's record of what it made

extension Cloudflare {
    /// Something Containment made: its kind, ID, where (the account, a zone or a list), and what Cloudflare said it
    /// made, field by field, which must still hold before Pion removes it.
    struct Owned: Codable, Equatable, Sendable {
        /// ip-access-rule, gateway-list, gateway-rule or gateway-item.
        let kind: String
        let id: String
        /// account:<id>, zone:<id>, or list:<id> for an item.
        let scope: String
        /// What it is about: a rule's target and value, a list's or rule's kind (domain or ip), an item's value.
        let label: String
        let created: Date
        let made: [String: String]
        /// Whether reading it back first found it otherwise than made, so someone may have changed it since; then Pion
        /// leaves it to the dashboard.
        let changedSinceCreation: Bool
    }

    struct Book: Sendable {
        var file: URL? = nil
        var records: [String: [Owned]] = [:]
    }
    static let book = Mutex(Book())

    /// Keeps Pion's record of what Cloudflare Containment made in `file`, reading what it already holds; nil keeps it in
    /// memory.
    public static func keepContainmentRecords(at file: URL?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([String: [Owned]].self, from: $0) } ?? [:]
        book.withLock { $0 = Book(file: file, records: saved) }
    }

    static func recordKey(_ service: ServiceClient) throws -> String {
        guard let connection = service.account else {
            throw ServiceError.input("Nothing was changed: Pion cannot tell which connection this is, so it can keep no record of what it makes, and makes nothing.")
        }
        return "\(connection.uuidString.lowercased())@\(try account(service))"
    }

    static func owned(_ service: ServiceClient, where match: (Owned) -> Bool) throws -> Owned? {
        let key = try recordKey(service)
        return book.withLock { $0.records[key]?.first(where: match) }
    }

    static func changeOwned(_ service: ServiceClient, _ change: (inout [Owned]) -> Void) throws {
        let key = try recordKey(service)
        try book.withLock { book in
            var records = book.records[key] ?? []
            change(&records)
            var changed = book.records
            changed[key] = records.isEmpty ? nil : records
            if let file = book.file {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(changed).write(to: file, options: .atomic)
            }
            book.records = changed
        }
    }

    /// How `now` differs from what was made; `required` fields must be given both times, or whether they changed
    /// cannot be told.
    static func differences(_ made: [String: String], _ now: [String: String], required: [String]) -> [String] {
        var found: [String] = []
        for key in Set(made.keys).union(now.keys).union(required).sorted() {
            let was = made[key], is_ = now[key]
            if required.contains(key), was == nil || is_ == nil {
                found.append("\(key) \(was == nil ? "was" : "is") not given, so whether it changed cannot be told")
            } else if was != is_ {
                found.append("\(key) \(was ?? "not given") is now \(is_ ?? "not given")")
            }
        }
        return found
    }
}

// MARK: - IP Access rules

extension Cloudflare {
    /// What an IP Access rule blocks: Cloudflare's target and value.
    struct Target: Sendable, Equatable {
        let target: String
        let value: String
        var said: String {
            switch target {
            case "ip", "ip6": "the address \(value)"
            case "ip_range": "the range \(value)"
            case "asn": "the network \(value)"
            default: "the country \(value)"
            }
        }
    }

    /// An IPv4 or IPv6 address in one canonical form, so Cloudflare's way of writing it compares with Pion's.
    static func canonicalIP(_ value: String) -> (text: String, v6: Bool)? {
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, value, &v4) == 1, inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil {
            return (String(cString: buffer), false)
        }
        if inet_pton(AF_INET6, value, &v6) == 1, inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil {
            return (String(cString: buffer), true)
        }
        return nil
    }

    /// An address or range as an IP Access rule takes it: one IPv4 or IPv6 address, or a range Cloudflare allows
    /// (IPv4 /16 or /24, IPv6 /32, /48 or /64), in canonical form.
    static func ipTarget(_ raw: String) throws -> Target {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let ip = canonicalIP(parts[0]) else {
            throw ServiceError.input("Nothing was changed: \"\(value)\" is not an IPv4 or IPv6 address or range.")
        }
        guard parts.count == 2 else { return Target(target: ip.v6 ? "ip6" : "ip", value: ip.text) }
        let allowed = ip.v6 ? [32, 48, 64] : [16, 24]
        guard let prefix = Int(parts[1]), allowed.contains(prefix) else {
            throw ServiceError.input("Nothing was changed: an IP Access rule takes a range of \(allowed.map { "/\($0)" }.joined(separator: " or ")) for \(ip.v6 ? "IPv6" : "IPv4"); block one address, or a range of that size.")
        }
        return Target(target: "ip_range", value: "\(ip.text)/\(prefix)")
    }

    static func asnTarget(_ raw: String) throws -> Target {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("AS") { value.removeFirst(2) }
        guard let number = UInt32(value), number > 0 else { throw ServiceError.input("Nothing was changed: give the network's AS number, such as AS64500 or 64500.") }
        return Target(target: "asn", value: "AS\(number)")
    }

    static func countryTarget(_ raw: String) throws -> Target {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 2, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ServiceError.input("Nothing was changed: give the country as its two-letter ISO 3166-1 code, such as RU, or T1 for Tor.")
        }
        return Target(target: "country", value: value)
    }

    /// A rule's target as Cloudflare gave it, in the same canonical form as Pion's.
    static func target(of rule: Item) -> Target? {
        guard let target = rule.text("configuration.target")?.lowercased(), let value = rule.text("configuration.value") else { return nil }
        switch target {
        case "ip", "ip6": return canonicalIP(value).map { Target(target: target, value: $0.text) }
        case "ip_range": return (try? ipTarget(value)).map { Target(target: target, value: $0.value) }
        case "asn": return (try? asnTarget(value)).map { Target(target: target, value: $0.value) }
        default: return Target(target: target, value: value.uppercased())
        }
    }

    /// Where a rule is made: the whole account, or one zone.
    struct RuleScope: Sendable {
        let path: [String]
        let scope: String
        let need: Need
        let said: String
    }

    static func ruleScope(_ zone: String?, _ service: ServiceClient) async throws -> RuleScope {
        let account = try account(service)
        guard let zone else {
            return RuleScope(path: ["accounts", account, "firewall", "access_rules", "rules"], scope: "account:\(account)", need: accountRulesNeed, said: "the whole account")
        }
        let domain = try ServiceInput.domain(zone)
        let id: String
        do { id = try await Cloudflare.zone(domain, on: service) } catch let error as ServiceError {
            if case .input(let reason) = error, reason.hasPrefix("Cloudflare refused") {
                throw ServiceError.input("Nothing was changed: " + reason.replacingOccurrences(of: zonesNeed.permission, with: zoneLookupNeed.permission))
            }
            throw ServiceError.input("Nothing was changed: \(error.localizedDescription)")
        }
        return RuleScope(path: ["zones", id, "firewall", "access_rules", "rules"], scope: "zone:\(id)", need: zoneRulesNeed, said: "the zone \(domain) [\(id)]")
    }

    static func ruleScope(recorded scope: String, _ service: ServiceClient) throws -> RuleScope {
        let account = try account(service)
        if scope == "account:\(account)" {
            return RuleScope(path: ["accounts", account, "firewall", "access_rules", "rules"], scope: scope, need: accountRulesNeed, said: "the whole account")
        }
        guard scope.hasPrefix("zone:"), let zone = hex32(String(scope.dropFirst(5))) else {
            throw ServiceError.input("Nothing was changed: Pion's record places the rule in \(scope), not this account or one of its zones, so it leaves it alone.")
        }
        return RuleScope(path: ["zones", zone, "firewall", "access_rules", "rules"], scope: scope, need: zoneRulesNeed, said: "the zone \(zone)")
    }

    /// Every IP Access rule in `scope` for exactly `target`, read whole, or the read fails. A zone's list includes the
    /// account's rules that apply to it.
    static func rules(for target: Target, in scope: RuleScope, _ service: ServiceClient) async throws -> [Item] {
        let listing = try await read(scope.need) {
            try await list(service, scope.path, query: ["configuration.target": target.target, "configuration.value": target.value, "match": "all"],
                           as: Item.self, size: 100, pages: 5, partial: false)
        }
        guard listing.complete else {
            throw ServiceError.input("Nothing was changed: not every IP Access rule for \(target.value) could be read (\(listing.stopped ?? "more than Pion reads at once")), so whether one exists is not known.")
        }
        return listing.value.filter { Cloudflare.target(of: $0) == target }
    }

    /// The most IP Access rules Pion reads to find one by its ID: 5,000 in a scope.
    static let rulePages = 50

    /// One rule by its exact ID, from every IP Access rule in its scope (the account, or that zone) read whole, never
    /// from the rules for one value, as a rule whose value someone changed keeps its ID. Cloudflare reads a zone's rule
    /// by no ID of its own and documents no answer meaning a rule is not there, so only the whole scope shows either.
    static func rule(_ id: String, in scope: RuleScope, _ service: ServiceClient) async -> Lookup<Item> {
        do {
            let listing = try await read(scope.need) {
                try await list(service, scope.path, query: [:], as: Item.self, size: 100, pages: rulePages, partial: false)
            }
            guard listing.complete else {
                return .inconclusive("not every IP Access rule in \(scope.said) could be read (\(listing.stopped ?? "more than the \(rulePages * 100) Pion reads at once"))")
            }
            let found = listing.value.filter { $0.id == id }
            switch found.count {
            case 0: return .absent
            case 1: return .present(found[0])
            default: return .inconclusive("Cloudflare names rule \(id) \(found.count) times")
            }
        } catch { return .inconclusive(error.localizedDescription) }
    }

    static func ruleSnapshot(_ rule: Item) -> [String: String] {
        var snapshot: [String: String] = [:]
        snapshot["mode"] = rule.text("mode")?.lowercased()
        if let target = target(of: rule) { snapshot["target"] = target.target; snapshot["value"] = target.value }
        snapshot["notes"] = rule.text("notes")
        snapshot["modified_on"] = rule.text("modified_on")
        return snapshot.compactMapValues { $0 }
    }

    static let ruleRequired = ["mode", "target", "value", "modified_on"]

    static func ruleLine(_ rule: Item) -> String {
        let target = Cloudflare.target(of: rule)
        return "\(rule.text("mode") ?? "mode not given") \(target?.target ?? "?") \(target?.value ?? "?")\(rule.text("scope.type").map { " (\($0) level)" } ?? ""), made \(rule.text("created_on") ?? "?")\(rule.text("notes").map { " — \(String($0.prefix(200)))" } ?? "") [\(rule.id)]"
    }

    static let blockRecovery = "Recovery: unblock with the rule's ID removes it, which lets that traffic reach the account's sites again at once; requests blocked meanwhile are not replayed."

    /// Reads every rule for the target, refuses one already there, makes a rule that blocks it, keeps Pion's record of it
    /// only from a plain answer, and reads it back.
    static func block(_ target: Target, zone: String?, reason raw: String, on service: ServiceClient) async throws -> ServiceResult {
        let notes = try approvalNote(raw)
        _ = try recordKey(service)
        let scope = try await ruleScope(zone, service)
        let existing = try await rules(for: target, in: scope, service)
        if let held = existing.first {
            let ours = (try? owned(service) { $0.kind == "ip-access-rule" && $0.id == held.id }) != nil
            throw ServiceError.input("Nothing was changed: an IP Access rule already holds \(target.value), \(ours ? "which Pion made through this connection" : "which Pion has no record of making, so it leaves it alone"): \(ruleLine(held)).")
        }
        let body = try json(["mode": "block", "configuration": ["target": target.target, "value": target.value], "notes": notes])
        let request = requested("POST", scope.path, "to block \(target.target) \(target.value) in \(scope.said)")
        let noRecord = "Pion kept no record of it, so unblock cannot remove it: read it with action-status, and remove it in the dashboard if it was made and should go."
        let (result, problem) = try await change(service, scope.path, method: "POST", body: body, need: scope.need)
        if let problem {
            throw ServiceError.input("The request to block \(target.said) could not be verified: \(problem). It is not reported done. \(noRecord)\n\(request)\n\(blockRecovery)")
        }
        guard let result, case .object = result, let id = result["id"]?.text.flatMap(hex32) else {
            throw ServiceError.input("Cloudflare answered the request to block \(target.said) without naming the rule it made, so whether it was made is not known, and it is not reported done. \(noRecord)\n\(request)\n\(blockRecovery)")
        }
        let made = Item(fields: result, id: id)
        let snapshot = ruleSnapshot(made)
        var mismatch: [String] = []
        if snapshot["mode"] != "block" { mismatch.append("mode \(snapshot["mode"] ?? "not given")") }
        if Cloudflare.target(of: made) != target { mismatch.append("target \(snapshot["target"] ?? "?") \(snapshot["value"] ?? "not given")") }
        if let given = snapshot["notes"], given != notes { mismatch.append("notes \"\(given)\"") }
        // Cloudflare names an account rule's scope by the account's ID; a zone rule's answer gives none.
        if let given = made.text("scope.id")?.lowercased(), !scope.scope.hasSuffix(":" + given) { mismatch.append("scope \(given)") }
        guard mismatch.isEmpty else {
            throw ServiceError.input("Cloudflare made rule \(id), but not as asked (\(mismatch.joined(separator: ", "))), so it is not reported done. \(noRecord)\n\(request)\n\(blockRecovery)")
        }
        await pause(pauses.first ?? 0)
        var unverified: String?, changed: [String] = []
        switch await rule(id, in: scope, service) {
        case .present(let now):
            changed = differences(snapshot, ruleSnapshot(now), required: ruleRequired)
            if !changed.isEmpty { unverified = "read back, it is not as Cloudflare said it made it: \(changed.joined(separator: "; "))" }
        case .absent: unverified = "read back, Cloudflare lists no rule \(id) in \(scope.said)"
        case .inconclusive(let why): unverified = "reading it back: \(why)"
        }
        do {
            try changeOwned(service) { records in
                records.removeAll { $0.kind == "ip-access-rule" && $0.id == id }
                records.append(Owned(kind: "ip-access-rule", id: id, scope: scope.scope, label: "\(target.target) \(target.value)", created: Date(), made: snapshot,
                                     changedSinceCreation: !changed.isEmpty))
            }
        } catch {
            throw ServiceError.input("Cloudflare made rule \(id) blocking \(target.said), but Pion could not keep its record of it (\(error.localizedDescription)), so unblock cannot remove it: remove it in the dashboard when it should go.\n\(request)")
        }
        if let unverified {
            let kept = changed.isEmpty ? "Pion keeps its record of it as made, so unblock with its ID can remove it while Cloudflare gives it as made."
                : "Pion keeps its record, marked changed since it was made, so unblock will not remove it: remove it in the dashboard when it should go."
            throw ServiceError.input("Cloudflare answered that it made rule \(id) blocking \(target.said), but it could not be verified: \(unverified). It is not reported done. \(kept)\n\(request)\n\(blockRecovery)")
        }
        var lines = ["Cloudflare made IP Access rule \(id): \(target.said) blocked in \(scope.said), read back as made. Pion keeps a record that it made it, which unblock needs."]
        if snapshot["modified_on"] == nil { lines.append("Cloudflare gave no modified_on for it, so unblock cannot tell later whether it changed and will leave it in place; remove it in the dashboard when it should go.") }
        lines.append("Only rules for exactly \(target.value) were checked first: a range, network or country rule that also covers it, or a WAF rule that lets it through first, was not.")
        lines.append(blockRecovery)
        struct Kept: Encodable { let id: String; let target: String; let value: String; let scope: String; let done: Bool; let recovery: String }
        return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(id: id, target: target.target, value: target.value, scope: scope.scope, done: true, recovery: blockRecovery))
    }

    static let zoneField = JSONSchema.string("Only this zone, by its domain, such as example.com. The whole account when left out.")
    static let reasonField = JSONSchema.string("Why: the reason given in the approval request, with the Investigation. Kept as the rule's notes.")

    struct BlockIP: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String; let zone: String?; let reason: String }
        static let name = "block-ip"
        static let summary = "Block an IP address, or an IPv4 /16 or /24 or IPv6 /32, /48 or /64 range, at Cloudflare's edge with an IP Access rule, for the whole account or one zone, and keep a record that Pion made it, which unblock needs. Refused when any rule already holds that value, whoever made it. \(Cloudflare.blockRecovery)"
        static let input = JSONSchema.object(["ip": .string("The IPv4 or IPv6 address, or range."), "zone": Cloudflare.zoneField, "reason": Cloudflare.reasonField], required: ["ip", "reason"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await Cloudflare.block(try Cloudflare.ipTarget(input.ip), zone: input.zone, reason: input.reason, on: service)
        }
    }

    struct BlockASN: ServiceOperation {
        struct Input: Decodable, Sendable { let asn: String; let zone: String?; let reason: String }
        static let name = "block-asn"
        static let summary = "Block a whole network by its AS number at Cloudflare's edge with an IP Access rule, for the whole account or one zone, and keep a record that Pion made it. A network carries everyone it serves, customers included, so prefer block-ip unless the network itself is hostile. \(Cloudflare.blockRecovery)"
        static let input = JSONSchema.object(["asn": .string("The AS number, such as AS64500."), "zone": Cloudflare.zoneField, "reason": Cloudflare.reasonField], required: ["asn", "reason"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await Cloudflare.block(try Cloudflare.asnTarget(input.asn), zone: input.zone, reason: input.reason, on: service)
        }
    }

    struct BlockCountry: ServiceOperation {
        struct Input: Decodable, Sendable { let country: String; let zone: String?; let reason: String }
        static let name = "block-country"
        static let summary = "Block a whole country at Cloudflare's edge with an IP Access rule, for the whole account or one zone, and keep a record that Pion made it. Cloudflare lets only Enterprise plans block a country; it refuses otherwise. Everyone there is cut off, travelling staff and customers included. \(Cloudflare.blockRecovery)"
        static let input = JSONSchema.object(["country": .string("The two-letter ISO 3166-1 code, such as RU, or T1 for Tor."), "zone": Cloudflare.zoneField, "reason": Cloudflare.reasonField],
                                             required: ["country", "reason"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await Cloudflare.block(try Cloudflare.countryTarget(input.country), zone: input.zone, reason: input.reason, on: service)
        }
    }

    struct Unblock: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "unblock"
        static let recovery = "Recovery: block-ip, block-asn or block-country again restores the block. Removing it lets that traffic reach the account's sites again at once."
        static let summary = "Remove one IP Access rule, by its ID, that Pion's own record says block-ip, block-asn or block-country made through this connection, in the same account or zone, and that Cloudflare still holds as made; any other is left in place, whatever its notes say. Held, as it lifts a block. \(recovery)"
        static let input = JSONSchema.object(["id": .string("The rule's ID, as the block gave it.")], required: ["id"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard let id = Cloudflare.hex32(input.id) else { throw ServiceError.input("Nothing was changed: give the rule's ID exactly as the block gave it: 32 hexadecimal characters.") }
            guard let record = try Cloudflare.owned(service, where: { $0.kind == "ip-access-rule" && $0.id == id }) else {
                throw ServiceError.input("Nothing was changed: Pion has no record of making IP Access rule \(id) through this connection, so it leaves it in place, whatever its notes say. Remove it in the dashboard if it should go.")
            }
            guard !record.changedSinceCreation else {
                throw ServiceError.input("Nothing was changed: rule \(id) was not as Cloudflare said it made it when Pion first read it back, so someone may have changed it, and Pion leaves it in place. Remove it in the dashboard if it should go.")
            }
            guard let targetKind = record.made["target"], let value = record.made["value"] else {
                throw ServiceError.input("Nothing was changed: Pion's record of rule \(id) does not say what it blocks, so it cannot be read whole and is left in place.")
            }
            let target = Target(target: targetKind, value: value)
            let scope = try Cloudflare.ruleScope(recorded: record.scope, service)
            let held: Item
            switch await Cloudflare.rule(id, in: scope, service) {
            case .absent:
                try? Cloudflare.changeOwned(service) { $0.removeAll { $0.kind == "ip-access-rule" && $0.id == id } }
                throw ServiceError.input("Nothing was changed: every IP Access rule in \(scope.said) was read, and none is \(id), so there is nothing to remove; Pion drops its record of it.")
            case .inconclusive(let why):
                throw ServiceError.input("Nothing was changed: whether Cloudflare still holds rule \(id) as Pion made it could not be told (\(why)), so it is left in place, and Pion keeps its record.")
            case .present(let rule): held = rule
            }
            let changed = Cloudflare.differences(record.made, Cloudflare.ruleSnapshot(held), required: Cloudflare.ruleRequired)
            guard changed.isEmpty else {
                throw ServiceError.input("Nothing was changed: rule \(id) has changed since Pion made it, or cannot be shown not to have: \(changed.joined(separator: "; ")). Someone may have changed it, so Pion leaves it in place and keeps its record; remove it in the dashboard if it should go.")
            }
            let path = scope.path + [id]
            // A zone's rule is removed from that zone alone, never from others of the account.
            let body = scope.scope.hasPrefix("zone:") ? try Cloudflare.json(["cascade": "none"]) : nil
            let request = Cloudflare.requested("DELETE", path, "of the \(target.target) \(value) rule")
            let (result, problem) = try await Cloudflare.change(service, path, method: "DELETE", body: body, need: scope.need)
            if let problem = problem ?? (result?["id"]?.text?.lowercased() == id ? nil : "Cloudflare's answer named \(result?["id"]?.text ?? "no rule"), not \(id)") {
                throw ServiceError.input("The request to remove rule \(id) could not be verified: \(problem). It is not reported removed, and Pion keeps its record; read it with action-status.\n\(request)\n\(Self.recovery)")
            }
            await Cloudflare.pause(Cloudflare.pauses.first ?? 0)
            switch await Cloudflare.rule(id, in: scope, service) {
            case .absent: break
            case .present(let still):
                let changed = Cloudflare.differences(record.made, Cloudflare.ruleSnapshot(still), required: Cloudflare.ruleRequired)
                throw ServiceError.input("Cloudflare still lists rule \(id) after the request to remove it\(changed.isEmpty ? "" : ", changed since Pion made it (\(changed.joined(separator: "; ")))"): \(Cloudflare.ruleLine(still)). It is not reported removed, and Pion keeps its record.\n\(request)\n\(Self.recovery)")
            case .inconclusive(let why):
                throw ServiceError.input("Cloudflare answered that it removed rule \(id), but whether it is gone is unverified (\(why)), so it is not reported removed and Pion keeps its record. Read it with action-status.\n\(request)\n\(Self.recovery)")
            }
            var lines = ["Removed IP Access rule \(id), which blocked \(target.said) in \(scope.said) and which Pion made through this connection: Cloudflare named it as removed and no longer lists it."]
            do { try Cloudflare.changeOwned(service) { $0.removeAll { $0.kind == "ip-access-rule" && $0.id == id } } }
            catch { lines.append("Pion could not drop its record of it (\(error.localizedDescription)); that changes nothing in Cloudflare.") }
            lines.append(Self.recovery)
            struct Kept: Encodable { let removed: String; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(removed: id, done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - Access sessions

extension Cloudflare {
    struct ContainmentAccessUser: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "access-user"
        static let summary = "A Zero Trust user's state before acting, by email or ID: their ID, last login and every active Access session. It changes nothing."
        static let input = JSONSchema.object(["user": .string("The user's email address, or their ID.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try await Cloudflare.targetUser(input.user, service)
            var lines = [Cloudflare.userLine(user)]
            let sessions: [String]?
            do {
                let listing = try await Cloudflare.sessions(user.id, service, need: Cloudflare.editZeroTrustNeed)
                sessions = listing.value.map(Cloudflare.sessionLine)
                lines.append(sessions!.isEmpty ? "No active Access session." : "\(Cloudflare.plural(sessions!.count, "active Access session")):\n" + sessions!.joined(separator: "\n"))
            } catch {
                sessions = nil
                lines.append("Their sessions could not be read: \(error.localizedDescription)")
            }
            lines.append("Read at \(Cloudflare.iso(Date())).")
            struct Kept: Encodable { let id: String; let email: String?; let sessions: [String]? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(id: user.id, email: user.text("email"), sessions: sessions))
        }
    }

    /// Reads a user whole by email or ID, or refuses.
    static func targetUser(_ value: String, _ service: ServiceClient) async throws -> Item {
        switch try await accessUser(value, service, need: editZeroTrustNeed) {
        case .present(let user): return user
        case .absent: throw ServiceError.input("Nothing was changed: Zero Trust has no user \(value); every user listed for it was read and none matches.")
        case .inconclusive(let why): throw ServiceError.input("Nothing was changed: the user \(value) could not be read whole first (\(why)).")
        }
    }

    struct RevokeAccessSessions: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "revoke-access-sessions"
        static let recovery = "Recovery: nothing to undo; the person signs in again through Access with their identity provider and gets new sessions. A revocation cannot be reversed, and it does not stop them signing in again: if their account is taken over, suspend it at the identity provider too."
        static let summary = "End every Access session a Zero Trust user has, by their email, so each Access application asks them to sign in again. Confirmed only when their sessions, read again, are gone. \(recovery)"
        static let input = JSONSchema.object(["user": .string("The user's email address, as access-user gives it.")], required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try await Cloudflare.targetUser(input.user, service)
            guard let email = user.text("email").map({ $0.lowercased() }) else {
                throw ServiceError.input("Nothing was changed: Cloudflare gave user \(user.id) no email, which revoking takes.")
            }
            var notes: [String] = []
            do {
                let before = try await Cloudflare.sessions(user.id, service, need: Cloudflare.editZeroTrustNeed)
                if before.value.isEmpty {
                    throw ServiceError.input("Nothing was changed: \(email) has no active Access session, per a whole read of their sessions, so there is nothing to revoke.")
                }
                notes.append("They had \(Cloudflare.plural(before.value.count, "active session")) before.")
            } catch let error as ServiceError {
                if case .input(let reason) = error, reason.hasPrefix("Nothing was changed") { throw error }
                notes.append("Their sessions could not be read first (\(error.localizedDescription)), so whether they had any is not known.")
            }
            let path = ["accounts", try Cloudflare.account(service), "access", "organizations", "revoke_user"]
            let request = Cloudflare.requested("POST", path, "for \(email)")
            let (result, problem) = try await Cloudflare.change(service, path, method: "POST", body: try Cloudflare.json(["email": email]), need: Cloudflare.editZeroTrustNeed)
            if let problem = problem ?? (result?.flag == true ? nil : "Cloudflare answered \(result?.text ?? "nothing") rather than true") {
                throw ServiceError.input("The request to revoke \(email)'s sessions could not be verified: \(problem). It is not reported done; read them with access-user.\n\(request)\n\(Self.recovery)")
            }
            var left: Int?, unread: String?
            for pause in Cloudflare.pauses {
                await Cloudflare.pause(pause)
                do {
                    left = try await Cloudflare.sessions(user.id, service, need: Cloudflare.editZeroTrustNeed).value.count
                    unread = nil
                } catch { unread = error.localizedDescription }
                if left == 0 { break }
            }
            guard left == 0 else {
                let why = unread.map { "reading their sessions again failed: \($0)" } ?? "Cloudflare still lists \(Cloudflare.plural(left ?? 0, "active session"))"
                throw ServiceError.input("Cloudflare answered true to the request to revoke \(email)'s sessions, which names no user, and it could not be confirmed: \(why). It is not reported done; read them with access-user.\n\(request)\n\(Self.recovery)")
            }
            var lines = ["Revoked every Access session of \(email) [\(user.id)]: Cloudflare accepted it, and their sessions, read again, are gone."]
            lines += notes
            lines.append("Each Access application asks them to sign in again; a WARP device's own session is not ended by this.")
            lines.append(Self.recovery)
            struct Kept: Encodable { let user: String; let email: String; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(user: user.id, email: email, done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - Gateway

extension Cloudflare {
    /// What Pion blocks in Gateway: a domain, in its DOMAIN list, which a DNS rule blocks; or an IP address or range,
    /// in its IP list, which a network rule blocks.
    struct GatewayKind: Sendable {
        let label: String
        let listType: String
        let listName: String
        let ruleName: String
        let filter: String
        func traffic(_ list: String) -> String { label == "domain" ? "any(dns.domains[*] in $\(list))" : "net.dst.ip in $\(list)" }
        var reaches: String { label == "domain" ? "devices that resolve through Gateway's DNS" : "devices whose traffic goes through Gateway's proxy with WARP" }
    }

    static let domainKind = GatewayKind(label: "domain", listType: "DOMAIN", listName: "Pion blocked domains", ruleName: "Pion: block the domains in Pion's list", filter: "dns")
    static let ipKind = GatewayKind(label: "ip", listType: "IP", listName: "Pion blocked IP addresses", ruleName: "Pion: block the IP addresses in Pion's list", filter: "l4")

    /// A value Gateway takes, and which of Pion's lists it goes in.
    static func gatewayValue(_ raw: String) throws -> (kind: GatewayKind, value: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let ip = canonicalIP(parts[0]) {
            guard parts.count == 1 || (parts.count == 2 && Int(parts[1]).map { (ip.v6 ? 8...128 : 8...32).contains($0) } == true) else {
                throw ServiceError.input("Nothing was changed: \"\(value)\" is not an IP address or a range Gateway takes.")
            }
            return (ipKind, parts.count == 2 ? "\(ip.text)/\(parts[1])" : ip.text)
        }
        guard let domain = try? ServiceInput.domain(value) else { throw ServiceError.input("Nothing was changed: give a domain, such as evil.example, or an IP address or range.") }
        return (domainKind, domain)
    }

    static func listSnapshot(_ list: Item) -> [String: String] {
        ["name": list.text("name"), "type": list.text("type")?.uppercased(), "description": list.text("description")].compactMapValues { $0 }
    }

    static func gatewayRuleSnapshot(_ rule: Item) -> [String: String] {
        ["name": rule.text("name"), "action": rule.text("action")?.lowercased(), "enabled": rule.flag("enabled").map(String.init), "traffic": rule.text("traffic"),
         "filters": rule.texts("filters").joined(separator: ",").nilIfBlank].compactMapValues { $0 }
    }

    /// One entry of a Gateway list as Cloudflare gives it. Cloudflare gives an entry no ID of its own, so its value,
    /// description and the time it was added are all that tell it from another entry put in its place.
    struct GatewayItem: Sendable, Equatable {
        let value: String
        let description: String?
        let created: String?
    }

    /// Every item in a Gateway list, read whole, or the read fails.
    static func listItems(_ list: String, _ service: ServiceClient) async throws -> [GatewayItem] {
        let listing = try await read(editZeroTrustNeed) {
            try await Cloudflare.list(service, ["accounts", try account(service), "gateway", "lists", list, "items"], query: [:], as: Value.self, size: 1_000, pages: 10, partial: false)
        }
        guard listing.complete else { throw ServiceError.input("not every item in list \(list) could be read (\(listing.stopped ?? "more than Pion reads at once"))") }
        return listing.value.compactMap { item in
            item["value"]?.text.map { GatewayItem(value: $0.lowercased(), description: item["description"]?.text, created: item["created_at"]?.text) }
        }
    }

    /// Where a person removes an entry from Pion's list themselves.
    static func dashboardSteps(_ kind: GatewayKind, _ value: String) -> String {
        "To remove it yourself, open the Cloudflare dashboard's Zero Trust › Reusable components › Lists (My Team › Lists on older dashboards), open \(kind.listName), and delete \(value), if it should go."
    }

    /// Pion's own list of this kind, as recorded and as Cloudflare still gives it, or why it cannot be used.
    static func ownList(_ kind: GatewayKind, _ service: ServiceClient) async throws -> (record: Owned, items: [GatewayItem])? {
        guard let record = try owned(service, where: { $0.kind == "gateway-list" && $0.label == kind.label }) else { return nil }
        guard !record.changedSinceCreation else {
            throw ServiceError.input("Nothing was changed: Pion's \(kind.label) list \(record.id) was not as Cloudflare said it made it when Pion first read it back, so Pion no longer uses it. Delete it in the dashboard, and Pion makes a new one next time.")
        }
        let path = ["accounts", try account(service), "gateway", "lists", record.id]
        switch try await read(editZeroTrustNeed, { try await fetch(service, path, id: record.id, what: "Gateway list") }) {
        case .present(let list):
            let changed = differences(record.made, listSnapshot(list), required: ["name", "type"])
            guard changed.isEmpty else {
                throw ServiceError.input("Nothing was changed: Pion's \(kind.label) list \(record.id) is not as Pion made it (\(changed.joined(separator: "; "))), so Pion leaves it alone. Delete it in the dashboard, and Pion makes a new one next time.")
            }
        case .absent, .inconclusive:
            // Cloudflare documents no answer meaning a list is not there, so only the whole list of lists can say so.
            switch try await read(editZeroTrustNeed, { try await find(service, ["accounts", try account(service), "gateway", "lists"], query: [:], id: record.id, what: "Gateway list", paging: .single) }) {
            case .absent:
                try? changeOwned(service) { $0.removeAll { ($0.kind == "gateway-list" && $0.id == record.id) || $0.scope == "list:\(record.id)" } }
                return nil
            case .present:
                throw ServiceError.input("Nothing was changed: Pion's \(kind.label) list \(record.id) is listed but could not be read by its ID, so whether it is as Pion made it is not known.")
            case .inconclusive(let why):
                throw ServiceError.input("Nothing was changed: Pion's \(kind.label) list \(record.id) could not be read whole (\(why)).")
            }
        }
        do { return (record, try await listItems(record.id, service)) }
        catch { throw ServiceError.input("Nothing was changed: \(error.localizedDescription), so whether it already holds the value is not known.") }
    }

    /// Whether Pion's rule for the list blocks it now: present, on, a block, on the list, as made; and the enabled
    /// allow rules evaluated before it that could let the value through.
    static func ruleState(_ kind: GatewayKind, list listID: String, _ service: ServiceClient) async -> (blocks: Bool, said: String, record: Owned?) {
        let record = try? owned(service) { $0.kind == "gateway-rule" && $0.label == kind.label && $0.made["traffic"] == kind.traffic(listID) }
        guard let record else { return (false, "Pion has no record of a Gateway rule blocking its \(kind.label) list", nil) }
        let listing: Listing<Item>
        do { listing = try await read(editZeroTrustNeed) { try await list(service, ["accounts", try account(service), "gateway", "rules"], query: [:], as: Item.self, paging: .single, size: 0) } }
        catch { return (false, "Pion's rule \(record.id) could not be read (\(error.localizedDescription)), so whether it blocks is unknown", record) }
        guard listing.complete else { return (false, "not every Gateway rule could be read, so whether Pion's rule \(record.id) blocks is unknown", record) }
        let named = listing.value.filter { $0.id == record.id && $0.text("deleted_at") == nil }
        guard named.count == 1 else { return (false, named.isEmpty ? "Pion's rule \(record.id) is no longer listed, so nothing in the list is blocked" : "Cloudflare names Pion's rule \(record.id) more than once", record) }
        let rule = named[0]
        let changed = differences(record.made, gatewayRuleSnapshot(rule), required: ["action", "enabled", "traffic"])
        guard changed.isEmpty else { return (false, "Pion's rule \(record.id) is not as Pion made it (\(changed.joined(separator: "; "))), so whether it blocks is not known; Pion leaves it as found", record) }
        var said = "Pion's rule \(record.id) blocks the list for \(kind.reaches), at precedence \(rule.text("precedence") ?? "not given")"
        if let precedence = rule.number("precedence") {
            let ahead = listing.value.filter { $0.id != rule.id && $0.text("deleted_at") == nil && $0.flag("enabled") != false && $0.texts("filters").contains(kind.filter)
                && ["allow", "bypass", "override"].contains($0.text("action")?.lowercased() ?? "") && ($0.number("precedence") ?? .max) < precedence }
            if !ahead.isEmpty { said += "; ⚠ evaluated before it, \(ahead.prefix(5).map { "\($0.text("action") ?? "?") rule \($0.text("name") ?? $0.id)" }.joined(separator: ", ")) may let the value through" }
        } else { said += "; as its precedence was not given, which rules are evaluated before it is not known" }
        return (true, said, record)
    }

    /// Makes Pion's list of this kind with its first value, and the rule that blocks it, keeping Pion's record of each
    /// only from a plain answer.
    static func makeList(_ kind: GatewayKind, first value: String, description: String, _ service: ServiceClient) async throws -> (list: String, lines: [String]) {
        let account = try account(service)
        let path = ["accounts", account, "gateway", "lists"]
        let listDescription = "Made by Pion for values the champion approved blocking; Pion adds and removes only its own items."
        let body = try json(["name": kind.listName, "type": kind.listType, "description": listDescription, "items": [["value": value, "description": description]]])
        let request = requested("POST", path, "making the list \(kind.listName) with \(value)")
        let (result, problem) = try await change(service, path, method: "POST", body: body, need: editZeroTrustNeed)
        guard problem == nil, let result, let id = result["id"]?.text.flatMap(uuid) else {
            throw ServiceError.input("The request to make Pion's \(kind.label) list with \(value) could not be verified: \(problem ?? "Cloudflare's answer named no list"). It is not reported done, and Pion kept no record of it: if it was made, delete it in the dashboard.\n\(request)")
        }
        let made = listSnapshot(Item(fields: result, id: id))
        guard made["name"] == kind.listName, made["type"] == kind.listType else {
            throw ServiceError.input("Cloudflare made list \(id), but not as asked (\(made["name"] ?? "no name"), \(made["type"] ?? "no type")), so Pion keeps no record of it: delete it in the dashboard.\n\(request)")
        }
        try changeOwned(service) { $0.append(Owned(kind: "gateway-list", id: id, scope: "account:\(account)", label: kind.label, created: Date(), made: made, changedSinceCreation: false)) }
        var lines = ["Made Pion's \(kind.label) list \(id), \(kind.listName)."]
        lines += try await makeRule(kind, list: id, service)
        return (id, lines)
    }

    /// Makes Pion's rule that blocks its list, keeping Pion's record of it only from a plain answer naming it as asked.
    static func makeRule(_ kind: GatewayKind, list: String, _ service: ServiceClient) async throws -> [String] {
        let account = try account(service)
        let path = ["accounts", account, "gateway", "rules"]
        let traffic = kind.traffic(list)
        let body = try json(["name": kind.ruleName, "description": "Made by Pion: blocks what is in Pion's list.", "action": "block", "enabled": true, "filters": [kind.filter], "traffic": traffic])
        let request = requested("POST", path, "making the rule \(kind.ruleName) on \(traffic)")
        let (result, problem) = try await change(service, path, method: "POST", body: body, need: editZeroTrustNeed)
        guard problem == nil, let result, let id = result["id"]?.text.flatMap(uuid) else {
            return ["⚠ The rule that blocks the list could not be verified as made (\(problem ?? "Cloudflare's answer named no rule")), so the list may block nothing; Pion kept no record of it. \(request)"]
        }
        let made = gatewayRuleSnapshot(Item(fields: result, id: id))
        guard made["action"] == "block", made["enabled"] == "true", made["traffic"] == traffic, made["filters"] == kind.filter else {
            return ["⚠ Cloudflare made rule \(id), but not as asked (\(made.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))), so Pion keeps no record of it and the list may block nothing: delete it in the dashboard. \(request)"]
        }
        try changeOwned(service) { $0.append(Owned(kind: "gateway-rule", id: id, scope: "account:\(account)", label: kind.label, created: Date(), made: made, changedSinceCreation: false)) }
        return ["Made Pion's Gateway rule \(id), which blocks what is in the list."]
    }

    struct GatewayBlock: ServiceOperation {
        struct Input: Decodable, Sendable { let value: String; let reason: String }
        static let name = "gateway-block"
        static let recovery = "Recovery: gateway-unblock with the same value removes it from Pion's list, which lets devices resolve or reach it again at once, as far as Gateway's other rules allow."
        static let summary = "Block a domain (and its subdomains) or an IP address or range for every device using Gateway, by adding it to Pion's own Gateway list, which Pion makes the first time with a Gateway rule that blocks it; a domain is blocked in DNS, an address in network traffic through WARP. Refused when Pion's list already holds it. \(recovery)"
        static let input = JSONSchema.object(["value": .string("The domain, such as evil.example, or IP address or range."), "reason": Cloudflare.reasonField], required: ["value", "reason"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (kind, value) = try Cloudflare.gatewayValue(input.value)
            let description = try Cloudflare.approvalNote(input.reason)
            _ = try Cloudflare.recordKey(service)
            var lines: [String] = []
            let list: String
            if let (record, items) = try await Cloudflare.ownList(kind, service) {
                if items.contains(where: { $0.value == value }) { throw ServiceError.input("Nothing was changed: Pion's \(kind.label) list \(record.id) already holds \(value).") }
                list = record.id
                let path = ["accounts", try Cloudflare.account(service), "gateway", "lists", list]
                let request = Cloudflare.requested("PATCH", path, "appending \(value)")
                let (result, problem) = try await Cloudflare.change(service, path, method: "PATCH", body: try Cloudflare.json(["append": [["value": value, "description": description]]]), need: Cloudflare.editZeroTrustNeed)
                if let problem = problem ?? (result?["id"]?.text?.lowercased() == list ? nil : "Cloudflare's answer named \(result?["id"]?.text ?? "no list"), not \(list)") {
                    throw ServiceError.input("The request to add \(value) to Pion's list could not be verified: \(problem). It is not reported done; read it with action-status.\n\(request)\n\(Self.recovery)")
                }
                if await Cloudflare.ruleState(kind, list: list, service).record == nil { lines += try await Cloudflare.makeRule(kind, list: list, service) }
            } else {
                let made = try await Cloudflare.makeList(kind, first: value, description: description, service)
                list = made.list
                lines += made.lines
            }
            await Cloudflare.pause(Cloudflare.pauses.first ?? 0)
            let entries: [Cloudflare.GatewayItem]
            do { entries = try await Cloudflare.listItems(list, service).filter { $0.value == value } }
            catch { throw ServiceError.input("Cloudflare answered the request to add \(value) to Pion's list \(list), but reading the list again failed (\(error.localizedDescription)), so it is not reported done. Read it with action-status.\n\(Self.recovery)") }
            guard entries.count == 1, let entry = entries.first, entry.description == description else {
                throw ServiceError.input("Cloudflare answered the request to add \(value) to Pion's list \(list), but the list, read whole again, \(entries.isEmpty ? "does not hold it" : "holds \(Cloudflare.plural(entries.count, "entry")) for it, not exactly the one Pion added with its description"), so it is not reported done and Pion keeps no record of adding it. \(Cloudflare.dashboardSteps(kind, value))\n\(Self.recovery)")
            }
            // What tells this entry from one put in its place later: its value, Pion's description, and when it was added.
            var made = ["value": value, "description": description]
            made["created_at"] = entry.created
            if entry.created == nil { lines.append("⚠ Cloudflare gave no time the entry was added, so gateway-unblock cannot tell it from an entry put in its place and will leave its removal to the dashboard. \(Cloudflare.dashboardSteps(kind, value))") }
            do { try Cloudflare.changeOwned(service) { records in
                records.removeAll { $0.kind == "gateway-item" && $0.scope == "list:\(list)" && $0.label == value }
                records.append(Owned(kind: "gateway-item", id: "\(list)/\(value)", scope: "list:\(list)", label: value, created: Date(), made: made, changedSinceCreation: false))
            } } catch {
                lines.append("⚠ Pion could not keep its record of adding \(value) (\(error.localizedDescription)), so gateway-unblock cannot remove it: remove it in the dashboard when it should go.")
            }
            let state = await Cloudflare.ruleState(kind, list: list, service)
            lines.insert("Added \(value) to Pion's \(kind.label) list \(list); the list, read whole again, holds it.", at: 0)
            lines.append(state.blocks ? "\(state.said)." : "⚠ It is in the list, but it is not shown to be blocked: \(state.said).")
            lines.append(Self.recovery)
            struct Kept: Encodable { let value: String; let list: String; let inList: Bool; let blocked: Bool; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(value: value, list: list, inList: true, blocked: state.blocks, done: state.blocks, recovery: Self.recovery))
        }
    }

    struct GatewayUnblock: ServiceOperation {
        struct Input: Decodable, Sendable { let value: String }
        static let name = "gateway-unblock"
        static let recovery = "Recovery: gateway-block again restores the block. Removing it lets devices resolve or reach it again at once."
        static let summary = "Remove a domain or IP address that gateway-block added to Pion's own Gateway list, so devices resolve or reach it again; anything else in the list, or in other lists, is left in place. Held, as it lifts a block. \(recovery)"
        static let input = JSONSchema.object(["value": .string("The domain or IP address, as gateway-block took it.")], required: ["value"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (kind, value) = try Cloudflare.gatewayValue(input.value)
            guard let item = try Cloudflare.owned(service, where: { $0.kind == "gateway-item" && $0.label == value }) else {
                throw ServiceError.input("Nothing was changed: Pion has no record of adding \(value) to its Gateway list through this connection, so it leaves it alone.")
            }
            guard let (record, items) = try await Cloudflare.ownList(kind, service), item.scope == "list:\(record.id)" else {
                try? Cloudflare.changeOwned(service) { $0.removeAll { $0.kind == "gateway-item" && $0.label == value } }
                throw ServiceError.input("Nothing was changed: Pion's \(kind.label) list that held \(value) is gone, so there is nothing to remove; Pion drops its record of it.")
            }
            let entries = items.filter { $0.value == value }
            guard !entries.isEmpty else {
                try? Cloudflare.changeOwned(service) { $0.removeAll { $0.kind == "gateway-item" && $0.label == value } }
                throw ServiceError.input("Nothing was changed: Pion's list \(record.id), read whole, does not hold \(value), so there is nothing to remove; Pion drops its record of it.")
            }
            // Cloudflare gives an entry no ID, so only its description and the time it was added show it is the entry Pion
            // added and not one someone put in its place.
            guard let added = item.made["created_at"] else {
                throw ServiceError.input("Nothing was changed: Cloudflare gave no time when Pion added \(value), so an entry someone put in its place cannot be told from Pion's, and Pion leaves it and keeps its record. \(Cloudflare.dashboardSteps(kind, value))")
            }
            guard entries.count == 1, entries[0].description == item.made["description"], entries[0].created == added else {
                let found = entries.map { "added \($0.created ?? "at a time not given")\($0.description.map { ", described \"\(String($0.prefix(120)))\"" } ?? ", without a description")" }.joined(separator: "; ")
                throw ServiceError.input("Nothing was changed: the entry for \(value) in Pion's list \(record.id) is not, or cannot be shown to be, the one Pion added at \(added) (Cloudflare gives \(found)). Someone may have replaced it, so Pion leaves it and keeps its record. \(Cloudflare.dashboardSteps(kind, value))")
            }
            let path = ["accounts", try Cloudflare.account(service), "gateway", "lists", record.id]
            let request = Cloudflare.requested("PATCH", path, "removing \(value)")
            let (result, problem) = try await Cloudflare.change(service, path, method: "PATCH", body: try Cloudflare.json(["remove": [value]]), need: Cloudflare.editZeroTrustNeed)
            if let problem = problem ?? (result?["id"]?.text?.lowercased() == record.id ? nil : "Cloudflare's answer named \(result?["id"]?.text ?? "no list"), not \(record.id)") {
                throw ServiceError.input("The request to remove \(value) from Pion's list could not be verified: \(problem). It is not reported removed, and Pion keeps its record.\n\(request)\n\(Self.recovery)")
            }
            await Cloudflare.pause(Cloudflare.pauses.first ?? 0)
            let still: Bool
            do { still = try await Cloudflare.listItems(record.id, service).contains { $0.value == value } }
            catch { throw ServiceError.input("Cloudflare answered the request to remove \(value), but reading the list again failed (\(error.localizedDescription)), so it is not reported removed and Pion keeps its record.\n\(request)\n\(Self.recovery)") }
            guard !still else { throw ServiceError.input("Pion's list \(record.id), read whole again, still holds \(value), so it is not reported removed and Pion keeps its record.\n\(request)\n\(Self.recovery)") }
            var lines = ["Removed \(value) from Pion's \(kind.label) list \(record.id): Cloudflare named the list, and the list, read whole again, no longer holds it."]
            do { try Cloudflare.changeOwned(service) { $0.removeAll { $0.kind == "gateway-item" && $0.label == value } } }
            catch { lines.append("Pion could not drop its record of it (\(error.localizedDescription)); that changes nothing in Cloudflare.") }
            lines.append("Another list or rule may still block it; gateway-rules lists them.")
            lines.append(Self.recovery)
            struct Kept: Encodable { let removed: String; let list: String; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(removed: value, list: record.id, done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - WARP devices

extension Cloudflare {
    /// One WARP registration by its exact ID, read through a listing asked for that ID alone, revoked ones included.
    static func registration(_ id: String, _ service: ServiceClient) async throws -> Lookup<Item> {
        try await read(editZeroTrustNeed) {
            try await find(service, ["accounts", try account(service), "devices", "registrations"], query: ["id": id, "status": "all"], id: id, what: "WARP registration",
                           size: 50, pages: 2, paging: .cursor, filtered: true)
        }
    }

    static func targetRegistration(_ value: String, _ service: ServiceClient) async throws -> Item {
        guard let id = anyID(value)?.lowercased() else { throw ServiceError.input("Nothing was changed: give the registration's ID exactly as devices lists it.") }
        switch try await registration(id, service) {
        case .present(let found): return found
        case .absent: throw ServiceError.input("Nothing was changed: Cloudflare lists no WARP registration \(id), revoked ones included.")
        case .inconclusive(let why): throw ServiceError.input("Nothing was changed: registration \(id) could not be read whole first (\(why)).")
        }
    }

    /// Whether a registration is revoked: true, false, or nil when Cloudflare does not say.
    static func revoked(_ registration: Item) -> Bool? {
        if registration.text("revoked_at") != nil { return true }
        return registration.fields["revoked_at"] == .null ? false : nil
    }

    struct ContainmentDevice: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "device"
        static let summary = "A WARP device registration's state before acting, by its registration ID: the device, its user, whether it is revoked or deleted and when last seen. It changes nothing."
        static let input = JSONSchema.object(["id": .string("The registration's ID, as Cloudflare Audit's devices gives it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let registration = try await Cloudflare.targetRegistration(input.id, service)
            let state = Cloudflare.revoked(registration).map { $0 ? "revoked" : "not revoked" } ?? "whether revoked not given, so unknown"
            struct Kept: Encodable { let id: String; let device: String?; let user: String?; let state: String }
            return try ServiceResult(text: Cloudflare.registrationLine(registration) + "\nRead at \(Cloudflare.iso(Date())).",
                                     structured: Kept(id: registration.id, device: registration.text("device.id"), user: registration.text("user.email"), state: state))
        }
    }

    struct RevokeDevice: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "revoke-device"
        static let recovery = "Recovery: unrevoke the registration, or have its user enrol the device in WARP again, in the Zero Trust dashboard (Team & Resources › Devices, or My Team › Devices); Pion offers no unrevoke, as it cannot verify who revoked a registration. Until then the device reaches nothing Zero Trust protects through it, and Gateway no longer filters it."
        static let summary = "Revoke one WARP device registration, by its ID, so the device can no longer reach Access applications or private networks through WARP. Reports the registration's state read after the request, which confirms the state, not who changed it. \(recovery)"
        static let input = JSONSchema.object(["id": .string("The registration's ID, as Cloudflare Audit's devices gives it.")], required: ["id"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Cloudflare.targetRegistration(input.id, service)
            let id = target.id
            var notes: [String] = []
            switch Cloudflare.revoked(target) {
            case true?: throw ServiceError.input("Nothing was changed: registration \(id) is already revoked, at \(target.text("revoked_at") ?? "a time not given").")
            case nil: notes.append("Cloudflare did not say whether it was revoked before, so whether it already was could not be confirmed.")
            case false?: break
            }
            let path = ["accounts", try Cloudflare.account(service), "devices", "registrations", "revoke"]
            let request = Cloudflare.requested("POST", path, "with id \(id)")
            let (_, problem) = try await Cloudflare.change(service, path, method: "POST", body: nil, query: ["id": id], need: Cloudflare.editZeroTrustNeed)
            if let problem {
                throw ServiceError.input("The request to revoke registration \(id) could not be verified: \(problem). It is not reported done; read it with device.\n\(request)\n\(Self.recovery)")
            }
            var now: Bool?, unread: String?, confirmed: Item?
            for pause in Cloudflare.pauses {
                await Cloudflare.pause(pause)
                switch try? await Cloudflare.registration(id, service) {
                case .present(let found)?: now = Cloudflare.revoked(found); unread = nil; confirmed = found
                case .absent?: unread = "Cloudflare no longer lists the registration"
                case .inconclusive(let why)?: unread = why
                case nil: unread = "reading it again failed"
                }
                if now == true { break }
            }
            guard now == true else {
                let why = unread ?? "read again, it is \(now.map { $0 ? "revoked" : "not revoked" } ?? "of a state not given")"
                throw ServiceError.input("Cloudflare accepted the request to revoke registration \(id), but its answer names no registration and it could not be confirmed: \(why). It is not reported done; read it with device.\n\(request)\n\(Self.recovery)")
            }
            let at = confirmed?.text("revoked_at") ?? "a time not given"
            var lines = ["Revoked WARP registration \(id) (\(target.text("device.name") ?? "an unnamed device"), user \(target.text("user.email") ?? "not given")): read again, it is revoked at \(at) — this confirms the state, not who changed it."]
            lines += notes
            lines.append(Self.recovery)
            struct Kept: Encodable { let registration: String; let revoked: Bool; let revokedAt: String?; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(registration: id, revoked: true, revokedAt: confirmed?.text("revoked_at"), done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - Following up, and access

extension Cloudflare {
    struct ActionStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let ruleId: String?, blocked: String?, zone: String?, gatewayValue: String?, user: String?, device: String? }
        static let name = "action-status"
        static let summary = "Where an action stands: every IP Access rule for an address, range, network (AS number) or country, or one rule Pion made by its ID, and whether Pion's record says it made each; whether Pion's Gateway list holds a value and its rule blocks it; a user's active Access sessions; or a WARP registration's state. It changes nothing."
        static let input = JSONSchema.object([
            "ruleId": .string("An IP Access rule's ID, as a block gave it."),
            "blocked": .string("An IP address or range, AS number (AS64500) or two-letter country code, to read every rule for it."),
            "zone": .string("With blocked: read that zone's rules, which include the account's, rather than the account's."),
            "gatewayValue": .string("A domain or IP address, to read whether Pion's Gateway list holds it."),
            "user": .string("A user's email address or ID, to read their sessions."),
            "device": .string("A WARP registration's ID."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var lines: [String] = []
            func ours(_ id: String) -> Bool { (try? Cloudflare.owned(service) { $0.kind == "ip-access-rule" && $0.id == id }) != nil }
            if let raw = input.ruleId {
                guard let id = Cloudflare.hex32(raw) else { throw ServiceError.input("Give the rule's ID: 32 hexadecimal characters.") }
                guard let record = try Cloudflare.owned(service, where: { $0.kind == "ip-access-rule" && $0.id == id }), let target = record.made["target"], let value = record.made["value"] else {
                    throw ServiceError.input("Pion has no record of making rule \(id) through this connection; give blocked with what it blocks to read every rule for it.")
                }
                let scope = try Cloudflare.ruleScope(recorded: record.scope, service)
                switch await Cloudflare.rule(id, in: scope, service) {
                case .present(let rule):
                    let changed = Cloudflare.differences(record.made, Cloudflare.ruleSnapshot(rule), required: Cloudflare.ruleRequired)
                    lines.append(Cloudflare.ruleLine(rule) + " — Pion's record says it made this one" + (changed.isEmpty ? ", and it is as made." : "; it is not as made: \(changed.joined(separator: "; ")).") )
                case .absent: lines.append("Rule \(id) (\(target) \(value)) is no longer listed in \(scope.said): every rule there was read.")
                case .inconclusive(let why): lines.append("Whether rule \(id) is still there could not be told: \(why).")
                }
            } else if let raw = input.blocked {
                let target: Target
                if let ip = try? Cloudflare.ipTarget(raw) { target = ip }
                else if let asn = try? Cloudflare.asnTarget(raw), raw.uppercased().hasPrefix("AS") || raw.allSatisfy(\.isNumber) { target = asn }
                else { target = try Cloudflare.countryTarget(raw) }
                let scope = try await Cloudflare.ruleScope(input.zone, service)
                let rules = try await Cloudflare.rules(for: target, in: scope, service)
                lines.append(rules.isEmpty ? "No IP Access rule in \(scope.said) holds \(target.value); every rule for it was read. A range, network or country rule covering it is not counted."
                             : rules.map { Cloudflare.ruleLine($0) + (ours($0.id) ? " — Pion's record says it made this one through this connection" : " — Pion has no record of making this one") }.joined(separator: "\n"))
            } else if let raw = input.gatewayValue {
                let (kind, value) = try Cloudflare.gatewayValue(raw)
                if let (record, items) = try await Cloudflare.ownList(kind, service) {
                    let state = await Cloudflare.ruleState(kind, list: record.id, service)
                    let recorded = (try? Cloudflare.owned(service) { $0.kind == "gateway-item" && $0.label == value }) != nil
                    lines.append(items.contains(where: { $0.value == value }) ? "Pion's \(kind.label) list \(record.id), read whole, holds \(value)\(recorded ? ", which Pion's record says it added" : ", which Pion has no record of adding")." : "Pion's \(kind.label) list \(record.id), read whole, does not hold \(value).")
                    lines.append("\(state.said).")
                } else { lines.append("Pion has no \(kind.label) list in Gateway for this connection, so it blocks nothing there; gateway-lists in Cloudflare Audit reads every list.") }
            } else if let raw = input.user {
                let user = try await Cloudflare.targetUser(raw, service)
                let sessions = try await Cloudflare.sessions(user.id, service, need: Cloudflare.editZeroTrustNeed)
                lines.append(Cloudflare.userLine(user))
                lines.append(sessions.value.isEmpty ? "No active Access session, per a whole read." : "\(Cloudflare.plural(sessions.value.count, "active Access session")):\n" + sessions.value.map(Cloudflare.sessionLine).joined(separator: "\n"))
            } else if let raw = input.device {
                lines.append(Cloudflare.registrationLine(try await Cloudflare.targetRegistration(raw, service)))
            } else {
                throw ServiceError.input("Give a rule's ID, what was blocked, a Gateway value, a user, or a device registration.")
            }
            lines.append("Read at \(Cloudflare.iso(Date())).")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["lines": lines])
        }
    }

    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let summary = "Verifies the token with Cloudflare (whose it is, whether active, when it expires), lists its own permissions when it may read them, tries what the actions read first (the account's IP Access rules, Gateway lists and rules, WARP registrations and Access users), and says what it reaches. It sends only reads, so the actions' edit permissions are verified only when the token's own record lists them."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try Cloudflare.api(service)
            let account = try Cloudflare.account(service)
            var lines = ["· Account \(account), reached at https://\(Cloudflare.host)\(Cloudflare.basePath) and nowhere else."]
            let (token, said) = await Cloudflare.verify(service)
            lines += said
            var proven: [String] = []
            if let token {
                if let names = await Cloudflare.ownPermissions(service, token) {
                    lines.append("· Its own record lists: \(names.joined(separator: ", ")).")
                    let wanted = ["Account Firewall Access Rules Write", "Account Firewall Access Rules Edit", "Zero Trust Write", "Zero Trust Edit", "Firewall Services Write", "Firewall Services Edit"]
                    proven = Cloudflare.containmentPermissions.filter { permission in
                        let group = permission.split(separator: "›").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                        return names.contains("\(group) Write") || names.contains("\(group) Edit")
                    }
                    let extra = names.filter { Cloudflare.changes($0) && !wanted.contains($0) }
                    if !extra.isEmpty { lines.append("⚠ It also holds \(extra.joined(separator: ", ")), which Containment does not use: remove them in the dashboard.") }
                } else {
                    lines.append("· Its own permissions could not be read (that needs Account API Tokens › Read, which Containment does not ask for).")
                }
            }
            lines.append(await Cloudflare.probe(Cloudflare.accountRulesNeed, required: true) {
                _ = try await Cloudflare.list(service, ["accounts", account, "firewall", "access_rules", "rules"], query: [:], as: Item.self, size: 1, pages: 1)
            }.line)
            lines.append(await Cloudflare.probe(Need(title: "Gateway lists and rules", permission: "Account › Zero Trust › Edit", zeroTrust: true), required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "gateway", "lists"], query: [:], as: Item.self, paging: .single, size: 0)
            }.line)
            lines.append(await Cloudflare.probe(Need(title: "WARP registrations", permission: "Account › Zero Trust › Edit", zeroTrust: true), required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "devices", "registrations"], query: ["status": "all"], as: Item.self, paging: .cursor, size: 1, pages: 1)
            }.line)
            lines.append(await Cloudflare.probe(Need(title: "Access users", permission: "Account › Zero Trust › Edit", zeroTrust: true), required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "access", "users"], query: [:], as: Item.self, size: 1, pages: 1)
            }.line)
            let unproven = Cloudflare.containmentPermissions.filter { !proven.contains($0) }
            if !proven.isEmpty { lines.append("✓ Its own record shows \(proven.joined(separator: " and ")), which the actions take.") }
            if !unproven.isEmpty {
                lines.append("· Not verified: \(unproven.joined(separator: ", ")). Reads above succeed with Read as well as Edit, and check-access sends no change; an action refused for want of one says which.")
            }
            lines.append("· Blocking in one zone also takes \(Cloudflare.containmentZonePermissions.joined(separator: " and ")) for that zone, tried only when an action names one.")
            lines.append("· Pion Containment's token should hold only \(Cloudflare.containmentPermissions.joined(separator: " and ")), plus the zone permissions to block in one zone.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}

extension String {
    /// Nil for an empty string.
    fileprivate var nilIfBlank: String? { isEmpty ? nil : self }
}
