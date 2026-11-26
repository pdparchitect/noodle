import Foundation
import NoodleCore
import NoodleToolConnections

/// Duo Detection's reads for an audit: what exists, its users, admins, applications and phones; and what is
/// allowed, its policies and bypass codes. Not its global settings: Duo lets them be read only with the right to change
/// them. Each leads with the gaps an audit asks about.
extension Duo {
    /// Lines for a result, at most `most`, saying how many more the structured result keeps.
    static func capped(_ lines: [String], _ most: Int) -> [String] {
        lines.count > most ? Array(lines.prefix(most)) + ["… and \(lines.count - most) more in the structured result."] : lines
    }

    // MARK: Users

    struct Users: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "users"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Every user, counted by status, led by those in bypass status (who skip Duo's second factor), not enrolled, locked out or disabled, then those who never logged in, each with their devices; up to 3,000 users, saying when there are more."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Duo.read(.resources) { try await Duo.list(service, ["admin", "v1", "users"], limit: 300, as: User.self) }
            let users = listing.value
            let status = { (user: User) in user.status?.lowercased() ?? "unknown" }
            let bypass = users.filter { status($0) == "bypass" }
            let unenrolled = users.filter { $0.is_enrolled == false && status($0) != "bypass" }
            let locked = users.filter { status($0) == "locked out" }
            let disabled = users.filter { status($0) == "disabled" }
            let never = users.filter { $0.last_login?.date == nil && status($0) == "active" && $0.is_enrolled != false }
            let counts = Dictionary(grouping: users, by: status).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
            var lines = [users.isEmpty ? "No users\(listing.complete ? "" : " in what was read")." : "\(users.count) users: \(counts)."]
            func section(_ title: String, _ found: [User]) {
                guard !found.isEmpty else { return }
                lines.append("\(title) (\(found.count)): " + found.prefix(25).map(\.sentence).joined(separator: "; ")
                             + (found.count > 25 ? "; and \(found.count - 25) more" : "") + ".")
            }
            section("In bypass status, so they skip the second factor", bypass)
            section("Not enrolled, so a policy decides whether they get in without Duo", unenrolled)
            section("Locked out", locked)
            section("Disabled", disabled)
            section("Active and enrolled but never logged in", never)
            if bypass.isEmpty && unenrolled.isEmpty && locked.isEmpty { lines.append("No user is in bypass status, unenrolled or locked out.") }
            lines.append("A group's status, such as Bypass, can override a user's own; integrations and policies show which groups reach which application.")
            struct Kept: Encodable { let users: [User]; let bypass: [String]; let notEnrolled: [String]; let lockedOut: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n") + Duo.stopped(listing, "users"),
                                     structured: Kept(users: users, bypass: bypass.map(\.user_id), notEnrolled: unenrolled.map(\.user_id),
                                                      lockedOut: locked.map(\.user_id), complete: listing.complete))
        }
    }

    // MARK: Admins

    struct Admin: Codable, Sendable {
        let admin_id: String?, name: String?, email: String?, role: String?, status: String?, last_login: Loose?, created: Loose?
        let phone: String?, restricted_by_admin_units: Bool?, password_change_required: Bool?
        let hardtoken: Token?, webauthncredentials: [SecurityKey]?, phone_details: [Phone]?

        /// Whether it signs in to the Admin Panel with something a phishing site cannot relay: a hardware token or a
        /// security key.
        var strongFactor: Bool { hardtoken != nil || !(webauthncredentials ?? []).isEmpty }

        var sentence: String {
            var parts = ["\(name ?? "?") <\(email ?? "?")>", role ?? "no role shown", status ?? "?"]
            parts.append(last_login?.shown.map { "last logged in \($0)" } ?? "never logged in")
            if restricted_by_admin_units == true { parts.append("restricted to administrative units") }
            parts.append(strongFactor ? "has a hardware token or security key" : "no hardware token or security key")
            return parts.joined(separator: ", ") + " [\(admin_id ?? "?")]"
        }
    }

    struct Admins: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "admins"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Every Duo administrator with their role, status and last login, owners first, flagging those without a hardware token or security key for the Admin Panel, and those who never logged in or must change their password."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Duo.read(.admins) { try await Duo.list(service, ["admin", "v1", "admins"], limit: 500, as: Admin.self) }
            let admins = listing.value.sorted { first, second in
                let owner = (first.role == "Owner", second.role == "Owner")
                return owner.0 != owner.1 ? owner.0 : (first.email ?? "") < (second.email ?? "")
            }
            let owners = admins.filter { $0.role == "Owner" }
            let weak = admins.filter { !$0.strongFactor && $0.status == "Active" }
            var lines = [admins.isEmpty ? "No administrators\(listing.complete ? "" : " in what was read")."
                : "\(admins.count) administrator\(admins.count == 1 ? "" : "s"), \(owners.count) owner\(owners.count == 1 ? "" : "s")."]
            lines += Duo.capped(admins.map(\.sentence), 40)
            if !weak.isEmpty {
                lines.append("\(weak.count) active administrator\(weak.count == 1 ? " has" : "s have") no hardware token or security key, so they sign in to the Admin Panel with a phone factor a phishing site can relay: \(weak.prefix(10).compactMap(\.email).joined(separator: ", ")).")
            }
            if owners.count > 3 { lines.append("\(owners.count) owners: each can change everything, Admin API applications included.") }
            let never = admins.filter { $0.last_login?.date == nil }
            if !never.isEmpty { lines.append("Never logged in: \(never.prefix(10).compactMap(\.email).joined(separator: ", ")).") }
            struct Kept: Encodable { let admins: [Admin]; let withoutStrongFactor: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n") + Duo.stopped(listing, "administrators"),
                                     structured: Kept(admins: admins, withoutStrongFactor: weak.compactMap(\.email), complete: listing.complete))
        }
    }

    // MARK: Applications

    struct Integration: Decodable, Sendable {
        let integration_key: String?, name: String?, type: String?, policy_key: String?, user_access: String?, groups_allowed: [Loose]?
        let networks_for_api_access: String?, sensitivity_level: String?, notes: String?
        let adminapi_admins: Loose?, adminapi_admins_read: Loose?, adminapi_integrations: Loose?, adminapi_read_log: Loose?
        let adminapi_read_resource: Loose?, adminapi_write_resource: Loose?, adminapi_settings: Loose?, adminapi_info: Loose?
        let adminapi_allow_to_set_permissions: Loose?

        /// The Admin API permissions it holds, by the names the Admin Panel gives them.
        var grants: [String] {
            let named: [(Loose?, String)] = [(adminapi_admins, "Grant administrators - Write"), (adminapi_admins_read, "Grant administrators - Read"),
                                             (adminapi_integrations, "Grant applications"), (adminapi_settings, "Grant settings"),
                                             (adminapi_read_log, "Grant read log"), (adminapi_read_resource, "Grant resource - Read"),
                                             (adminapi_write_resource, "Grant resource - Write"), (adminapi_info, "Grant read information"),
                                             (adminapi_allow_to_set_permissions, "Grant set Admin API permissions")]
            return named.filter { $0.0?.text == "1" || $0.0?.text == "true" }.map(\.1)
        }

        /// Whether its keys can change users, admins, applications, permissions or settings.
        var canChangeDuo: Bool {
            [adminapi_admins, adminapi_integrations, adminapi_settings, adminapi_write_resource, adminapi_allow_to_set_permissions]
                .contains { $0?.text == "1" || $0?.text == "true" }
        }

        var sentence: String {
            var parts = ["\(name ?? "?") (\(type ?? "?"))"]
            switch user_access {
            case "ALL_USERS": parts.append("all users")
            case "NO_USERS": parts.append("no users")
            case "PERMITTED_GROUPS": parts.append("\(groups_allowed?.count ?? 0) permitted group\(groups_allowed?.count == 1 ? "" : "s")")
            default: break
            }
            parts.append(policy_key.map { "custom policy \($0)" } ?? "global policy")
            if let level = sensitivity_level { parts.append("\(level) sensitivity") }
            if type == "adminapi" {
                parts.append(grants.isEmpty ? "no permissions" : grants.joined(separator: ", "))
                let networks = networks_for_api_access?.trimmingCharacters(in: .whitespaces) ?? ""
                parts.append(networks.isEmpty ? "from any network" : "only from \(networks)")
            }
            return parts.joined(separator: ", ") + " [\(integration_key ?? "?")]"
        }
    }

    struct Integrations: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "integrations"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Every application Duo protects, with its type, who may use it, and the policy assigned, led by the Admin API applications that can change Duo, with their permissions and the networks they may be used from. Secret keys are never shown."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Duo.read(.resources) { try await Duo.list(service, ["admin", "v3", "integrations"], limit: 500, as: Integration.self) }
            let all = listing.value
            let admin = all.filter { $0.type == "adminapi" }
            let writers = admin.filter(\.canChangeDuo)
            let anywhere = admin.filter { ($0.networks_for_api_access ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            var lines = [all.isEmpty ? "No applications\(listing.complete ? "" : " in what was read")."
                : "\(all.count) application\(all.count == 1 ? "" : "s"), \(admin.count) of them Admin API."]
            if !writers.isEmpty {
                lines.append("Admin API applications that can change Duo (\(writers.count)): " + writers.map(\.sentence).joined(separator: "; ") + ".")
            }
            if !anywhere.isEmpty { lines.append("\(anywhere.count) Admin API application\(anywhere.count == 1 ? "" : "s") can be used from any network.") }
            let open = all.filter { $0.type != "adminapi" && $0.user_access == "ALL_USERS" && $0.policy_key == nil }
            if !open.isEmpty { lines.append("\(open.count) application\(open.count == 1 ? "" : "s") let every user in under the global policy alone.") }
            lines += Duo.capped(all.filter { !$0.canChangeDuo }.map(\.sentence), 40)
            struct Kept: Encodable {
                struct Application: Encodable {
                    let key: String?, name: String?, type: String?, policy: String?, userAccess: String?, groupsAllowed: Int, permissions: [String], networks: String?
                }
                let applications: [Application]; let complete: Bool
            }
            let kept = all.map { Kept.Application(key: $0.integration_key, name: $0.name, type: $0.type, policy: $0.policy_key, userAccess: $0.user_access,
                                                  groupsAllowed: $0.groups_allowed?.count ?? 0, permissions: $0.grants, networks: $0.networks_for_api_access) }
            return try ServiceResult(text: lines.joined(separator: "\n") + Duo.stopped(listing, "applications"), structured: Kept(applications: kept, complete: listing.complete))
        }
    }

    // MARK: Phones

    struct Phones: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "phones"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Every phone, counted by platform, led by those Duo reports jailbroken or rooted, unencrypted, without a screen lock or biometrics, or never activated for Duo Mobile, and landlines that only take calls or SMS, each with its users; device health shows only on Duo Premier and Duo Advantage."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Duo.read(.resources) { try await Duo.list(service, ["admin", "v1", "phones"], limit: 500, as: Phone.self) }
            let phones = listing.value
            let platforms = Dictionary(grouping: phones) { $0.platform?.isEmpty == false ? $0.platform! : "Unknown" }
                .map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
            func owners(_ phone: Phone) -> String { (phone.users ?? []).compactMap { $0.username ?? $0.user_id }.joined(separator: ", ") }
            var lines = [phones.isEmpty ? "No phones\(listing.complete ? "" : " in what was read")." : "\(phones.count) phones: \(platforms)."]
            let concerning = phones.filter { !$0.concerns.isEmpty }.sorted { $0.concerns.count > $1.concerns.count }
            lines += Duo.capped(concerning.map { "\($0.sentence), used by \(owners($0).nilIfEmpty ?? "no one")" }, 40)
            let callOnly = phones.filter { phone in
                let can = Set(phone.capabilities ?? [])
                return !can.isEmpty && !can.contains("push") && !can.contains("mobile_otp")
            }
            if !callOnly.isEmpty { lines.append("\(callOnly.count) phone\(callOnly.count == 1 ? "" : "s") can only take calls or SMS, factors a phishing site can relay.") }
            if !phones.isEmpty, !phones.contains(where: { $0.tampered?.isEmpty == false || $0.encrypted?.isEmpty == false }) {
                lines.append("Duo reported no device health for any phone: it does so only on Duo Premier and Duo Advantage, and only for activated Duo Mobile.")
            }
            if concerning.isEmpty, !phones.isEmpty { lines.append("No phone has a health concern Duo reports.") }
            struct Kept: Encodable { let phones: [Phone]; let concerning: [String]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n") + Duo.stopped(listing, "phones"),
                                     structured: Kept(phones: phones, concerning: concerning.compactMap(\.phone_id), complete: listing.complete))
        }
    }

    // MARK: Policies

    /// A policy as the Policies API v2 gives it, its sections kept as JSON.
    struct Policy: Decodable, @unchecked Sendable {
        let policy_key: String?, policy_name: String?, is_global_policy: Bool?
        let sections: [String: Any]

        enum Keys: String, CodingKey { case policy_key, policy_name, is_global_policy, sections }
        struct AnyJSON: Decodable { let value: Any
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { value = NSNull() }
                else if let flag = try? container.decode(Bool.self) { value = flag }
                else if let number = try? container.decode(Double.self) { value = number }
                else if let text = try? container.decode(String.self) { value = text }
                else if let list = try? container.decode([AnyJSON].self) { value = list.map(\.value) }
                else if let object = try? container.decode([String: AnyJSON].self) { value = object.mapValues(\.value) }
                else { value = NSNull() }
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            policy_key = try? container.decode(String.self, forKey: .policy_key)
            policy_name = try? container.decode(String.self, forKey: .policy_name)
            is_global_policy = try? container.decode(Bool.self, forKey: .is_global_policy)
            sections = ((try? container.decode([String: AnyJSON].self, forKey: .sections)) ?? [:]).mapValues(\.value)
        }

        func section(_ name: String) -> [String: Any] { sections[name] as? [String: Any] ?? [:] }

        /// A list Duo gives as a comma-separated string or as an array.
        static func list(_ value: Any?) -> [String] {
            if let text = value as? String { return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            return (value as? [Any])?.compactMap { $0 as? String } ?? []
        }

        /// What it lets through that an audit asks about. A section a custom policy leaves out follows the global one.
        var gaps: [String] {
            var found: [String] = []
            let methods = section("authentication_methods")
            if !methods.isEmpty {
                // Duo allows every method its blocked list leaves out, whatever the allowed list names.
                let blocked = Set(Self.list(methods["blocked_auth_list"]))
                let weak = ["sms", "phonecall"].filter { !blocked.contains($0) }
                if !weak.isEmpty { found.append("allows \(weak.map { $0 == "sms" ? "SMS passcodes" : "phone calls" }.joined(separator: " and ")), which a phishing site can relay") }
                if !blocked.contains("bypass") { found.append("accepts bypass codes") }
                if !blocked.contains("duo-push"), methods["require_verified_push"] as? Bool == false { found.append("allows Duo Push without Verified Push, so a user can approve a push they did not start") }
            }
            if section("new_user")["new_user_behavior"] as? String == "no-mfa" {
                found.append("lets users unknown to Duo in without a second factor (new user policy no-mfa)")
            }
            if section("authentication_policy")["user_auth_behavior"] as? String == "bypass" { found.append("skips the second factor for everyone (authentication policy bypass)") }
            let networks = section("authorized_networks")
            let skip = Self.list((networks["no_2fa_required"] as? [String: Any])?["ip_list"])
            if !skip.isEmpty { found.append("skips the second factor from \(skip.prefix(5).joined(separator: ", "))\(skip.count > 5 ? " and \(skip.count - 5) more" : "")") }
            let remembered = section("remembered_devices")
            if let browser = remembered["browser_apps"] as? [String: Any], browser["enabled"] as? Bool != false {
                for method in ["user_based", "risk_based"] {
                    guard let settings = browser[method] as? [String: Any], let value = (settings["max_time_value"] as? Double).map(Int.init) else { continue }
                    let days = (settings["max_time_units"] as? String) == "days" ? value : value / 24
                    if days > 7 { found.append("remembers browsers for \(days) days (\(method.replacingOccurrences(of: "_", with: "-")))") }
                }
            }
            if section("tampered_devices")["block_tampered_devices"] as? Bool == false { found.append("lets jailbroken or rooted phones approve") }
            if section("screen_lock")["require_screen_lock"] as? Bool == false { found.append("lets phones without a screen lock approve") }
            if section("anonymous_networks")["anonymous_access_behavior"] as? String == "no-action" { found.append("takes no action on anonymous networks such as Tor") }
            return found
        }
    }

    struct PolicySummary: Decodable {
        struct Applied: Decodable { let app_name: String?; let apply_type: String? }
        struct Item: Decodable { let policy_key: String?; let policy_name: String?; let policy_applies_to: [Applied]? }
        let policies: [Item]?
    }

    struct Policies: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "policies"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The global policy and every custom policy, with the applications each applies to, led by what they let through: SMS or phone calls allowed, bypass codes accepted, Duo Push without Verified Push, new users let in without a second factor, everyone bypassed, networks that skip Duo, browsers remembered for long, jailbroken phones or phones without a screen lock allowed, and anonymous networks not acted on. It says what the policies allow, not who logged in under them, which auth-logs shows."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let global: Policy
            do {
                global = try await Duo.read(.resources) { try await Duo.get(service, ["admin", "v2", "policies", "global"], as: Policy.self).value }
            } catch ServiceError.notFound {
                throw ServiceError.input("Duo has no Policies API for this account (it answered 404): its edition or age may not offer it. Read the policies in the Admin Panel under **Policies**.")
            }
            let listing = try await Duo.read(.resources) { try await Duo.list(service, ["admin", "v2", "policies"], limit: 100, pages: 5, as: Policy.self) }
            let custom = listing.value.filter { $0.is_global_policy != true }
            var applied: [String: [String]] = [:]
            if let summary = try? await Duo.get(service, ["admin", "v2", "policies", "summary"], as: PolicySummary.self).value {
                for item in summary.policies ?? [] { applied[item.policy_key ?? ""] = (item.policy_applies_to ?? []).compactMap(\.app_name) }
            }
            var lines: [String] = []
            let globalGaps = global.gaps
            lines.append("Global policy: " + (globalGaps.isEmpty ? "nothing Pion checks lets anyone through." : globalGaps.joined(separator: "; ") + "."))
            for policy in custom {
                let apps = applied[policy.policy_key ?? ""] ?? []
                let gaps = policy.gaps
                lines.append("\(policy.policy_name ?? "?") [\(policy.policy_key ?? "?")], on \(apps.isEmpty ? "no application" : apps.prefix(6).joined(separator: ", ") + (apps.count > 6 ? " and \(apps.count - 6) more" : "")): "
                             + (gaps.isEmpty ? "nothing Pion checks beyond the global policy." : gaps.joined(separator: "; ") + "."))
            }
            lines.append("A custom policy changes only the sections it sets; the rest follow the global policy. Some sections exist only on Duo Premier and Duo Advantage.")
            struct Kept: Encodable { struct Item: Encodable { let key: String?; let name: String?; let global: Bool; let appliesTo: [String]; let gaps: [String] }; let policies: [Item]; let complete: Bool }
            let kept = [Kept.Item(key: global.policy_key, name: global.policy_name, global: true, appliesTo: [], gaps: globalGaps)]
                + custom.map { Kept.Item(key: $0.policy_key, name: $0.policy_name, global: false, appliesTo: applied[$0.policy_key ?? ""] ?? [], gaps: $0.gaps) }
            return try ServiceResult(text: lines.joined(separator: "\n") + Duo.stopped(listing, "policies"), structured: Kept(policies: kept, complete: listing.complete))
        }
    }

    // MARK: Bypass codes

    struct BypassCodes: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "bypass-codes"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Every bypass code's metadata, by user: how many each holds, when made and by which administrator, led by codes that never expire or can be used without limit. Duo's API never gives the codes themselves, and Pion never shows them."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Duo.read(.resources) { try await Duo.list(service, ["admin", "v1", "bypass_codes"], limit: 500, as: BypassCode.self) }
            let codes = listing.value
            let grouped: [String: [BypassCode]] = Dictionary(grouping: codes) { (code: BypassCode) -> String in code.user?.username ?? code.user?.user_id ?? "?" }
            func rank(_ held: [BypassCode]) -> (Int, Int) { (held.filter(\.neverExpires).count, held.count) }
            let byUser: [(key: String, value: [BypassCode])] = grouped.sorted { (first, second) -> Bool in rank(first.value) > rank(second.value) }
            let forever = codes.filter(\.neverExpires).count, unlimited = codes.filter(\.unlimited).count
            let old = codes.filter { ($0.created?.date ?? .distantFuture) < Date().addingTimeInterval(-90 * 86_400) }.count
            var lines = [codes.isEmpty ? "No bypass codes\(listing.complete ? "" : " in what was read")."
                : "\(codes.count) bypass code\(codes.count == 1 ? "" : "s") held by \(byUser.count) user\(byUser.count == 1 ? "" : "s"): \(forever) never expire, \(unlimited) can be used without limit, \(old) are over 90 days old."]
            lines += Duo.capped(byUser.map { (user: String, held: [BypassCode]) -> String in "\(user): " + Duo.describe(held) }, 40)
            struct Holder: Encodable { let user: String; let codes: Int; let neverExpire: Int; let unlimited: Int; let newest: String?; let madeBy: [String] }
            struct Kept: Encodable { let holders: [Holder]; let total: Int; let complete: Bool }
            let holders: [Holder] = byUser.map { (user: String, held: [BypassCode]) -> Holder in
                let newest: Date? = held.compactMap { (code: BypassCode) -> Date? in code.created?.date }.max()
                let makers: [String] = Array(Set(held.compactMap(\.admin_email))).sorted()
                return Holder(user: user, codes: held.count, neverExpire: held.filter(\.neverExpires).count, unlimited: held.filter(\.unlimited).count,
                              newest: newest.map(Duo.iso), madeBy: makers)
            }
            return try ServiceResult(text: lines.joined(separator: "\n") + Duo.stopped(listing, "bypass codes"),
                                     structured: Kept(holders: holders, total: codes.count, complete: listing.complete))
        }
    }
}

private extension String {
    /// Nil for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
