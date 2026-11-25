import Foundation
import NoodleCore
import NoodleToolConnections

/// Google Workspace Detection's reads for auditing how the organisation is set up, through Cloud Identity rather than
/// the Admin SDK: the organisation's current settings, such as 2-step verification enforcement and Drive sharing.
extension GoogleWorkspace {
    /// One page of a Cloud Identity list, whichever list it is.
    struct IdentityPage<Item: Decodable>: Decodable {
        let policies: [Item]?, nextPageToken: String?
        var listed: [Item] { policies ?? [] }
    }

    /// A Cloud Identity list read page after page up to `limit`, and whether there was more. Google keeps every other
    /// parameter the same from page to page, and its pages may come short, so the pages read are bounded too.
    static func identityList<Item: Decodable>(_ client: ServiceClient, _ path: [String], query: [String: String?], pageSize: Int,
                                              limit: Int) async throws -> (items: [Item], more: Bool) {
        var query = query, items: [Item] = []
        query["pageSize"] = String(pageSize)
        for _ in 0..<(limit / pageSize + 10) {
            let page = try await client.get(path, query: query, as: IdentityPage<Item>.self)
            items += page.listed
            guard let next = page.nextPageToken, !next.isEmpty else { return (items, false) }
            if items.count >= limit { return (items, true) }
            query["pageToken"] = next
        }
        return (items, true)
    }

    /// The organisation's current settings from Cloud Identity's Policy API, by setting and the organisational unit or
    /// group each applies to: those an audit asks about first, said plainly, such as whether 2-step verification
    /// is enforced and who files can be shared with, then every other as Google gives it. Google lists only settings
    /// with a value set, by an admin or by Google for the edition, and lets only a super admin read them.
    struct PolicySettings: ServiceOperation {
        struct Input: Decodable, Sendable { let settingType: String?, orgUnit: String?, limit: Int? }
        static let name = "policy-settings"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The organisation's current settings, by setting and the organisational unit or group each applies to: 2-step verification enforcement and methods, less secure apps, session length, passwords, account recovery, Drive external sharing and default link sharing, mail forwarding, outside Chat and Meet, and app access first, said plainly, then every other setting as Google gives it; optionally only settings whose type starts with some text, or one organisational unit's. Google lets only a super admin read them."
        static let input = JSONSchema.object([
            "settingType": .string("Only settings whose type starts with this, such as security.two_step_verification or drive_and_docs."),
            "orgUnit": .string("Only settings that apply to this organisational unit, by its ID, with or without orgUnits/ before it."),
            "limit": .integer("How many settings to list, at most, those an audit asks about first; the rest are counted.", minimum: 1, maximum: 2000),
        ])

        struct Policy: Codable, Sendable {
            struct Query: Codable, Sendable { let query: String?, orgUnit: String?, group: String?, sortOrder: Double? }
            struct Setting: Codable, Sendable { let type: String?, value: GoogleCloud.JSON? }
            let name: String?, customer: String?, policyQuery: Query?, setting: Setting?, type: String?
        }

        /// A setting as listed: where it applies, its value as Google gives it, and what it means where that is known.
        struct Listed: Encodable {
            let settingType: String, title: String?, appliesTo: String, orgUnit: String?, group: String?, sortOrder: Double?, policyType: String?
            let value: GoogleCloud.JSON?, said: [String], policy: String?
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 300
            guard (1...2000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 2000 settings.") }
            var prefix = input.settingType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let given = prefix, given.hasPrefix("settings/") { prefix = String(given.dropFirst("settings/".count)) }
            if prefix?.isEmpty == true { prefix = nil }
            if let prefix, prefix.count > 100 || !prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) {
                throw ServiceError.input("A setting type is letters, digits, underscores and dots, such as security.two_step_verification_enforcement.")
            }
            var unit = input.orgUnit?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let given = unit, given.lowercased().hasPrefix("orgunits/") { unit = String(given.dropFirst("orgUnits/".count)) }
            if unit?.isEmpty == true { unit = nil }
            if let unit, unit.count > 100 || unit.contains(where: { "/?#\\ ".contains($0) }) {
                throw ServiceError.input("Give an organisational unit by its ID, such as 03ph8a2z1enx4lx.")
            }
            var query: [String: String?] = [:]
            // Google's filter is a CEL expression; a dot in the type is escaped in its regular expression.
            if let prefix { query["filter"] = "setting.type.matches('^settings/\(prefix.replacingOccurrences(of: ".", with: "\\\\."))')" }
            let identity = try service.at(host: "cloudidentity.googleapis.com")
            let read: [Policy], more: Bool
            do {
                (read, more) = try await GoogleWorkspace.read(.policies) {
                    try await GoogleWorkspace.identityList(identity, ["v1", "policies"], query: query, pageSize: 100, limit: 5000)
                }
            } catch let error as ServiceError {
                switch error {
                case .notFound, .refused, .status:
                    throw ServiceError.input("Google's Policy API did not give the organisation's settings (\(error.localizedDescription)). It may not be "
                                             + "available for this edition; ask the champion for the Admin console pages for the settings that matter, and say what you could not check.")
                default: throw error
                }
            }
            // Google's filter is kept to here too, so a setting it lets through anyway is not taken for one asked for.
            let pool = read.filter { policy in
                (unit.map { unit in policy.policyQuery?.orgUnit.map { Self.bare($0) == unit } ?? false } ?? true)
                    && (prefix.map { prefix in policy.setting?.type?.lowercased().hasPrefix("settings/" + prefix) ?? false } ?? true)
            }
            let items = pool.map { policy -> Listed in
                let type = policy.setting?.type ?? "?"
                let bare = type.hasPrefix("settings/") ? String(type.dropFirst("settings/".count)) : type
                let known = Self.known[bare]
                let group = policy.policyQuery?.group.flatMap { $0.isEmpty ? nil : $0 }
                let orgUnit = policy.policyQuery?.orgUnit.flatMap { $0.isEmpty ? nil : $0 }
                let applies = group.map { "group \($0)" } ?? orgUnit.map { "org unit \($0)" } ?? "the organisation"
                return Listed(settingType: bare, title: known?.title, appliesTo: applies + (policy.type?.uppercased() == "SYSTEM" ? " (Google's default)" : ""),
                              orgUnit: orgUnit, group: group, sortOrder: policy.policyQuery?.sortOrder, policyType: policy.type,
                              value: policy.setting?.value, said: policy.setting?.value.map { value in known?.say(value) ?? [] } ?? [], policy: policy.name)
            }
            // Those an audit asks about first, in the order below, then the rest by type; within one setting,
            // the highest sort order first, as Google applies that one where several reach someone.
            let rank = Dictionary(Self.keySettings.enumerated().map { ($1.type, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = items.sorted { a, b in
                let (x, y) = (rank[a.settingType] ?? Int.max, rank[b.settingType] ?? Int.max)
                if x != y { return x < y }
                if a.settingType != b.settingType { return a.settingType < b.settingType }
                if (a.sortOrder ?? 0) != (b.sortOrder ?? 0) { return (a.sortOrder ?? 0) > (b.sortOrder ?? 0) }
                return (a.appliesTo, a.policy ?? "") < (b.appliesTo, b.policy ?? "")
            }
            let listed = Array(ordered.prefix(limit))
            let types = Set(items.map(\.settingType))
            let missing = Self.keySettings.filter { key in !types.contains(key.type) && (prefix.map { key.type.hasPrefix($0) } ?? true) }.map(\.title)

            let plural = { (count: Int, one: String, many: String) in "\(count) \(count == 1 ? one : many)" }
            let filters = [prefix.map { "type \($0)" }, unit.map { "org unit \($0)" }].compactMap { $0 }
            var lines: [String] = []
            if pool.isEmpty {
                lines.append("Google's Policy API gave no settings" + (filters.isEmpty ? "" : " for \(filters.joined(separator: " and "))") + ".")
                lines.append("It lists only settings with a value set, by an admin or by Google for the edition; one not listed is at Google's default "
                             + "or not part of this edition. Ask the champion for the Admin console pages for the settings that matter.")
            } else {
                lines.append("\(plural(pool.count, "setting", "settings")) of \(plural(types.count, "kind", "kinds"))"
                             + (filters.isEmpty ? "." : " for \(filters.joined(separator: " and ")).")
                             + " Where several apply to someone, Google applies the one listed first for that setting.")
            }
            var heading: String?
            for item in listed {
                let section = item.title == nil ? "Other settings:" : "Settings an audit checks first:"
                if section != heading { lines.append(section); heading = section }
                let value = item.said.isEmpty ? (item.value?.compact(300) ?? "no value given") : item.said.joined(separator: "; ")
                lines.append("\(item.title.map { "\($0) (\(item.settingType))" } ?? item.settingType), \(item.appliesTo): \(value)")
            }
            if ordered.count > listed.count {
                lines.append("\(ordered.count - listed.count) more matched than are listed; narrow by settingType or orgUnit, or raise limit.")
            }
            if !pool.isEmpty, !missing.isEmpty {
                lines.append("Not listed, so at Google's default or not in this edition: \(missing.joined(separator: ", ")).")
            }
            if more { lines.append(GoogleWorkspace.incomplete("settings") + " The counts cover only those read.") }
            struct Kept: Encodable { let settings: [Listed]; let matched: Int, kinds: Int; let notListed: [String]; let incomplete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(settings: listed, matched: pool.count, kinds: types.count, notListed: pool.isEmpty ? [] : missing, incomplete: more))
        }

        /// An organisational unit's ID without the orgUnits/ Google may give before it.
        static func bare(_ unit: String) -> String {
            unit.lowercased().hasPrefix("orgunits/") ? String(unit.dropFirst("orgUnits/".count)) : unit
        }

        /// A setting's field by name, whether Google gives it in camelCase or snake_case, as its settings page mixes both.
        static func field(_ value: GoogleCloud.JSON, _ name: String) -> GoogleCloud.JSON? {
            guard case .object(let fields) = value else { return nil }
            let wanted = name.lowercased().replacingOccurrences(of: "_", with: "")
            return fields.first { $0.key.lowercased().replacingOccurrences(of: "_", with: "") == wanted }?.value
        }

        static func flag(_ value: GoogleCloud.JSON, _ name: String) -> Bool? {
            switch field(value, name) {
            case .bool(let flag)?: flag
            case .string(let text)?: text.lowercased() == "true" ? true : text.lowercased() == "false" ? false : nil
            default: nil
            }
        }

        static func text(_ value: GoogleCloud.JSON, _ name: String) -> String? {
            switch field(value, name) {
            case .string(let text)?: text
            case .number(let number)?: number.rounded() == number ? String(Int64(number)) : String(number)
            default: nil
            }
        }

        /// A length of time Google gives as seconds, such as "43200s", said in days or hours.
        static func duration(_ value: GoogleCloud.JSON, _ name: String) -> String? {
            guard let said = text(value, name), let seconds = Double(said.hasSuffix("s") ? String(said.dropLast()) : said) else { return nil }
            if seconds == 0 { return "0" }
            if seconds >= 86400, seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(seconds / 86400)) \(seconds == 86400 ? "day" : "days")" }
            if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600)) \(seconds == 3600 ? "hour" : "hours")" }
            return "\(Int(seconds / 60)) minutes"
        }

        /// What a flag set or not means, when Google gives it.
        static func said(_ value: GoogleCloud.JSON, _ name: String, _ yes: String, _ no: String) -> String? {
            flag(value, name).map { $0 ? yes : no }
        }

        /// What an enumerated value means, when Google gives one of these; any other is shown as Google gives it.
        static func said(_ value: GoogleCloud.JSON, _ name: String, _ meanings: [String: String], _ label: String) -> String? {
            text(value, name).map { meanings[$0.uppercased()] ?? "\(label) \($0)" }
        }

        struct Known: Sendable {
            let type: String, title: String
            let say: @Sendable (GoogleCloud.JSON) -> [String]
        }

        /// The settings an audit asks about first, each said plainly from its fields as Google's list of
        /// supported settings names them (https://cloud.google.com/identity/docs/concepts/supported-policy-api-settings).
        static let keySettings: [Known] = [
            Known(type: "security.two_step_verification_enforcement", title: "2-step verification enforcement") { value in
                guard let from = text(value, "enforcedFrom") else { return ["not enforced: no enforcement date is set"] }
                guard let date = ServiceAlert.time(from) else { return ["enforced from \(from)"] }
                return [date <= Date() ? "enforced since \(from)" : "not enforced yet: enforced from \(from)"]
            },
            Known(type: "security.two_step_verification_enrollment", title: "2-step verification enrollment") { value in
                [said(value, "allowEnrollment", "users may turn on 2-step verification", "users may not turn on 2-step verification")].compactMap { $0 }
            },
            Known(type: "security.two_step_verification_enforcement_factor", title: "2-step verification methods") { value in
                [said(value, "allowedSignInFactorSet", ["ALL": "any method allowed, codes by text or call included",
                                                         "NO_TELEPHONY": "any method but codes by text or call",
                                                         "PASSKEY_PLUS_IP_BOUND_SECURITY_CODE": "only passkeys, security keys and security codes bound to an address",
                                                         "PASSKEY_PLUS_SECURITY_CODE": "only passkeys, security keys and security codes",
                                                         "PASSKEY_ONLY": "only passkeys and security keys"], "methods")].compactMap { $0 }
            },
            Known(type: "security.two_step_verification_grace_period", title: "2-step verification grace period") { value in
                [duration(value, "enrollmentGracePeriod").map { "new users have \($0) to turn it on" }].compactMap { $0 }
            },
            Known(type: "security.two_step_verification_device_trust", title: "2-step verification trusted devices") { value in
                [said(value, "allowTrustingDevice", "users may skip it on a device they trust", "asked on every sign-in, no device trusted")].compactMap { $0 }
            },
            Known(type: "security.less_secure_apps", title: "Less secure apps") { value in
                [said(value, "allowLessSecureApps", "allowed: apps may sign in with a password alone, without 2-step verification", "blocked")].compactMap { $0 }
            },
            Known(type: "security.session_controls", title: "Web session length") { value in
                [duration(value, "webSessionDuration").map { "users sign in again after \($0)" }].compactMap { $0 }
            },
            Known(type: "security.password", title: "Password policy") { value in
                [text(value, "minimumLength").map { "at least \($0) characters" },
                 said(value, "allowedStrength", ["STRONG": "strong passwords required", "WEAK": "weak passwords allowed"], "strength"),
                 duration(value, "expirationDuration").map { $0 == "0" ? "never expire" : "expire after \($0)" },
                 said(value, "allowReuse", "old passwords may be reused", "old passwords may not be reused"),
                 said(value, "enforceRequirementsAtLogin", "checked at sign-in", "not checked at sign-in, so older passwords may fall short")].compactMap { $0 }
            },
            Known(type: "security.super_admin_account_recovery", title: "Super admin account recovery") { value in
                [said(value, "enableAccountRecovery", "super admins may recover their own accounts", "super admins may not recover their own accounts")].compactMap { $0 }
            },
            Known(type: "security.user_account_recovery", title: "User account recovery") { value in
                [said(value, "enableAccountRecovery", "users may recover their own accounts", "users may not recover their own accounts")].compactMap { $0 }
            },
            Known(type: "security.advanced_protection_program", title: "Advanced Protection") { value in
                [said(value, "enableAdvancedProtectionSelfEnrollment", "users may enrol themselves", "users may not enrol themselves"),
                 text(value, "securityCodeOption").map { "security codes \($0)" }].compactMap { $0 }
            },
            Known(type: "security.login_challenges", title: "Sign-in challenges") { value in
                [said(value, "enableEmployeeIdChallenge", "employee ID asked when a sign-in looks suspicious", "no employee ID challenge")].compactMap { $0 }
            },
            Known(type: "drive_and_docs.external_sharing", title: "Drive sharing outside the organisation") { value in
                [said(value, "externalSharingMode", ["ALLOWED": "files may be shared outside the organisation",
                                                     "ALLOWLISTED_DOMAINS": "files may be shared outside only with allowlisted domains",
                                                     "DISALLOWED": "files may not be shared outside the organisation"], "sharing"),
                 said(value, "allowPublishingFiles", "files may be published on the web", "files may not be published on the web"),
                 said(value, "warnForExternalSharing", "users are warned before sharing outside", "no warning before sharing outside"),
                 said(value, "allowNonGoogleInvites", "people without a Google account may be invited", "people without a Google account may not be invited"),
                 said(value, "allowReceivingExternalFiles", "users may receive files from outside", "users may not receive files from outside"),
                 said(value, "accessCheckerSuggestions", ["RECIPIENTS_OR_AUDIENCE_OR_PUBLIC": "Drive may suggest sharing with anyone with the link",
                                                          "RECIPIENTS_OR_AUDIENCE": "Drive suggests sharing only with recipients or the organisation",
                                                          "RECIPIENTS_ONLY": "Drive suggests sharing only with recipients"], "access checker")].compactMap { $0 }
            },
            Known(type: "drive_and_docs.general_access_default", title: "Drive default link sharing") { value in
                [said(value, "defaultFileAccess", ["PRIVATE_TO_OWNER": "new files are private to their owner",
                                                   "PRIMARY_AUDIENCE_WITH_LINK": "new files open to the organisation to anyone with the link",
                                                   "PRIMARY_AUDIENCE_WITH_LINK_OR_SEARCH": "new files open to the organisation by link or search"], "default")].compactMap { $0 }
            },
            Known(type: "drive_and_docs.shared_drive_creation", title: "Shared drives") { value in
                [said(value, "allowExternalUserAccess", "people outside may be added to shared drives", "people outside may not be added to shared drives"),
                 said(value, "allowNonMemberAccess", "shared drive files may be shared with non-members", "shared drive files may not be shared with non-members")].compactMap { $0 }
            },
            Known(type: "gmail.auto_forwarding", title: "Mail auto-forwarding") { value in
                [said(value, "enableAutoForwarding", "users may forward their mail automatically", "users may not forward their mail automatically"),
                 said(value, "allowedForwardingDestination", ["ANY_ADDRESS": "to any address", "INTERNAL_ADDRESSES": "only to the organisation's addresses"],
                      "destinations")].compactMap { $0 }
            },
            Known(type: "chat.external_chat_restriction", title: "Chat outside the organisation") { value in
                [said(value, "allowExternalChat", "users may chat with people outside", "users may not chat with people outside"),
                 said(value, "externalChatRestriction", ["NO_RESTRICTION": "with any domain", "TRUSTED_DOMAINS": "only with trusted domains"],
                      "restriction")].compactMap { $0 }
            },
            Known(type: "chat.chat_external_spaces", title: "Chat spaces with outside people") { value in
                [said(value, "enabled", "spaces may include people outside", "spaces may not include people outside"),
                 said(value, "domainAllowlistMode", ["ALL_DOMAINS": "from any domain", "TRUSTED_DOMAINS": "only from trusted domains"], "domains")].compactMap { $0 }
            },
            Known(type: "meet.safety_domain", title: "Who may join the organisation's meetings") { value in
                [said(value, "usersAllowedToJoin", ["SAME_ORGANIZATION_ONLY": "only people in the organisation",
                                                    "LOGGED_IN": "anyone signed in to a Google account",
                                                    "ALL": "anyone, without a Google account too"], "joining")].compactMap { $0 }
            },
            Known(type: "meet.safety_access", title: "Which meetings users may join") { value in
                [said(value, "meetingsAllowedToJoin", ["SAME_ORGANIZATION_ONLY": "only the organisation's",
                                                       "ANY_WORKSPACE_ORGANIZATION": "any Google Workspace organisation's", "ALL": "anyone's"],
                      "meetings")].compactMap { $0 }
            },
            Known(type: "meet.safety_external_participants", title: "Outside participants in meetings") { value in
                [said(value, "enableExternalLabel", "marked as outside the organisation", "not marked as outside")].compactMap { $0 }
            },
            Known(type: "api_controls.unconfigured_third_party_apps", title: "Apps no admin has configured") { value in
                [said(value, "accessLevel", ["BLOCK_ALL": "blocked from the organisation's data",
                                             "ALLOW_SIGN_IN_ONLY": "may only be used to sign in with Google"], "access")].compactMap { $0 }
            },
            Known(type: "api_controls.internal_apps", title: "The organisation's own apps") { value in
                [said(value, "trustInternalApps", "trusted with the organisation's data", "not trusted automatically")].compactMap { $0 }
            },
        ]

        static let known = Dictionary(keySettings.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
