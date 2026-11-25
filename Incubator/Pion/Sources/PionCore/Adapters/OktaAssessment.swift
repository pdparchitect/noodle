import Foundation
import NoodleCore
import NoodleToolConnections

/// Okta Detection's reads for assessing how the org is set up: its global session and authentication policies with
/// their rules, its authenticators and the policies that enrol them, and its password policies, each said plainly with
/// the gaps an assessment asks about first. Okta lets the Read-Only Administrator view them; the sign-in reads them
/// through okta.policies.read, okta.authenticators.read and okta.networkZones.read, which only read.
extension Okta {
    /// The most policies whose rules are read, one request each, and the most groups and users named, one request each.
    static let policyLookups = 100, nameLookups = 50

    /// A policy as Okta lists it. Its conditions and settings differ by type, so they are kept as Okta gives them.
    struct PolicyRecord: Codable, Sendable {
        let id: String, type: String?, status: String?, name: String?, description: String?, priority: Double?, system: Bool?
        let conditions: GoogleCloud.JSON?, settings: GoogleCloud.JSON?
    }

    /// A policy rule as Okta lists it, its conditions and actions as Okta gives them.
    struct RuleRecord: Codable, Sendable {
        let id: String?, name: String?, status: String?, priority: Double?, system: Bool?, type: String?
        let conditions: GoogleCloud.JSON?, actions: GoogleCloud.JSON?
    }

    /// A policy with the rules read for it, and why they were not all read when they were not.
    struct PolicyRead: Sendable {
        let policy: PolicyRecord, rules: [RuleRecord], gap: String?
    }

    /// Every policy of one type, read page after page, in the order Okta applies them, with the rules of the first
    /// `policyLookups`, each read page after page; a policy whose rules could not be read says why.
    static func readPolicies(_ type: String, _ service: ServiceClient) async throws -> (read: [PolicyRead], listing: Listing<PolicyRecord>) {
        let listing = try await read(.policies) {
            try await list(service, ["policies"], query: ["type": type, "limit": "200"], as: PolicyRecord.self)
        }
        let ordered = listing.value.sorted { ($0.priority ?? .infinity, $0.name ?? $0.id) < ($1.priority ?? .infinity, $1.name ?? $1.id) }
        let looked = Array(ordered.prefix(policyLookups))
        var found = try await withThrowingTaskGroup(of: (Int, PolicyRead).self) { group in
            for (index, policy) in looked.enumerated() {
                group.addTask {
                    do {
                        let id = try Okta.id(policy.id, length: 1...64, "the policy")
                        let rules = try await Okta.read(.policies) {
                            try await Okta.list(service, ["policies", id, "rules"], query: ["limit": "200"], as: RuleRecord.self)
                        }
                        let sorted = rules.value.sorted { ($0.priority ?? .infinity) < ($1.priority ?? .infinity) }
                        return (index, PolicyRead(policy: policy, rules: sorted,
                                                  gap: rules.complete ? nil : Okta.stopped(rules, "its rules").trimmingCharacters(in: .whitespacesAndNewlines)))
                    } catch {
                        return (index, PolicyRead(policy: policy, rules: [], gap: "its rules were not read: \(error.localizedDescription)"))
                    }
                }
            }
            return try await group.reduce(into: [(Int, PolicyRead)]()) { $0.append($1) }
        }.sorted { $0.0 < $1.0 }.map(\.1)
        found += ordered.dropFirst(policyLookups).map { PolicyRead(policy: $0, rules: [], gap: "its rules were not read: only the first \(policyLookups) policies' rules are read") }
        return (found, listing)
    }

    // MARK: Names

    /// A network zone as Okta lists it: its addresses or places, to say how broad it is.
    struct Zone: Codable, Sendable {
        struct Address: Codable, Sendable { let type: String?, value: String? }
        struct Place: Codable, Sendable { let country: String?, region: String? }
        let id: String, name: String?, type: String?, status: String?, usage: String?, system: Bool?
        let gateways: [Address]?, proxies: [Address]?, locations: [Place]?

        /// Whether it holds every IPv4 or IPv6 address.
        var coversEverything: Bool {
            (gateways ?? []).contains { ["0.0.0.0/0", "0.0.0.0-255.255.255.255", "::/0"].contains(($0.value ?? "").replacingOccurrences(of: " ", with: "")) }
        }

        var said: String {
            var parts: [String] = []
            if let gateways, !gateways.isEmpty { parts.append("\(gateways.count) address range\(gateways.count == 1 ? "" : "s")") }
            if let locations, !locations.isEmpty { parts.append("places " + locations.prefix(5).map { [$0.country, $0.region].compactMap { $0 }.joined(separator: "-") }.joined(separator: ", ")) }
            if coversEverything { parts.append("covers every address") }
            if status == "INACTIVE" { parts.append("inactive") }
            return "\"\(name ?? id)\"" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
        }
    }

    /// Names for the groups, users and network zones conditions give by ID, read as far as `nameLookups` allows.
    struct Names: Sendable {
        var groups: [String: String] = [:], users: [String: String] = [:], zones: [String: Zone] = [:]
        /// Why zones were not named, and how many groups and users were left unnamed.
        var zoneGap: String?, unnamed = 0

        func group(_ id: String) -> String { "group \(groups[id].map { "\"\($0)\"" } ?? id)" }
        func user(_ id: String) -> String { "user \(users[id] ?? id)" }
        func zone(_ id: String) -> String {
            if id == "ALL_ZONES" { return "any zone" }
            return "zone " + (zones[id]?.said ?? id)
        }

        var gaps: [String] {
            [zoneGap.map { "Network zones were not named: \($0)" },
             unnamed > 0 ? "\(unnamed) group\(unnamed == 1 ? "" : "s") or user\(unnamed == 1 ? "" : "s") could not be named, so they show their ID." : nil].compactMap { $0 }
        }
    }

    static func ids(_ value: GoogleCloud.JSON?, _ path: String...) -> [String] {
        path.reduce(value) { $0?[$1] }?.strings ?? []
    }

    /// The groups, users and zones the policies and rules name, named: zones from one listing, groups and users one
    /// request each.
    static func names(for policies: [PolicyRead], _ service: ServiceClient) async -> Names {
        var groups = Set<String>(), users = Set<String>(), zones = false
        for read in policies {
            for conditions in [read.policy.conditions] + read.rules.map(\.conditions) {
                for side in ["include", "exclude"] {
                    groups.formUnion(ids(conditions, "people", "groups", side))
                    users.formUnion(ids(conditions, "people", "users", side))
                    if !ids(conditions, "network", side).isEmpty { zones = true }
                }
            }
        }
        var names = Names()
        if zones {
            do {
                let listing = try await read(.zones) { try await list(service, ["zones"], query: [:], as: Zone.self) }
                names.zones = Dictionary(listing.value.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                if !listing.complete { names.zoneGap = "not every zone was read" }
            } catch {
                names.zoneGap = error.localizedDescription
            }
        }
        let wanted = groups.sorted().map { (true, $0) } + users.sorted().map { (false, $0) }
        let looked = await withTaskGroup(of: (Bool, String, String?).self) { group in
            for (isGroup, given) in wanted.prefix(nameLookups) {
                group.addTask {
                    guard let id = try? Okta.id(given, length: 1...64, "the ID") else { return (isGroup, given, nil) }
                    if isGroup {
                        struct Group: Decodable { struct Profile: Decodable { let name: String? }; let profile: Profile? }
                        return (true, id, try? await Okta.get(service, ["groups", id], as: Group.self).profile?.name)
                    }
                    return (false, id, await Okta.login(id, on: service))
                }
            }
            return await group.reduce(into: [(Bool, String, String?)]()) { $0.append($1) }
        }
        for (isGroup, id, name) in looked {
            guard let name else { continue }
            if isGroup { names.groups[id] = name } else { names.users[id] = name }
        }
        names.unnamed = wanted.count - names.groups.count - names.users.count
        return names
    }

    /// Who a policy's or rule's conditions reach: its groups and users, included and excluded; everyone when it names none.
    static func who(_ conditions: GoogleCloud.JSON?, _ names: Names) -> String {
        let include = ids(conditions, "people", "groups", "include").map(names.group) + ids(conditions, "people", "users", "include").map(names.user)
        let exclude = ids(conditions, "people", "groups", "exclude").map(names.group) + ids(conditions, "people", "users", "exclude").map(names.user)
        return (include.isEmpty ? "everyone" : include.joined(separator: ", ")) + (exclude.isEmpty ? "" : " except " + exclude.joined(separator: ", "))
    }

    /// Where a rule applies from, and whether that is any network.
    static func network(_ conditions: GoogleCloud.JSON?, _ names: Names) -> (said: String, anywhere: Bool) {
        let network = conditions?["network"]
        let include = ids(network, "include"), exclude = ids(network, "exclude")
        let connection = network?["connection"]?.text?.uppercased() ?? "ANYWHERE"
        if connection == "ANYWHERE" || (include.isEmpty && exclude.isEmpty) { return ("any network", true) }
        let broad = include.contains("ALL_ZONES") || include.contains { names.zones[$0]?.coversEverything == true }
        if !include.isEmpty {
            return ("from " + include.map(names.zone).joined(separator: ", ") + (exclude.isEmpty ? "" : " except " + exclude.map(names.zone).joined(separator: ", ")), broad)
        }
        return ("any network except " + exclude.map(names.zone).joined(separator: ", "), true)
    }

    /// A length of time Okta gives in ISO 8601, such as PT2H, in seconds.
    static func seconds(_ duration: String?) -> Double? {
        guard let duration, let regex = try? NSRegularExpression(pattern: #"^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#),
              let match = regex.firstMatch(in: duration, range: NSRange(duration.startIndex..., in: duration)), duration.count > 1 else { return nil }
        let units: [Double] = [604_800, 86_400, 3_600, 60, 1]
        return (1...5).reduce(0.0) { total, index in
            guard let range = Range(match.range(at: index), in: duration), let value = Double(duration[range]) else { return total }
            return total + value * units[index - 1]
        }
    }

    /// A length of time in minutes, said in the largest whole unit.
    static func spoken(minutes: Double) -> String {
        let plural = { (count: Int, word: String) in "\(count) \(word)\(count == 1 ? "" : "s")" }
        if minutes >= 1_440, minutes.truncatingRemainder(dividingBy: 1_440) == 0 { return plural(Int(minutes / 1_440), "day") }
        if minutes >= 60, minutes.truncatingRemainder(dividingBy: 60) == 0 { return plural(Int(minutes / 60), "hour") }
        return plural(Int(minutes.rounded()), "minute")
    }

    static func isActive(_ status: String?) -> Bool { (status ?? "ACTIVE").uppercased() == "ACTIVE" }

    /// What a policy is called in a result: its kind and name.
    static func titled(_ policy: PolicyRecord) -> String {
        let kind = switch policy.type?.uppercased() {
        case "OKTA_SIGN_ON": "Global session policy"
        case "ACCESS_POLICY": "Authentication policy"
        case "MFA_ENROLL": "Authenticator enrollment policy"
        case "PASSWORD": "Password policy"
        default: "Policy"
        }
        return "\(kind) \"\(policy.name ?? policy.id)\""
    }

    /// A policy's line: its kind, name, state, priority, whether it is Okta's default, and whom it reaches.
    static func heading(_ policy: PolicyRecord, _ names: Names) -> String {
        let state = [isActive(policy.status) ? "active" : "inactive", policy.priority.map { "priority \(Int($0))" },
                     policy.system == true ? "Okta's default" : nil].compactMap { $0 }.joined(separator: ", ")
        return "\(titled(policy)) (\(state)) for \(who(policy.conditions, names)):"
    }

    /// One rule as a result keeps it: what it does said plainly, its gaps, and its conditions and actions as Okta gives them.
    struct RuleSaid: Encodable {
        let id: String?, name: String?, status: String?, priority: Int?, system: Bool?, said: String, gaps: [String]
        let conditions: GoogleCloud.JSON?, actions: GoogleCloud.JSON?
    }

    /// One policy as a result keeps it.
    struct PolicySaid: Encodable {
        let id: String, type: String?, name: String?, status: String?, priority: Int?, system: Bool?, appliesTo: String, said: [String], gaps: [String]
        let rules: [RuleSaid], rulesNotRead: String?, settings: GoogleCloud.JSON?
    }

    /// A rule's line: its order, name and state, then what it does.
    static func ruleLine(_ rule: RuleRecord, _ said: String) -> String {
        let state = [isActive(rule.status) ? nil : "inactive", rule.system == true ? "Okta's default" : nil].compactMap { $0 }
        return "  \(rule.priority.map { "\(Int($0))." } ?? "·") \"\(rule.name ?? rule.id ?? "?")\"\(state.isEmpty ? "" : " (\(state.joined(separator: ", ")))"): \(said)"
    }
}

// MARK: - Sign-on policies

extension Okta {
    /// The global session policies, which say how a session with Okta starts and how long it lasts, and the
    /// authentication policies, which say what each app asks for, with every rule: whom it reaches, from where, and
    /// what it requires. Gaps an assessment asks about first lead.
    struct SignOnPolicies: ServiceOperation {
        struct Input: Decodable, Sendable { let type: String?, sessionHours: Int?, limit: Int? }
        static let name = "sign-on-policies"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The global session policies and authentication policies, in the order Okta applies them, with every rule: whom it reaches by group and user, from which network zones, whether it allows or denies, whether MFA or a phishing-resistant factor is required, and how long sessions and re-authentication last; gaps first, such as rules that let a password alone in, sessions that never end, or rules that apply from any network. Inactive ones are listed but not counted."
        static let types = ["OKTA_SIGN_ON", "ACCESS_POLICY"]
        static let input = JSONSchema.object([
            "type": .string("Only global session policies (OKTA_SIGN_ON) or only authentication policies (ACCESS_POLICY). Both when left out.", oneOf: types),
            "sessionHours": .integer("How long a session or re-authentication may last before it counts as a gap. 12 hours when left out.", minimum: 1, maximum: 720),
            "limit": .integer("How many policies to list, at most, with all their rules; gaps cover every policy read. 100 when left out.", minimum: 1, maximum: 500),
        ])
        /// How long an idle session may last before it counts as a gap, Okta's own default.
        static let idleMinutes = 120.0

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 policies.") }
            let hours = input.sessionHours ?? 12
            guard (1...720).contains(hours) else { throw ServiceError.input("Ask for between 1 and 720 hours.") }
            let type = input.type?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let type, !Self.types.contains(type) { throw ServiceError.input("A type is OKTA_SIGN_ON or ACCESS_POLICY.") }
            var read: [PolicyRead] = [], gaps: [String] = [], failures: [Error] = [], complete = true
            for kind in type.map({ [$0] }) ?? Self.types {
                do {
                    let (policies, listing) = try await Okta.readPolicies(kind, service)
                    read += policies
                    if !listing.complete { complete = false; gaps.append(Okta.stopped(listing, kind == "OKTA_SIGN_ON" ? "global session policies" : "authentication policies").trimmingCharacters(in: .whitespacesAndNewlines)) }
                } catch {
                    failures.append(error)
                    gaps.append("\(kind == "OKTA_SIGN_ON" ? "Global session" : "Authentication") policies were not read: \(error.localizedDescription)"
                                + (kind == "ACCESS_POLICY" ? " A Classic Engine org has no authentication policies." : ""))
                }
            }
            if read.isEmpty, failures.count == (type == nil ? 2 : 1), let first = failures.first { throw first }
            let names = await Okta.names(for: read, service)
            let limitMinutes = Double(hours) * 60
            let said = read.map { Self.said($0, names, limitMinutes: limitMinutes) }
            let flagged = said.flatMap { policy in policy.gaps.map { "\(policy.title): \($0)" } + policy.rules.flatMap { rule in rule.gaps.map { "\(policy.title) › rule \"\(rule.name ?? rule.id ?? "?")\": \($0)" } } }

            let sessions = read.filter { $0.policy.type?.uppercased() == "OKTA_SIGN_ON" }.count, apps = read.count - sessions
            let rules = read.reduce(0) { $0 + $1.rules.count }
            var lines = ["\(sessions) global session polic\(sessions == 1 ? "y" : "ies") and \(apps) authentication polic\(apps == 1 ? "y" : "ies"), with \(rules) rule\(rules == 1 ? "" : "s")."]
            if flagged.isEmpty {
                lines.append(read.isEmpty ? "No policies were read." : "No gaps found in the active policies and rules read: every one requires more than a password, keeps sessions within \(hours) hours and idle sessions within \(Okta.spoken(minutes: Self.idleMinutes)), or denies.")
            } else {
                lines.append("Gaps an assessment asks about first, in active policies and rules (\(flagged.count)):")
                lines += flagged.map { "- " + $0 }
            }
            lines.append("Policies, in the order Okta applies them; within each, the first rule that matches applies:")
            for policy in said.prefix(limit) {
                lines.append(policy.heading)
                lines += policy.lines
            }
            if said.count > limit { lines.append("\(said.count - limit) more policies were read than are listed; their gaps are counted above. Narrow by type, or raise limit.") }
            lines += gaps + names.gaps
            if read.contains(where: { $0.gap != nil }) { complete = false }
            struct Kept: Encodable { let policies: [PolicySaid]; let gaps: [String]; let matched: Int, sessionHours: Int; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(policies: said.prefix(limit).map(\.kept), gaps: flagged, matched: said.count, sessionHours: hours,
                                                      complete: complete && names.zoneGap == nil))
        }

        struct Said {
            let title: String, heading: String, lines: [String], gaps: [String], rules: [RuleSaid], kept: PolicySaid
        }

        static func said(_ read: PolicyRead, _ names: Names, limitMinutes: Double) -> Said {
            let policy = read.policy, active = Okta.isActive(policy.status)
            var lines: [String] = [], kept: [RuleSaid] = []
            for rule in read.rules {
                let (text, found) = policy.type?.uppercased() == "OKTA_SIGN_ON" ? session(rule, names, limitMinutes: limitMinutes) : app(rule, names, limitMinutes: limitMinutes)
                let gaps = active && Okta.isActive(rule.status) ? found : []
                lines.append(Okta.ruleLine(rule, text))
                kept.append(RuleSaid(id: rule.id, name: rule.name, status: rule.status, priority: rule.priority.map { Int($0) }, system: rule.system,
                                     said: text, gaps: gaps, conditions: rule.conditions, actions: rule.actions))
            }
            if read.rules.isEmpty, read.gap == nil { lines.append("  No rules: nobody is let in by it.") }
            if let gap = read.gap { lines.append("  Not complete: \(gap)") }
            let applies = Okta.who(policy.conditions, names)
            return Said(title: Okta.titled(policy), heading: Okta.heading(policy, names), lines: lines, gaps: [], rules: kept,
                        kept: PolicySaid(id: policy.id, type: policy.type, name: policy.name, status: policy.status, priority: policy.priority.map { Int($0) },
                                         system: policy.system, appliesTo: applies, said: [], gaps: [], rules: kept, rulesNotRead: read.gap, settings: policy.settings))
        }

        /// A global session policy's rule: whether it lets people in, whether MFA is asked for the session and how
        /// often, and how long sessions last.
        static func session(_ rule: RuleRecord, _ names: Names, limitMinutes: Double) -> (String, [String]) {
            let signon = rule.actions?["signon"], conditions = rule.conditions
            let (from, anywhere) = Okta.network(conditions, names)
            var parts = ["for \(Okta.who(conditions, names))", from]
            if let auth = conditions?["authContext"]?["authType"]?.text, auth != "ANY" { parts.append("by \(auth)") }
            if let risk = conditions?["riskScore"]?["level"]?.text, risk != "ANY" { parts.append("at \(risk.lowercased()) risk") }
            if let provider = conditions?["identityProvider"]?["provider"]?.text, provider != "ANY" { parts.append("signing in through \(provider)") }
            guard (signon?["access"]?.text ?? "ALLOW").uppercased() == "ALLOW" else { return ((["denies"] + parts).joined(separator: ", "), []) }
            var said = ["allows"], gaps: [String] = []
            let requireFactor = signon?["requireFactor"]?.bool ?? false, primary = signon?["primaryFactor"]?.text
            if requireFactor {
                let lifetime = signon?["factorLifetime"]?.number
                switch signon?["factorPromptMode"]?.text?.uppercased() {
                case "ALWAYS": said.append("MFA at every sign-in")
                case "DEVICE": said.append("MFA once on each new device")
                case "SESSION": said.append("MFA once every \(lifetime.map { Okta.spoken(minutes: $0) } ?? "session")")
                default: said.append("MFA required")
                }
            } else if let primary {
                // Identity Engine: the session's first factor here, then each app's authentication policy decides.
                said.append(primary == "PASSWORD_IDP" ? "a password starts the session, without MFA, and each app's authentication policy decides the rest"
                                                      : "no MFA for the session itself: each app's authentication policy decides")
            } else {
                said.append("no MFA: a password alone signs in")
                gaps.append("a password alone signs in, without MFA" + (anywhere ? ", from any network" : ""))
            }
            let session = signon?["session"]
            if let lifetime = session?["maxSessionLifetimeMinutes"]?.number {
                if lifetime <= 0 {
                    said.append("sessions never end by time")
                    gaps.append("sessions never end by time")
                } else {
                    said.append("sessions end after \(Okta.spoken(minutes: lifetime))")
                    if lifetime > limitMinutes { gaps.append("sessions last \(Okta.spoken(minutes: lifetime))") }
                }
            }
            if let idle = session?["maxSessionIdleMinutes"]?.number {
                said.append("idle sessions end after \(Okta.spoken(minutes: idle))")
                if idle > idleMinutes { gaps.append("idle sessions last \(Okta.spoken(minutes: idle))") }
            }
            if session?["usePersistentCookie"]?.bool == true {
                said.append("sessions survive closing the browser")
                gaps.append("sessions survive closing the browser")
            }
            if signon?["rememberDeviceByDefault"]?.bool == true { said.append("devices remembered by default") }
            return ((said + parts).joined(separator: ", "), gaps)
        }

        /// An authentication policy's rule: whether it lets people into the app, with how many factors and which, and
        /// how often they must authenticate again.
        static func app(_ rule: RuleRecord, _ names: Names, limitMinutes: Double) -> (String, [String]) {
            let signOn = rule.actions?["appSignOn"], conditions = rule.conditions
            let (from, anywhere) = Okta.network(conditions, names)
            var parts = ["for \(Okta.who(conditions, names))", from]
            if let risk = conditions?["riskScore"]?["level"]?.text, risk != "ANY" { parts.append("at \(risk.lowercased()) risk") }
            if let device = conditions?["device"], device != .null { parts.append("devices \(device.compact(120))") }
            if let platforms = conditions?["platform"]?["include"]?.array, !platforms.isEmpty {
                parts.append("on " + platforms.map { [$0["type"]?.text, $0["os"]?["type"]?.text].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", "))
            }
            if let users = conditions?["userType"], users != .null { parts.append("user types \(users.compact(120))") }
            if let expression = conditions?["elCondition"]?["condition"]?.text { parts.append("when \(expression)") }
            guard (signOn?["access"]?.text ?? "ALLOW").uppercased() == "ALLOW" else { return ((["denies"] + parts).joined(separator: ", "), []) }
            var said = ["allows"], gaps: [String] = []
            let method = signOn?["verificationMethod"]
            switch method?["type"]?.text?.uppercased() ?? "ASSURANCE" {
            case "ASSURANCE":
                let constraints = method?["constraints"]?.array ?? []
                let mode = method?["factorMode"]?.text?.uppercased()
                // One factor with no constraint, or one a knowledge factor alone meets, takes a password alone.
                let passwordAlone = constraints.isEmpty || constraints.contains { $0["possession"] == nil || $0["possession"] == GoogleCloud.JSON.null }
                if mode == "1FA" {
                    said.append(passwordAlone ? "one factor, which may be a password alone" : "one factor, which must be one the user holds")
                    if passwordAlone { gaps.append("one factor, which may be a password alone, lets people in" + (anywhere ? ", from any network" : "")) }
                } else {
                    said.append(mode == "2FA" ? "two factors" : "factors \(mode ?? "as Okta's default")")
                }
                let possession = constraints.compactMap { $0["possession"] }
                if possession.contains(where: { $0["phishingResistant"]?.text == "REQUIRED" }) { said.append("phishing-resistant required") }
                if possession.contains(where: { $0["hardwareProtection"]?.text == "REQUIRED" }) { said.append("hardware-protected required") }
                if possession.contains(where: { $0["deviceBound"]?.text == "REQUIRED" }) { said.append("device-bound required") }
                let types = Set(constraints.flatMap { constraint in ["knowledge", "possession"].flatMap { Okta.ids(constraint, $0, "types") + Okta.ids(constraint, $0, "methods") } })
                if !types.isEmpty { said.append("of " + types.sorted().map { $0.lowercased().replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")) }
            case let other:
                said.append(other == "AUTH_METHOD_CHAIN" ? "a chain of authentication methods" : other == "ID_PROOFING" ? "identity proofing" : "verification \(other)")
            }
            if let again = method?["reauthenticateIn"]?.text, let seconds = Okta.seconds(again) {
                if seconds == 0 { said.append("authenticate again every time") } else {
                    said.append("authenticate again after \(Okta.spoken(minutes: seconds / 60))")
                    if seconds / 60 > limitMinutes { gaps.append("people authenticate again only after \(Okta.spoken(minutes: seconds / 60))") }
                }
            }
            if let idle = method?["inactivityPeriod"]?.text, let seconds = Okta.seconds(idle) { said.append("again after \(Okta.spoken(minutes: seconds / 60)) idle") }
            return ((said + parts).joined(separator: ", "), gaps)
        }
    }
}

// MARK: - Authenticators

extension Okta {
    /// An authenticator as Okta lists it.
    struct Authenticator: Codable, Sendable {
        let id: String?, key: String?, name: String?, type: String?, status: String?, settings: GoogleCloud.JSON?
    }

    /// Authenticators an attacker can take over through the phone network, or guess or look up, by key: Identity
    /// Engine's authenticators, and Classic Engine's factors.
    static let weakAuthenticators = ["phone_number": "SMS or voice codes", "security_question": "a security question",
                                     "okta_sms": "SMS codes", "okta_call": "voice codes", "okta_question": "a security question"]
    /// Authenticators that prove only that someone holds the password or reads the mailbox.
    static let notSecondFactors: Set<String> = ["okta_password", "okta_email"]

    /// The org's authenticators, which of them are allowed and for what, and the authenticator enrollment policies:
    /// which each policy requires, offers or refuses for whom, and when people are asked to enroll.
    struct MFAPolicies: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "mfa-policies"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The org's authenticators, active or not and what each may be used for, and the authenticator enrollment policies, in the order Okta applies them: for whom each requires, offers or refuses each authenticator, and when its rules ask people to enroll; gaps first, such as SMS, voice or a security question allowed, or a policy that requires nothing beyond a password and email. Inactive policies are listed but not counted."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var authenticators: [Authenticator]?, failures: [Error] = [], notes: [String] = []
            do {
                let listing = try await Okta.read(.authenticators) { try await Okta.list(service, ["authenticators"], query: [:], as: Authenticator.self) }
                authenticators = listing.value
                if !listing.complete { notes.append(Okta.stopped(listing, "authenticators").trimmingCharacters(in: .whitespacesAndNewlines)) }
            } catch {
                failures.append(error)
                notes.append("Authenticators were not read: \(error.localizedDescription) A Classic Engine org lists factors instead, which this tool does not read.")
            }
            var policies: [PolicyRead] = [], complete = true
            do {
                let (read, listing) = try await Okta.readPolicies("MFA_ENROLL", service)
                policies = read
                if !listing.complete { complete = false; notes.append(Okta.stopped(listing, "enrollment policies").trimmingCharacters(in: .whitespacesAndNewlines)) }
            } catch {
                failures.append(error)
                notes.append("Authenticator enrollment policies were not read: \(error.localizedDescription)")
            }
            if failures.count == 2 { throw failures[0] }
            let names = await Okta.names(for: policies, service)
            var gaps: [String] = [], lines: [String] = []

            if let authenticators {
                let active = authenticators.filter { Okta.isActive($0.status) }
                for item in active {
                    guard let key = item.key, let weak = Okta.weakAuthenticators[key] else { continue }
                    switch item.settings?["allowedFor"]?.text?.lowercased() {
                    case "recovery": gaps.append("\(item.name ?? key) (\(weak)) is active for account recovery")
                    case "none": continue
                    default: gaps.append("\(item.name ?? key) (\(weak)) is active and may be used to sign in")
                    }
                }
            }
            var said: [PolicySaid] = []
            for read in policies {
                let policy = read.policy, active = Okta.isActive(policy.status)
                let settings = Self.enrollment(policy.settings)
                var found: [String] = []
                let required = settings.filter { $0.enroll == "REQUIRED" }.map(\.key), offered = settings.filter { $0.enroll == "OPTIONAL" }.map(\.key)
                for key in required + offered { if let weak = Okta.weakAuthenticators[key] { found.append("lets people enroll \(key) (\(weak))") } }
                if !settings.isEmpty, required.allSatisfy(Okta.notSecondFactors.contains) {
                    found.append(required.isEmpty ? "requires no authenticator at all" : "requires no authenticator besides " + required.joined(separator: " and "))
                }
                var policyLines = settings.isEmpty ? ["  Settings: \(policy.settings?.compact(200) ?? "none given")"] : [
                    "  Required: \(required.isEmpty ? "none" : required.joined(separator: ", "))",
                    "  Optional: \(offered.isEmpty ? "none" : offered.joined(separator: ", "))",
                    "  Not allowed: \(settings.filter { $0.enroll == "NOT_ALLOWED" }.map(\.key).joined(separator: ", ").nonEmpty ?? "none")",
                ]
                var rules: [RuleSaid] = []
                for rule in read.rules {
                    let text = Self.rule(rule, names)
                    policyLines.append(Okta.ruleLine(rule, text))
                    rules.append(RuleSaid(id: rule.id, name: rule.name, status: rule.status, priority: rule.priority.map { Int($0) }, system: rule.system, said: text,
                                          gaps: [], conditions: rule.conditions, actions: rule.actions))
                }
                if let gap = read.gap { policyLines.append("  Not complete: \(gap)"); complete = false }
                let counted = active ? found : []
                gaps += counted.map { "\(Okta.titled(policy)) \($0)" }
                lines.append(Okta.heading(policy, names))
                lines += policyLines
                said.append(PolicySaid(id: policy.id, type: policy.type, name: policy.name, status: policy.status, priority: policy.priority.map { Int($0) },
                                       system: policy.system, appliesTo: Okta.who(policy.conditions, names), said: Array(policyLines.prefix(3)), gaps: counted,
                                       rules: rules, rulesNotRead: read.gap, settings: policy.settings))
            }

            var text: [String] = []
            if let authenticators {
                let active = authenticators.filter { Okta.isActive($0.status) }
                text.append("\(active.count) of the org's \(authenticators.count) authenticator\(authenticators.count == 1 ? "" : "s") are active, and \(policies.count) authenticator enrollment polic\(policies.count == 1 ? "y" : "ies").")
            } else {
                text.append("\(policies.count) authenticator enrollment polic\(policies.count == 1 ? "y" : "ies").")
            }
            if gaps.isEmpty {
                text.append("No gaps found in what was read: no SMS, voice or security question is active or offered, and every active enrollment policy requires an authenticator besides a password and email.")
            } else {
                text.append("Gaps an assessment asks about first (\(gaps.count)):")
                text += gaps.map { "- " + $0 }
            }
            if let authenticators {
                text.append("Authenticators:")
                text += authenticators.map { item in
                    let use = item.settings?["allowedFor"]?.text.map { ", allowed for \($0)" } ?? ""
                    return "  \(item.name ?? item.key ?? item.id ?? "?") (\(item.key ?? "?")): \(Okta.isActive(item.status) ? "active" : "inactive")\(use)"
                }
            }
            if !policies.isEmpty { text.append("Authenticator enrollment policies, in the order Okta applies them:") }
            text += lines + notes + names.gaps
            struct Kept: Encodable { let authenticators: [Authenticator]?; let policies: [PolicySaid]; let gaps: [String]; let complete: Bool }
            return try ServiceResult(text: text.joined(separator: "\n"),
                                     structured: Kept(authenticators: authenticators, policies: said, gaps: gaps, complete: complete && failures.isEmpty))
        }

        /// What a policy's settings say of each authenticator: Identity Engine lists authenticators, Classic factors.
        static func enrollment(_ settings: GoogleCloud.JSON?) -> [(key: String, enroll: String)] {
            if let listed = settings?["authenticators"]?.array {
                return listed.compactMap { item in item["key"]?.text.map { ($0, item["enroll"]?["self"]?.text?.uppercased() ?? "NOT_ALLOWED") } }
            }
            if case .object(let factors)? = settings?["factors"] {
                return factors.keys.sorted().map { ($0, factors[$0]?["enroll"]?["self"]?.text?.uppercased() ?? "NOT_ALLOWED") }
            }
            return []
        }

        static func rule(_ rule: RuleRecord, _ names: Names) -> String {
            let when = switch rule.actions?["enroll"]?["self"]?.text?.uppercased() {
            case "CHALLENGE", "LOGIN": "people are asked to enroll the next time they sign in"
            case "NEVER": "people are never asked to enroll at sign-in, only during recovery"
            case "NEVER_INCLUDING_RECOVERY": "people are never asked to enroll"
            case let other?: "enrollment \(other)"
            case nil: "enrollment as Okta's default"
            }
            return "\(when), for \(Okta.who(rule.conditions, names)), \(Okta.network(rule.conditions, names).said)"
        }
    }
}

// MARK: - Password policies

extension Okta {
    /// The password policies: how long and complex passwords must be, how old they may get, how many failed attempts
    /// lock an account, and how people may recover it, with each policy's rules on who may change, reset or unlock.
    struct PasswordPolicies: ServiceOperation {
        struct Input: Decodable, Sendable { let minLength: Int? }
        static let name = "password-policies"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The password policies, in the order Okta applies them, for whom each applies: minimum length and character classes, common passwords and the username refused or not, maximum and minimum age, history, lockout after failed attempts and unlock, breached-password protection, recovery by email, SMS, voice call or security question, and each rule's self-service change, reset and unlock; gaps first, such as passwords shorter than asked, no lockout, common passwords allowed, or recovery by SMS or a security question. Inactive policies are listed but not counted."
        static let input = JSONSchema.object([
            "minLength": .integer("The shortest password an assessment accepts; shorter minimums are gaps. 12 when left out.", minimum: 4, maximum: 64),
        ])
        /// The most failed attempts before a lockout that does not count as a gap.
        static let attempts = 10.0

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let shortest = input.minLength ?? 12
            guard (4...64).contains(shortest) else { throw ServiceError.input("Ask for a minimum length between 4 and 64.") }
            let (policies, listing) = try await Okta.readPolicies("PASSWORD", service)
            let names = await Okta.names(for: policies, service)
            var gaps: [String] = [], lines: [String] = [], said: [PolicySaid] = []
            for read in policies {
                let policy = read.policy, active = Okta.isActive(policy.status)
                let (text, found) = Self.settings(policy, shortest: shortest)
                var policyLines = text.map { "  " + $0 }
                var rules: [RuleSaid] = []
                var ruleGaps: [String] = []
                for rule in read.rules {
                    let (ruleText, ruleFound) = Self.rule(rule, names)
                    policyLines.append(Okta.ruleLine(rule, ruleText))
                    let counted = active && Okta.isActive(rule.status) ? ruleFound : []
                    ruleGaps += counted.map { "rule \"\(rule.name ?? rule.id ?? "?")\": \($0)" }
                    rules.append(RuleSaid(id: rule.id, name: rule.name, status: rule.status, priority: rule.priority.map { Int($0) }, system: rule.system,
                                          said: ruleText, gaps: counted, conditions: rule.conditions, actions: rule.actions))
                }
                if let gap = read.gap { policyLines.append("  Not complete: \(gap)") }
                let counted = active ? found : []
                gaps += counted.map { "\(Okta.titled(policy)): \($0)" } + ruleGaps.map { "\(Okta.titled(policy)) › \($0)" }
                lines.append(Okta.heading(policy, names))
                lines += policyLines
                said.append(PolicySaid(id: policy.id, type: policy.type, name: policy.name, status: policy.status, priority: policy.priority.map { Int($0) },
                                       system: policy.system, appliesTo: Okta.who(policy.conditions, names), said: text, gaps: counted, rules: rules,
                                       rulesNotRead: read.gap, settings: policy.settings))
            }
            var text = ["\(policies.count) password polic\(policies.count == 1 ? "y" : "ies")."]
            if gaps.isEmpty {
                text.append(policies.isEmpty ? "No password policies were read." : "No gaps found in the active policies read: passwords of at least \(shortest) characters, common passwords refused, a lockout within \(Int(Self.attempts)) attempts, and no recovery by SMS, voice call or security question.")
            } else {
                text.append("Gaps an assessment asks about first (\(gaps.count)):")
                text += gaps.map { "- " + $0 }
            }
            text.append("Password policies, in the order Okta applies them; within each, the first rule that matches applies:")
            text += lines
            if !listing.complete { text.append(Okta.stopped(listing, "password policies").trimmingCharacters(in: .whitespacesAndNewlines)) }
            text += names.gaps
            struct Kept: Encodable { let policies: [PolicySaid]; let gaps: [String]; let minLength: Int; let complete: Bool }
            return try ServiceResult(text: text.joined(separator: "\n"),
                                     structured: Kept(policies: said, gaps: gaps, minLength: shortest,
                                                      complete: listing.complete && !policies.contains { $0.gap != nil }))
        }

        /// A password policy's settings said plainly, and its gaps.
        static func settings(_ policy: PolicyRecord, shortest: Int) -> ([String], [String]) {
            let password = policy.settings?["password"], complexity = password?["complexity"], age = password?["age"], lockout = password?["lockout"]
            var lines: [String] = [], gaps: [String] = []
            let provider = policy.conditions?["authProvider"]?["provider"]?.text?.uppercased() ?? "OKTA"
            if provider != "OKTA" {
                lines.append("For people whose passwords \(provider == "ACTIVE_DIRECTORY" ? "Active Directory" : provider) keeps: its own rules set their length, age and lockout, not those below.")
            }
            let count = { (value: GoogleCloud.JSON?) in value?.number.map { Int($0) } }
            var rules: [String] = []
            if let length = count(complexity?["minLength"]) {
                rules.append("at least \(length) characters")
                if provider == "OKTA", length < shortest { gaps.append("passwords may be as short as \(length) characters, under \(shortest)") }
            }
            let classes = [("minLowerCase", "lowercase"), ("minUpperCase", "uppercase"), ("minNumber", "digit"), ("minSymbol", "symbol")]
                .compactMap { key, word in count(complexity?[key]).flatMap { $0 > 0 ? "\($0) \(word)" : nil } }
            if !classes.isEmpty { rules.append("with " + classes.joined(separator: ", ")) }
            if let common = complexity?["dictionary"]?["common"]?["exclude"]?.bool {
                rules.append(common ? "common passwords refused" : "common passwords allowed")
                if !common, provider == "OKTA" { gaps.append("common passwords are allowed") }
            }
            if complexity?["excludeUsername"]?.bool == true { rules.append("not the username") }
            if !(complexity?["excludeAttributes"]?.strings ?? []).isEmpty { rules.append("not \((complexity?["excludeAttributes"]?.strings ?? []).joined(separator: ", "))") }
            if !rules.isEmpty { lines.append("Passwords: " + rules.joined(separator: ", ") + ".") }

            var ageing: [String] = []
            if let days = count(age?["maxAgeDays"]) { ageing.append(days == 0 ? "never expire" : "expire after \(days) days") }
            if let minutes = age?["minAgeMinutes"]?.number, minutes > 0 { ageing.append("may change again after \(Okta.spoken(minutes: minutes))") }
            if let history = count(age?["historyCount"]) { ageing.append(history == 0 ? "old passwords may be reused" : "the last \(history) may not be reused") }
            if !ageing.isEmpty { lines.append("Age: " + ageing.joined(separator: ", ") + ".") }

            if let attempts = lockout?["maxAttempts"]?.number {
                if attempts <= 0 {
                    lines.append("Lockout: none, however many attempts fail.")
                    if provider == "OKTA" { gaps.append("no lockout after failed sign-in attempts") }
                } else {
                    let unlock = lockout?["autoUnlockMinutes"]?.number.map { $0 > 0 ? "unlocks itself after \(Okta.spoken(minutes: $0))" : "stays locked until unlocked" } ?? ""
                    lines.append("Lockout: after \(Int(attempts)) failed attempts" + (unlock.isEmpty ? "" : ", " + unlock) + ".")
                    if attempts > Self.attempts, provider == "OKTA" { gaps.append("an account locks only after \(Int(attempts)) failed attempts") }
                }
            }
            if let breached = password?["breachedProtection"], breached != .null { lines.append("Breached-password protection: \(breached.compact(160)).") }

            let factors = policy.settings?["recovery"]?["factors"]
            var recovery: [String] = []
            for (key, word, weak) in [("okta_email", "email", false), ("okta_sms", "SMS", true), ("okta_call", "voice call", true), ("recovery_question", "security question", true)] {
                guard let factor = factors?[key], Okta.isActive(factor["status"]?.text) else { continue }
                var said = word
                if let minutes = factor["properties"]?["recoveryToken"]?["tokenLifetimeMinutes"]?.number { said += " (link valid \(Okta.spoken(minutes: minutes)))" }
                recovery.append(said)
                if weak { gaps.append("the account can be recovered by \(word)") }
            }
            if factors != nil { lines.append("Recovery: " + (recovery.isEmpty ? "none active." : recovery.joined(separator: ", ") + ".")) }
            if policy.settings?["delegation"]?["options"]?["skipUnlock"]?.bool == true { lines.append("An Active Directory account is not unlocked when its password is reset.") }
            return (lines, gaps)
        }

        /// A password policy's rule: who may change, reset and unlock their password, and with what.
        static func rule(_ rule: RuleRecord, _ names: Names) -> (String, [String]) {
            let actions = rule.actions
            var said: [String] = [], gaps: [String] = []
            let allowed = { (name: String) in (actions?[name]?["access"]?.text ?? "").uppercased() == "ALLOW" }
            if actions?["passwordChange"] != nil { said.append(allowed("passwordChange") ? "may change their password" : "may not change their password") }
            if actions?["selfServicePasswordReset"] != nil {
                if allowed("selfServicePasswordReset") {
                    let requirement = actions?["selfServicePasswordReset"]?["requirement"]
                    let methods = Okta.ids(requirement, "primary", "methods")
                    let stepUp = requirement?["stepUp"]?["required"]?.bool ?? false
                    said.append("may reset it" + (methods.isEmpty ? "" : " with \(methods.joined(separator: " or "))") + (stepUp ? " and a second step" : ""))
                    if !methods.isEmpty, !stepUp, Set(methods.map { $0.lowercased() }).isSubset(of: ["email", "sms", "voice"]) {
                        gaps.append("a password can be reset with \(methods.joined(separator: " or ")) alone, without a second step")
                    }
                } else {
                    said.append("may not reset it themselves")
                }
            }
            if actions?["selfServiceUnlock"] != nil { said.append(allowed("selfServiceUnlock") ? "may unlock their account" : "may not unlock their account themselves") }
            return ((said.isEmpty ? ["as Okta's default"] : said).joined(separator: ", ") + ", for \(Okta.who(rule.conditions, names)), \(Okta.network(rule.conditions, names).said)", gaps)
        }
    }
}

// MARK: - JSON

extension GoogleCloud.JSON {
    var number: Double? { if case .number(let number) = self { return number }; return nil }
    var bool: Bool? { if case .bool(let bool) = self { return bool }; return nil }
    var array: [GoogleCloud.JSON]? { if case .array(let items) = self { return items }; return nil }
    /// The texts of a list, leaving out anything else.
    var strings: [String] { array?.compactMap(\.text) ?? [] }
}

extension String {
    /// Itself, or nil when empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}
