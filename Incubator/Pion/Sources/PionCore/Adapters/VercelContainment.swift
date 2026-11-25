import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// Vercel Containment: responding in one team, with a token of its own whose member holds only the role its actions take,
/// kept apart from Detection's so the detection member stays a Viewer. Every action waits for the champion's approval,
/// and each says what recovering from it involves.
///
/// Pion reads what it acts on first and refuses what is already as asked. It removes only the firewall rules it made: a
/// rule is Pion's only by Pion's own record of what it made, bound to the connection, the team and the project, and kept
/// with what Vercel said it made, which must still hold before Pion removes it. A change is confirmed only when a read
/// afterwards shows it; anything else is reported unverified, with the request's details.
///
/// Revoking another member's access token is left out: Vercel's API deletes only the calling user's own tokens, so
/// removing the member, or the member deleting the token in their own Account Settings, is the way to end one.
extension Vercel {
    public static let containment = ToolDefinition(
        id: "86d8bbe6-e36d-4019-abb6-c23f305a1b18", name: "Vercel Containment",
        summary: "Turn on Attack Challenge Mode or deployment protection, block an IP address, network or country with a firewall rule and remove it, remove a team member, and roll production back to an earlier deployment, in Vercel.",
        defaultInstructions: """
        Use Vercel Containment to respond in a Vercel team. Find the target with Vercel Detection first, then read it \\
        here with project and record it as evidence before acting. enable-attack-mode challenges every visitor to a \\
        project with Vercel's browser check, for a time or until disable-attack-mode; block-ip, block-asn and \\
        block-country add a Vercel Firewall rule to a project that denies an address or range, a network or a country, \\
        and give its ID; Pion keeps a record of each rule it makes, and unblock removes one by that ID only if the \\
        record says Pion made it and Vercel still holds it as made. enable-protection turns on Vercel Authentication \\
        for a project's deployments, so only team members signed in to Vercel reach them. remove-member removes a \\
        member from the team, cutting off everything they reach through it, their tokens included; Vercel lets only an \\
        Owner do it. rollback makes an earlier production deployment of a project serve its production domains again. \\
        All of these are held for the champion's approval: give the exact target, and in --approval-reason why, the \\
        expected effect and how to undo it, with the Investigation as --approval-conversation. project and \\
        check-access read without approval. Pion refuses a malformed value, a target it cannot read first, one already \\
        as asked, and a rule it has no record of making. A result Pion could not verify is never reported done and \\
        keeps the request's details. Vercel cannot revoke another member's token through its API: remove the member, or \\
        ask them to delete it. Run check-access when something is refused, and tell the champion exactly what it says \\
        to change.
        """,
        iconName: "vercel",
        configuration: .connection(.init(endpointTemplate: "https://api.vercel.com", fields: [teamField],
                                         tokenHeader: "Authorization", tokenScheme: "Bearer", adapter: "vercel-containment")),
        setup: containmentSetup)

    static let containmentSetup = [
        tokenCaveat,
        "Invite a member for Pion Containment alone, such as pion-containment@example.com, under the team's **Settings › Members**, with the **Member** role, which can turn on Attack Challenge Mode, change projects' firewall rules and deployment protection and roll production back. Only an **Owner** can remove members, so remove-member is refused for a Member; give this member Owner only if agents should remove members, knowing it can then change everything in the team.",
        "Signed in as that member, open **Account Settings › Tokens**, create a token named Pion Containment, set its **Scope** to this team only, not Full Account, and give it an **Expiration**; give it here. Pion sends it as `Authorization: Bearer <token>`, only to api.vercel.com.",
        teamStep,
    ]

    public static let containmentAdapter = OperationAdapter(operations: operations, job: .containment, simultaneousRequests: 2)

    // MARK: What it needs

    static let firewallEditNeed = Need(title: "The project's firewall", role: "Member")
    static let projectEditNeed = Need(title: "The project's settings", role: "Member")
    static let rollbackNeed = Need(title: "Rolling back production", role: "Member (a Developer may roll back too)")
    static let removeMemberNeed = Need(title: "Removing a team member", role: "Owner")

    /// How long to wait between a change and reading it back.
    @TaskLocal static var pauses: [Double] = [1, 2, 3]
    @TaskLocal static var pause: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    static let notePrefix = "Pion, after the champion's approval: "

    /// A reason as Vercel keeps it beside what Pion made, for people reading the dashboard: one line, up to 200
    /// characters.
    static func approvalNote(_ value: String) throws -> String {
        let words = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (3...200).contains(words.count) else { throw ServiceError.input("Nothing was changed: give a reason of up to 200 characters saying why, as the approval request does.") }
        return notePrefix + words
    }

    /// What a change's request was, for a result that could not be verified.
    static func requested(_ method: String, _ path: [String], _ details: String) -> String {
        "Request: \(method) /\(path.joined(separator: "/")) \(details)."
    }

    /// A change, sent once, through `need`'s refusals; Vercel's answer, when it gave one, as a value.
    static func change(_ service: ServiceClient, _ path: [String], method: String, query: [String: String?] = [:], body: Data?, need: Need) async throws -> Value? {
        let answer = try await read(need) { try await exchange(service, path, query: query, method: method, body: body) }
        return answer.data.isEmpty ? nil : try? JSONDecoder().decode(Value.self, from: answer.data)
    }

    /// Reads `read` after each pause until `done` holds, and gives the last value read, or the last failure.
    static func readBack<Result>(_ read: () async throws -> Result, until done: (Result) -> Bool) async -> (value: Result?, error: Error?) {
        var last: Result?, failure: Error?
        for wait in pauses {
            await pause(wait)
            do {
                let value = try await read()
                last = value
                failure = nil
                if done(value) { break }
            } catch { failure = error }
        }
        return (last, failure)
    }
}

// MARK: - Pion's record of what it made

extension Vercel {
    /// A firewall rule Containment made: its ID, project, what it blocks, and what Vercel said it made, field by field,
    /// which must still hold before Pion removes it.
    struct Owned: Codable, Equatable, Sendable {
        let kind: String
        let id: String
        let project: String
        let label: String
        let created: Date
        let made: [String: String]
    }

    struct Book: Sendable {
        var file: URL? = nil
        var records: [String: [Owned]] = [:]
    }
    static let book = Mutex(Book())

    /// Keeps Pion's record of the firewall rules Vercel Containment made in `file`, reading what it already holds; nil
    /// keeps it in memory.
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
        return "\(connection.uuidString.lowercased())@\(try team(service).value)"
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
}

// MARK: - Reading a project before acting

extension Vercel {
    /// A project's ID, read whole first, so an action names exactly one project.
    static func targetProject(_ value: String, _ service: ServiceClient) async throws -> (id: String, project: Value) {
        let project: Value
        do { project = try await Vercel.project(value, service, need: projectEditNeed) }
        catch let error as ServiceError { throw ServiceError.input("Nothing was changed: \(error.localizedDescription)") }
        guard let id = project.text("id") else { throw ServiceError.input("Nothing was changed: Vercel's answer for \(value) gave no project ID.") }
        return (try Vercel.id(id, "the project"), project)
    }

    struct ContainmentProject: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String }
        static let name = "project"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "A project's state before acting, by name or ID: its deployment protection, whether Attack Challenge Mode is on and until when, its current and recent production deployments, its firewall's custom rules, and which of them Pion's record says it made. It changes nothing."
        static let input = JSONSchema.object(["project": .string("The project's name or ID.")], required: ["project"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (id, project) = try await Vercel.targetProject(input.project, service)
            var lines = ["\(Vercel.projectName(project))", Protection(project).line]
            let attack = project.flag("security.attackModeEnabled")
            lines.append("Attack Challenge Mode: \(attack.map { $0 ? "ON" : "off" } ?? "not given")\(project.time("security.attackModeActiveUntil").map { ", until \($0)" } ?? "")")
            lines.append("Production now: \(project.text("targets.production.id") ?? "not given")\(project.text("targets.production.url").map { " https://\($0)" } ?? "")")
            do {
                let recent = try await Vercel.list(service, ["v7", "deployments"], key: "deployments", query: ["projectId": id, "target": "production"], size: 10, pages: 1)
                lines.append("Recent production deployments, newest first:\n" + recent.value.map { "  " + Deployment($0).line }.joined(separator: "\n"))
            } catch { lines.append("Recent production deployments could not be read: \(error.localizedDescription)") }
            do {
                let config = try await Vercel.firewall(id, service, need: Vercel.firewallEditNeed)
                let rules = config["rules"]?.items ?? []
                lines.append("Firewall \(config.flag("firewallEnabled").map { $0 ? "on" : "OFF" } ?? "state not given"), \(Vercel.plural(rules.count, "custom rule"))"
                             + rules.map { rule in
                                 let ours = rule.text("id").flatMap { ruleID in try? Vercel.owned(service) { $0.id == ruleID && $0.project == id } } != nil
                                 return "\n  " + Vercel.ruleLine(rule) + (ours ? " — Pion made this one" : "")
                             }.joined())
            } catch ServiceError.notFound {
                lines.append("No firewall configuration has been saved for this project.")
            } catch { lines.append("The firewall could not be read: \(error.localizedDescription)") }
            lines.append("Read at \(Vercel.iso(Date())).")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["project": id, "state": lines.joined(separator: "\n")])
        }
    }
}

// MARK: - Attack Challenge Mode

extension Vercel {
    static func attackMode(_ projectInput: String, on enabled: Bool, hours: Int?, _ service: ServiceClient) async throws -> ServiceResult {
        let recovery = enabled
            ? "Recovery: disable-attack-mode turns it off at once; until then every visitor must pass Vercel's browser check, so scripts, API clients and webhooks that cannot are turned away."
            : "Recovery: enable-attack-mode turns it on again."
        let (id, project) = try await targetProject(projectInput, service)
        if let now = project.flag("security.attackModeEnabled"), now == enabled {
            throw ServiceError.input("Nothing was changed: Attack Challenge Mode is already \(enabled ? "on" : "off") for \(projectName(project)).")
        }
        let until = hours.map { Date().addingTimeInterval(Double($0) * 3_600) }
        var body: [String: Any] = ["projectId": id, "attackModeEnabled": enabled]
        if let until { body["attackModeActiveUntil"] = Int64(until.timeIntervalSince1970 * 1_000) }
        let path = ["v1", "security", "attack-mode"]
        let request = requested("POST", path, "for \(projectName(project)), attackModeEnabled \(enabled)\(until.map { " until \(iso($0))" } ?? "")")
        do { _ = try await change(service, path, method: "POST", body: try json(body), need: firewallEditNeed) }
        catch { throw ServiceError.input("Vercel refused to turn Attack Challenge Mode \(enabled ? "on" : "off") for \(projectName(project)): \(error.localizedDescription)\n\(request)") }
        let (read, error) = await readBack({ try await Vercel.project(id, service, need: projectEditNeed) }, until: { $0.flag("security.attackModeEnabled") == enabled })
        guard read?.flag("security.attackModeEnabled") == enabled else {
            let why = error.map { "reading the project back: \($0.localizedDescription)" } ?? "read back, the project gives Attack Challenge Mode as \(read?.flag("security.attackModeEnabled").map { $0 ? "on" : "off" } ?? "not given")"
            throw ServiceError.input("Vercel accepted the request, but whether Attack Challenge Mode is \(enabled ? "on" : "off") could not be verified: \(why). It is not reported done; read it with project.\n\(request)\n\(recovery)")
        }
        let text = "Attack Challenge Mode is \(enabled ? "on" : "off") for \(projectName(project)), read back as asked\(until.map { ", until \(iso($0))" } ?? "").\n\(recovery)"
        struct Kept: Encodable { let project: String; let attackMode: Bool; let until: String?; let done: Bool; let recovery: String }
        return try ServiceResult(text: text, structured: Kept(project: id, attackMode: enabled, until: until.map(iso), done: true, recovery: recovery))
    }

    struct EnableAttackMode: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String; let hours: Int? }
        static let name = "enable-attack-mode"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Turn on Attack Challenge Mode for a project, so every visitor must pass Vercel's browser check before reaching it, for a number of hours or until turned off. Scripts, API clients and webhooks that cannot pass it are turned away meanwhile. Recovery: disable-attack-mode."
        static let input = JSONSchema.object(["project": .string("The project's name or ID."),
                                              "hours": .integer("How many hours it stays on. Until disable-attack-mode when left out.", minimum: 1, maximum: 168)],
                                             required: ["project"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            if let hours = input.hours, !(1...168).contains(hours) { throw ServiceError.input("Nothing was changed: give between 1 and 168 hours.") }
            return try await Vercel.attackMode(input.project, on: true, hours: input.hours, service)
        }
    }

    struct DisableAttackMode: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String }
        static let name = "disable-attack-mode"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Turn Attack Challenge Mode off for a project, letting every visitor through without Vercel's browser check again. Held, as it lifts a protection. Recovery: enable-attack-mode."
        static let input = JSONSchema.object(["project": .string("The project's name or ID.")], required: ["project"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await Vercel.attackMode(input.project, on: false, hours: nil, service)
        }
    }
}

// MARK: - Firewall rules

extension Vercel {
    /// What a rule blocks: Vercel's condition type and value.
    struct Target: Sendable, Equatable {
        let type: String
        let value: String
        var said: String {
            switch type {
            case "ip_address": value.contains("/") ? "the range \(value)" : "the address \(value)"
            case "geo_as_number": "the network AS\(value)"
            default: "the country \(value)"
            }
        }
    }

    /// An IPv4 or IPv6 address, or a CIDR range of one, in canonical form.
    static func ipTarget(_ raw: String) throws -> Target {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        func text(_ buffer: [CChar]) -> String { String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        let canonical: (text: String, v6: Bool)?
        if (1...2).contains(parts.count), inet_pton(AF_INET, parts[0], &v4) == 1, inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil {
            canonical = (text(buffer), false)
        } else if (1...2).contains(parts.count), inet_pton(AF_INET6, parts[0], &v6) == 1, inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil {
            canonical = (text(buffer), true)
        } else { canonical = nil }
        guard let canonical else { throw ServiceError.input("Nothing was changed: \"\(value)\" is not an IPv4 or IPv6 address or range.") }
        guard parts.count == 2 else { return Target(type: "ip_address", value: canonical.text) }
        let widest = canonical.v6 ? 32 : 8, narrowest = canonical.v6 ? 128 : 32
        guard let prefix = Int(parts[1]), (widest...narrowest).contains(prefix) else {
            throw ServiceError.input("Nothing was changed: give a range of /\(widest) to /\(narrowest) for \(canonical.v6 ? "IPv6" : "IPv4"); a wider one would block far more than an attacker.")
        }
        return Target(type: "ip_address", value: "\(canonical.text)/\(prefix)")
    }

    static func asnTarget(_ raw: String) throws -> Target {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("AS") { value.removeFirst(2) }
        guard let number = UInt32(value), number > 0 else { throw ServiceError.input("Nothing was changed: give the network's AS number, such as AS64500 or 64500.") }
        return Target(type: "geo_as_number", value: String(number))
    }

    static func countryTarget(_ raw: String) throws -> Target {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 2, value.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw ServiceError.input("Nothing was changed: give the country as its two-letter ISO 3166-1 code, such as RU.")
        }
        return Target(type: "geo_country", value: value)
    }

    /// What Pion keeps of a rule to tell later whether it changed: its name, whether it is on, its action and its one
    /// condition.
    static func ruleSnapshot(_ rule: Value) -> [String: String] {
        var snapshot: [String: String] = [:]
        snapshot["name"] = rule.text("name")
        snapshot["active"] = rule.flag("active").map { String($0) }
        snapshot["action"] = rule.text("action.mitigate.action")
        let conditions = (rule["conditionGroup"]?.items ?? []).flatMap { $0["conditions"]?.items ?? [] }
        if conditions.count == 1, let condition = conditions.first {
            snapshot["type"] = condition.text("type")
            snapshot["op"] = condition.text("op")
            snapshot["value"] = condition["value"]?.texts.joined(separator: ",")
            snapshot["neg"] = condition.flag("neg").map { String($0) } ?? "false"
        } else {
            snapshot["conditions"] = String(conditions.count)
        }
        return snapshot
    }

    static func differences(_ made: [String: String], _ now: [String: String]) -> [String] {
        Set(made.keys).union(now.keys).sorted().compactMap { key in
            made[key] == now[key] ? nil : "\(key) \(made[key] ?? "not given") is now \(now[key] ?? "not given")"
        }
    }

    /// The custom rules of a project's active firewall, or none when no configuration was ever saved.
    static func rules(_ projectID: String, _ service: ServiceClient) async throws -> [Value] {
        do { return try await firewall(projectID, service, need: firewallEditNeed)["rules"]?.items ?? [] }
        catch ServiceError.notFound { return [] }
    }

    /// What tells a rule Pion makes from any other of the same target, so it is found by its name alone; tests give
    /// their own.
    @TaskLocal static var ruleSuffix: @Sendable () -> String = { String(UUID().uuidString.prefix(8).lowercased()) }

    static let blockRecovery = "Recovery: unblock with the rule's ID removes it, which lets that traffic reach the project again at once; requests denied meanwhile are not replayed."

    /// Refuses a target any rule of the project already denies by the same single condition, adds a rule that denies
    /// it, finds it by its name in the active firewall, and keeps Pion's record of it.
    static func block(_ target: Target, project projectInput: String, reason raw: String, on service: ServiceClient) async throws -> ServiceResult {
        let note = try approvalNote(raw)
        _ = try recordKey(service)
        let (projectID, project) = try await targetProject(projectInput, service)
        let existing = try await rules(projectID, service)
        if let held = existing.first(where: { let shot = ruleSnapshot($0); return shot["type"] == target.type && shot["value"] == target.value && shot["neg"] == "false" }) {
            throw ServiceError.input("Nothing was changed: a firewall rule of \(projectName(project)) already matches \(target.value): \(ruleLine(held)).")
        }
        let name = "Pion block \(target.type == "geo_as_number" ? "AS" : "")\(target.value) \(ruleSuffix())"
        let rule: [String: Any] = [
            "name": name, "description": note, "active": true,
            "conditionGroup": [["conditions": [["type": target.type, "op": "eq", "value": target.value]]]],
            "action": ["mitigate": ["action": "deny", "rateLimit": NSNull(), "redirect": NSNull(), "actionDuration": NSNull()]],
        ]
        let path = ["v1", "security", "firewall", "config"]
        let request = requested("PATCH", path, "rules.insert for \(projectName(project)), denying \(target.type) \(target.value) as \"\(name)\"")
        let noRecord = "Pion kept no record of it, so unblock cannot remove it: read it with project, and remove it in the dashboard's Firewall if it was made and should go."
        do { _ = try await change(service, path, method: "PATCH", query: ["projectId": projectID], body: try json(["action": "rules.insert", "id": NSNull(), "value": rule]), need: firewallEditNeed) }
        catch { throw ServiceError.input("Vercel refused to add the rule blocking \(target.said): \(error.localizedDescription)\n\(request)") }
        let (read, error) = await readBack({ try await Vercel.rules(projectID, service) }, until: { $0.contains { $0.text("name") == name } })
        let named = (read ?? []).filter { $0.text("name") == name }
        guard named.count == 1, let made = named.first, let ruleID = made.text("id") else {
            let why = error.map { "reading the firewall back: \($0.localizedDescription)" } ?? (named.isEmpty ? "the active firewall holds no rule named \(name)" : "the active firewall holds \(named.count) rules named \(name)")
            throw ServiceError.input("Vercel accepted the request to block \(target.said), but it could not be verified: \(why). It is not reported done. \(noRecord)\n\(request)\n\(blockRecovery)")
        }
        let snapshot = ruleSnapshot(made)
        let expected = ["name": name, "active": "true", "action": "deny", "type": target.type, "op": "eq", "value": target.value, "neg": "false"]
        let mismatch = differences(expected, snapshot)
        guard mismatch.isEmpty else {
            throw ServiceError.input("Vercel made rule \(ruleID), but not as asked (\(mismatch.joined(separator: "; "))), so it is not reported done. \(noRecord)\n\(request)\n\(blockRecovery)")
        }
        do {
            try changeOwned(service) { records in
                records.removeAll { $0.id == ruleID && $0.project == projectID }
                records.append(Owned(kind: "firewall-rule", id: ruleID, project: projectID, label: "\(target.type) \(target.value)", created: Date(), made: snapshot))
            }
        } catch {
            throw ServiceError.input("Vercel made rule \(ruleID) blocking \(target.said), but Pion could not keep its record of it (\(error.localizedDescription)), so unblock cannot remove it: remove it in the dashboard's Firewall when it should go.\n\(request)")
        }
        let text = "Vercel made firewall rule \(ruleID) in \(projectName(project)): \(target.said) denied, read back as made. Pion keeps a record that it made it, which unblock needs.\n"
            + "Only rules with exactly this one condition were checked first: a broader rule, or one that lets traffic through earlier, was not. The firewall must be on for the rule to apply: project says whether it is.\n\(blockRecovery)"
        struct Kept: Encodable { let id: String; let project: String; let type: String; let value: String; let done: Bool; let recovery: String }
        return try ServiceResult(text: text, structured: Kept(id: ruleID, project: projectID, type: target.type, value: target.value, done: true, recovery: blockRecovery))
    }

    static let projectField = JSONSchema.string("The project's name or ID.")
    static let reasonField = JSONSchema.string("Why: the reason given in the approval request, with the Investigation. Kept as the rule's description.")

    struct BlockIP: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String; let ip: String; let reason: String }
        static let name = "block-ip"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Deny an IP address or CIDR range from reaching a project, with a Vercel Firewall custom rule, and keep a record that Pion made it, which unblock needs. Refused when a rule with that one condition already exists. \(Vercel.blockRecovery)"
        static let input = JSONSchema.object(["project": Vercel.projectField, "ip": .string("The IPv4 or IPv6 address, or CIDR range."), "reason": Vercel.reasonField],
                                             required: ["project", "ip", "reason"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await Vercel.block(try Vercel.ipTarget(input.ip), project: input.project, reason: input.reason, on: service)
        }
    }

    struct BlockASN: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String; let asn: String; let reason: String }
        static let name = "block-asn"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Deny a whole network, by its AS number, from reaching a project, with a Vercel Firewall custom rule, and keep a record that Pion made it. A network carries everyone it serves, customers included, so prefer block-ip unless the network itself is hostile. \(Vercel.blockRecovery)"
        static let input = JSONSchema.object(["project": Vercel.projectField, "asn": .string("The AS number, such as AS64500."), "reason": Vercel.reasonField],
                                             required: ["project", "asn", "reason"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await Vercel.block(try Vercel.asnTarget(input.asn), project: input.project, reason: input.reason, on: service)
        }
    }

    struct BlockCountry: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String; let country: String; let reason: String }
        static let name = "block-country"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Deny a whole country from reaching a project, with a Vercel Firewall custom rule, and keep a record that Pion made it. Everyone there is cut off, travelling staff and customers included. \(Vercel.blockRecovery)"
        static let input = JSONSchema.object(["project": Vercel.projectField, "country": .string("The two-letter ISO 3166-1 code, such as RU."), "reason": Vercel.reasonField],
                                             required: ["project", "country", "reason"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await Vercel.block(try Vercel.countryTarget(input.country), project: input.project, reason: input.reason, on: service)
        }
    }

    struct Unblock: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "unblock"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: block-ip, block-asn or block-country again restores the block. Removing it lets that traffic reach the project again at once."
        static let summary = "Remove one Vercel Firewall rule, by its ID, that Pion's own record says block-ip, block-asn or block-country made through this connection, and that Vercel still holds as made; any other is left in place, whatever its name says. Held, as it lifts a block. \(recovery)"
        static let input = JSONSchema.object(["id": .string("The rule's ID, as the block gave it.")], required: ["id"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try Vercel.id(input.id, "the rule's ID")
            guard let record = try Vercel.owned(service, where: { $0.kind == "firewall-rule" && $0.id == id }) else {
                throw ServiceError.input("Nothing was changed: Pion has no record of making firewall rule \(id) through this connection, so it leaves it in place, whatever its name says. Remove it in the dashboard's Firewall if it should go.")
            }
            let rules: [Value]
            do { rules = try await Vercel.rules(record.project, service) }
            catch { throw ServiceError.input("Nothing was changed: the firewall of project \(record.project) could not be read first (\(error.localizedDescription)), so rule \(id) is left in place, and Pion keeps its record.") }
            let held = rules.filter { $0.text("id") == id }
            guard let rule = held.first else {
                try? Vercel.changeOwned(service) { $0.removeAll { $0.id == id && $0.project == record.project } }
                throw ServiceError.input("Nothing was changed: project \(record.project)'s firewall holds no rule \(id), so there is nothing to remove; Pion drops its record of it.")
            }
            guard held.count == 1 else { throw ServiceError.input("Nothing was changed: Vercel lists rule \(id) \(held.count) times, so which one is meant cannot be told.") }
            let changed = Vercel.differences(record.made, Vercel.ruleSnapshot(rule))
            guard changed.isEmpty else {
                throw ServiceError.input("Nothing was changed: rule \(id) has changed since Pion made it: \(changed.joined(separator: "; ")). Someone may have changed it, so Pion leaves it in place and keeps its record; remove it in the dashboard if it should go.")
            }
            let path = ["v1", "security", "firewall", "config"]
            let request = Vercel.requested("PATCH", path, "rules.remove of \(id) (\(record.label)) in project \(record.project)")
            do { _ = try await Vercel.change(service, path, method: "PATCH", query: ["projectId": record.project], body: try Vercel.json(["action": "rules.remove", "id": id, "value": NSNull()]), need: Vercel.firewallEditNeed) }
            catch { throw ServiceError.input("Vercel refused to remove rule \(id): \(error.localizedDescription) It is left in place, and Pion keeps its record.\n\(request)") }
            let (read, error) = await Vercel.readBack({ try await Vercel.rules(record.project, service) }, until: { !$0.contains { $0.text("id") == id } })
            guard let read, !read.contains(where: { $0.text("id") == id }) else {
                let why = error.map { "reading the firewall back: \($0.localizedDescription)" } ?? "the firewall still lists it"
                throw ServiceError.input("Vercel accepted the request to remove rule \(id), but whether it is gone is unverified: \(why). It is not reported removed, and Pion keeps its record.\n\(request)\n\(Self.recovery)")
            }
            var lines = ["Removed firewall rule \(id), which denied \(record.label) in project \(record.project) and which Pion made through this connection: the active firewall no longer lists it."]
            do { try Vercel.changeOwned(service) { $0.removeAll { $0.id == id && $0.project == record.project } } }
            catch { lines.append("Pion could not drop its record of it (\(error.localizedDescription)); that changes nothing in Vercel.") }
            lines.append(Self.recovery)
            struct Kept: Encodable { let removed: String; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(removed: id, done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - Deployment protection

extension Vercel {
    /// The deploymentType values Vercel Authentication takes, the most covering first.
    static let protectionTypes = ["all", "all_except_custom_domains", "prod_deployment_urls_and_all_previews", "preview"]

    struct EnableProtection: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String; let deployments: String? }
        static let name = "enable-protection"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: set Vercel Authentication back in the project's Settings › Deployment Protection; the result gives what it was. Until then only team members signed in to Vercel reach the deployments it covers, and links shared with anyone else, such as clients reviewing a preview or CI and preview checks that open deployments, stop working."
        static let summary = "Turn on Vercel Authentication for a project's deployments, so only team members signed in to Vercel reach them: every deployment except production custom domains (Standard Protection, the default), or every deployment, production domains included, which takes the public site offline for everyone else. \(recovery)"
        static let input = JSONSchema.object([
            "project": Vercel.projectField,
            "deployments": .string("Which deployments: all_except_custom_domains (Standard Protection, the default) or all, production domains included.", oneOf: ["all_except_custom_domains", "all"]),
        ], required: ["project"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let wanted = try ServiceInput.oneOf(input.deployments ?? "all_except_custom_domains", ["all_except_custom_domains", "all"], "deployments")
            let (id, project) = try await Vercel.targetProject(input.project, service)
            let before = project["ssoProtection"].flatMap { $0.isNull ? nil : $0.text("deploymentType") }
            if let before, let now = Vercel.protectionTypes.firstIndex(of: before), let asked = Vercel.protectionTypes.firstIndex(of: wanted), now <= asked {
                throw ServiceError.input("Nothing was changed: Vercel Authentication already covers \(Vercel.covers(before)) for \(Vercel.projectName(project)).")
            }
            let path = ["v9", "projects", id]
            let request = Vercel.requested("PATCH", path, "ssoProtection.deploymentType \(wanted), was \(before ?? "off")")
            do { _ = try await Vercel.change(service, path, method: "PATCH", body: try Vercel.json(["ssoProtection": ["deploymentType": wanted]]), need: Vercel.projectEditNeed) }
            catch { throw ServiceError.input("Vercel refused to turn on Vercel Authentication for \(Vercel.projectName(project)): \(error.localizedDescription)\n\(request)") }
            let (read, error) = await Vercel.readBack({ try await Vercel.project(id, service, need: Vercel.projectEditNeed) }, until: { $0.text("ssoProtection.deploymentType") == wanted })
            guard read?.text("ssoProtection.deploymentType") == wanted else {
                let why = error.map { "reading the project back: \($0.localizedDescription)" } ?? "read back, Vercel Authentication covers \(Vercel.covers(read?.text("ssoProtection.deploymentType")))"
                throw ServiceError.input("Vercel accepted the request, but it could not be verified: \(why). It is not reported done; read it with project.\n\(request)\n\(Self.recovery)")
            }
            let text = "Vercel Authentication now covers \(Vercel.covers(wanted)) for \(Vercel.projectName(project)), read back as asked; it covered \(before.map(Vercel.covers) ?? "nothing") before.\n"
                + "Protection bypass secrets, if any, still let automation through: project-protection in Vercel Detection lists them.\n\(Self.recovery)"
            struct Kept: Encodable { let project: String; let deploymentType: String; let before: String?; let done: Bool; let recovery: String }
            return try ServiceResult(text: text, structured: Kept(project: id, deploymentType: wanted, before: before, done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - Members and rollback

extension Vercel {
    /// The user the connection's token belongs to.
    static func me(_ service: ServiceClient) async throws -> Value {
        try api(service)
        let answer = try await service.exchange(["v2", "user"], returning: Set(300...599))
        try check(answer)
        let body: Value = try decode(answer.data)
        guard let user = body["user"], user.text("id") != nil || user.text("uid") != nil else { throw ServiceError.unreadable }
        return user
    }

    struct RemoveMember: ServiceOperation {
        struct Input: Decodable, Sendable { let member: String }
        static let name = "remove-member"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: invite them again under the team's Settings › Members with the role they had; the result gives it. Their access tokens scoped to the team stop working with their membership, and come back only if they make new ones."
        static let summary = "Remove a member from the team, by their email, username or user ID, cutting off everything they reach through it, their tokens for the team included. Vercel lets only an Owner do it. Refused for the token's own user and for the team's last owner. \(recovery)"
        static let input = JSONSchema.object(["member": .string("The member's email address, username or user ID, as members gives it.")], required: ["member"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let wanted = input.member.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard (1...254).contains(wanted.count), !wanted.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw ServiceError.input("Nothing was changed: give the member's email address, username or user ID.")
            }
            let team = try await Vercel.teamID(service)
            let listing = try await Vercel.read(Vercel.membersNeed) {
                try await Vercel.list(service, ["v3", "teams", team, "members"], key: "members", size: 100, pages: 20, partial: false)
            }
            guard listing.complete else { throw ServiceError.input("Nothing was changed: not every member could be read first, so which one is meant could not be told.") }
            let matches = listing.value.filter { member in
                [member.text("uid"), member.text("email"), member.text("username")].compactMap { $0?.lowercased() }.contains(wanted)
            }
            guard matches.count == 1, let member = matches.first, let uid = member.text("uid") else {
                throw ServiceError.input(matches.isEmpty ? "Nothing was changed: the team has no member \(input.member); every member was read." : "Nothing was changed: \(input.member) names \(matches.count) members; give the user ID.")
            }
            let role = member.text("role") ?? "role not given"
            let who = "\(member.text("email") ?? member.text("username") ?? uid) (\(role)) [\(uid)]"
            if let me = try? await Vercel.me(service), [me.text("id"), me.text("uid")].contains(uid) {
                throw ServiceError.input("Nothing was changed: \(who) is the member whose token this connection uses.")
            }
            if role.uppercased() == "OWNER", listing.value.filter({ $0.text("role")?.uppercased() == "OWNER" && $0.flag("confirmed") != false }).count <= 1 {
                throw ServiceError.input("Nothing was changed: \(who) is the team's only owner.")
            }
            let path = ["v1", "teams", team, "members", try Vercel.id(uid, "the member's user ID")]
            let request = Vercel.requested("DELETE", path, "removing \(who)")
            do { _ = try await Vercel.change(service, path, method: "DELETE", body: nil, need: Vercel.removeMemberNeed) }
            catch { throw ServiceError.input("Vercel refused to remove \(who): \(error.localizedDescription)\n\(request)") }
            let (read, error) = await Vercel.readBack({
                try await Vercel.list(service, ["v3", "teams", team, "members"], key: "members", size: 100, pages: 20, partial: false)
            }, until: { listing in listing.complete && !listing.value.contains { $0.text("uid") == uid } })
            guard let read, read.complete, !read.value.contains(where: { $0.text("uid") == uid }) else {
                let why = error.map { "reading the members back: \($0.localizedDescription)" } ?? (read?.complete == false ? "not every member could be read back" : "the team still lists them")
                throw ServiceError.input("Vercel accepted the request to remove \(who), but it could not be verified: \(why). It is not reported done.\n\(request)\n\(Self.recovery)")
            }
            let text = "Removed \(who) from the team: it no longer lists them.\n\(Self.recovery)"
            struct Kept: Encodable { let removed: String; let role: String; let done: Bool; let recovery: String }
            return try ServiceResult(text: text, structured: Kept(removed: uid, role: role, done: true, recovery: Self.recovery))
        }
    }

    struct Rollback: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String; let deployment: String }
        static let name = "rollback"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: promote the deployment the result names as serving before, in the dashboard's Deployments. A rollback stops new production deployments from taking the production domains until one is promoted, so new pushes do not go live meanwhile."
        static let summary = "Make an earlier, ready production deployment of a project serve its production domains again, with Vercel's Instant Rollback, such as to take a compromised build out of service. Hobby teams can only roll back to the deployment just before; Vercel refuses while another rollback or promotion is under way. \(recovery)"
        static let input = JSONSchema.object(["project": Vercel.projectField,
                                              "deployment": .string("The production deployment to serve, by its ID, such as dpl_…, as deployments or project gives it.")],
                                             required: ["project", "deployment"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let deploymentID = try Vercel.id(input.deployment, "the deployment's ID")
            let (projectID, project) = try await Vercel.targetProject(input.project, service)
            let current = project.text("targets.production.id")
            if current == deploymentID { throw ServiceError.input("Nothing was changed: \(deploymentID) already serves \(Vercel.projectName(project))'s production domains.") }
            let deployment: Value
            do { deployment = try await Vercel.read(Vercel.deploymentsNeed) { try await Vercel.get(service, ["v13", "deployments", deploymentID], as: Value.self) } }
            catch { throw ServiceError.input("Nothing was changed: deployment \(deploymentID) could not be read first: \(error.localizedDescription)") }
            guard deployment.text("projectId") == projectID else {
                throw ServiceError.input("Nothing was changed: deployment \(deploymentID) belongs to \(deployment.text("projectId") ?? "another project"), not \(Vercel.projectName(project)).")
            }
            guard deployment.text("target") == "production" else { throw ServiceError.input("Nothing was changed: deployment \(deploymentID) is not a production deployment.") }
            guard (deployment.text("readyState") ?? deployment.text("status")) == "READY" else {
                throw ServiceError.input("Nothing was changed: deployment \(deploymentID) is \(deployment.text("readyState") ?? "in a state not given"), not ready.")
            }
            let path = ["v1", "projects", projectID, "rollback", deploymentID]
            let request = Vercel.requested("POST", path, "for \(Vercel.projectName(project)), serving \(current ?? "a deployment not given") before")
            do { _ = try await Vercel.change(service, path, method: "POST", body: nil, need: Vercel.rollbackNeed) }
            catch { throw ServiceError.input("Vercel refused to roll \(Vercel.projectName(project)) back to \(deploymentID): \(error.localizedDescription)\n\(request)") }
            let (read, error) = await Vercel.readBack({ try await Vercel.project(projectID, service, need: Vercel.projectEditNeed) }, until: { $0.text("targets.production.id") == deploymentID })
            guard read?.text("targets.production.id") == deploymentID else {
                let why = error.map { "reading the project back: \($0.localizedDescription)" } ?? "read back, production is served by \(read?.text("targets.production.id") ?? "a deployment not given")"
                throw ServiceError.input("Vercel accepted the rollback, but it could not be verified: \(why). It may still be under way; it is not reported done. Read it with project.\n\(request)\n\(Self.recovery)")
            }
            let text = "\(Vercel.projectName(project))'s production domains are served by \(deploymentID) again, read back as asked; \(current ?? "a deployment not given") served them before.\n\(Self.recovery)"
            struct Kept: Encodable { let project: String; let serving: String; let before: String?; let done: Bool; let recovery: String }
            return try ServiceResult(text: text, structured: Kept(project: projectID, serving: deploymentID, before: current, done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - Check access

extension Vercel {
    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Says whose token this is and their role in the team, which actions that role allows (an Owner for remove-member, a Member for the rest), and tries what the actions read first: projects, deployments, the firewall and members. It sends only reads."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try Vercel.api(service)
            let team = try Vercel.team(service)
            var lines = ["· Team \(team.value), reached at https://\(Vercel.host) and nowhere else."]
            let role = await Vercel.whoAmI(service, &lines)
            switch role?.uppercased() {
            case "OWNER"?: lines.append("✓ An Owner can take every action, remove-member included. ⚠ An Owner can also change everything in the team: give this member Member unless agents should remove members.")
            case "MEMBER"?: lines.append("✓ A Member can take every action but remove-member, which Vercel lets only an Owner take.")
            case let other?: lines.append("✗ The \(other) role cannot change projects, their firewall or production: give this member the Member role.")
            case nil: break
            }
            var firstProject: String?
            lines.append(await Vercel.probe(Vercel.projectsNeed) {
                firstProject = try await Vercel.list(service, ["v10", "projects"], key: "projects", size: 1, cursor: "from", pages: 1).value.first?.text("id")
            })
            lines.append(await Vercel.probe(Vercel.deploymentsNeed) { _ = try await Vercel.list(service, ["v7", "deployments"], key: "deployments", size: 1, pages: 1) })
            if let firstProject {
                lines.append(await Vercel.probe(Vercel.firewallEditNeed) {
                    do { _ = try await Vercel.firewall(firstProject, service) } catch ServiceError.notFound {}
                })
            }
            lines.append(await Vercel.probe(Vercel.membersNeed) {
                _ = try await Vercel.list(service, ["v3", "teams", try await Vercel.teamID(service), "members"], key: "members", size: 1, pages: 1)
            })
            lines.append("· The actions' changes are not tried: check-access sends none, so an action refused for want of a role says which.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }

    /// Says whose token this is and their role in the team, adding the lines to `lines`; the role, when it was read.
    static func whoAmI(_ service: ServiceClient, _ lines: inout [String]) async -> String? {
        let me: Value
        do { me = try await Vercel.me(service) } catch {
            lines.append("✗ The token's user: " + (fix(for: error, teamNeed) ?? error.localizedDescription))
            return nil
        }
        let uid = me.text("id") ?? me.text("uid") ?? "?"
        lines.append("· The token belongs to \(me.text("email") ?? me.text("username") ?? uid) [\(uid)].")
        do {
            let teamID = try await Vercel.teamID(service)
            let found = try await read(teamNeed) { try await get(service, ["v2", "teams", teamID], as: Value.self) }
            let role = found.text("membership.role")
            lines.append("✓ The team \(found.text("name") ?? teamID) [\(teamID)], on the \(found.text("billing.plan") ?? "unnamed") plan: they are \(role ?? "a member whose role is not given") there.")
            return role
        } catch {
            lines.append("✗ The team: " + (fix(for: error, teamNeed) ?? error.localizedDescription))
            return nil
        }
    }
}
