import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Entra ID Detection's reads for assessing how the tenant is set up: its Conditional Access policies, and
/// its authentication methods policy with security defaults, each said plainly with the facts an assessment asks about
/// first. They read through Policy.Read.All, which only reads, and Global Reader may read them.
extension Entra {
    /// The most apps named by asking for each, one request each.
    static let appLookups = 20

    /// Apps whose IDs are the same in every tenant, named without asking.
    static let knownApps: [String: String] = [
        graphApp: "Microsoft Graph", "797f4846-ba00-4fd7-ba43-dac1f8f63013": "Windows Azure Service Management API",
        "00000002-0000-0ff1-ce00-000000000000": "Office 365 Exchange Online", "00000003-0000-0ff1-ce00-000000000000": "Office 365 SharePoint Online",
        "00000004-0000-0ff1-ce00-000000000000": "Skype for Business Online", "cc15fd57-2c6c-4117-a88c-83b1d56b4bbe": "Microsoft Teams Services",
        "0000000a-0000-0000-c000-000000000000": "Microsoft Intune", "d4ebce55-015a-49b5-a083-c84d1797ae8c": "Microsoft Intune Enrollment",
        "00000002-0000-0000-c000-000000000000": "Windows Azure Active Directory",
    ]

    /// The users, groups and other directory objects `ids` name, by their display or sign-in name, asked for one by
    /// one up to `nameLookups`; and how many were left unnamed.
    static func objectNames(_ ids: Set<String>, _ service: ServiceClient) async -> (names: [String: String], unnamed: Int) {
        let wanted = ids.filter(isGUID).sorted()
        let found = await withTaskGroup(of: (String, String?).self) { group in
            for id in wanted.prefix(nameLookups) {
                group.addTask {
                    let object = try? await Entra.get(service, ["directoryObjects", id.lowercased()], query: ["$select": "id,displayName,userPrincipalName"],
                                                      as: DirectoryObject.self)
                    return (id, object.map { $0.userPrincipalName ?? $0.displayName ?? $0.id })
                }
            }
            return await group.reduce(into: [(String, String?)]()) { $0.append($1) }
        }
        let names = Dictionary(found.compactMap { id, name in name.map { (id.lowercased(), $0) } }, uniquingKeysWith: { first, _ in first })
        return (names, wanted.count - names.count)
    }

    /// The apps `ids` name by application (client) ID, those known everywhere by name and the rest asked for, up to
    /// `appLookups`.
    static func appNames(_ ids: Set<String>, _ service: ServiceClient) async -> [String: String] {
        var names = knownApps
        let wanted = ids.filter { isGUID($0) && knownApps[$0.lowercased()] == nil }.sorted()
        struct App: Decodable { let displayName: String? }
        let found = await withTaskGroup(of: (String, String?).self) { group in
            for id in wanted.prefix(appLookups) {
                group.addTask {
                    let page = try? await Entra.get(service, ["servicePrincipals"], query: ["$filter": "appId eq '\(id.lowercased())'", "$select": "displayName"],
                                                    as: Page<App>.self)
                    return (id, page?.value.first?.displayName)
                }
            }
            return await group.reduce(into: [(String, String?)]()) { $0.append($1) }
        }
        for (id, name) in found { if let name { names[id.lowercased()] = name } }
        return names
    }

    /// Whether security defaults are on, or why that was not read.
    static func securityDefaults(_ service: ServiceClient) async -> (enabled: Bool?, gap: String?) {
        struct Defaults: Decodable { let isEnabled: Bool? }
        do {
            let defaults = try await read(.securityDefaults) {
                try await get(service, ["policies", "identitySecurityDefaultsEnforcementPolicy"], as: Defaults.self)
            }
            guard let enabled = defaults.isEnabled else { return (nil, "Microsoft Graph did not say whether security defaults are on.") }
            return (enabled, nil)
        } catch {
            return (nil, "Whether security defaults are on was not read: \(error.localizedDescription)")
        }
    }
}

// MARK: - Conditional Access

extension Entra {
    /// A Conditional Access policy as Graph lists it; its conditions and controls are kept as Graph gives them.
    struct AccessPolicy: Codable, Sendable {
        let id: String, displayName: String?, state: String?, createdDateTime: String?, modifiedDateTime: String?
        let conditions: GoogleCloud.JSON?, grantControls: GoogleCloud.JSON?, sessionControls: GoogleCloud.JSON?
    }

    /// A named location: IP ranges or countries, and whether it is marked trusted.
    struct NamedLocation: Codable, Sendable {
        struct Range: Codable, Sendable { let cidrAddress: String? }
        enum CodingKeys: String, CodingKey { case type = "@odata.type", id, displayName, isTrusted, ipRanges, countriesAndRegions, includeUnknownCountriesAndRegions }
        let type: String?, id: String, displayName: String?, isTrusted: Bool?, ipRanges: [Range]?, countriesAndRegions: [String]?
        let includeUnknownCountriesAndRegions: Bool?

        /// The ranges that hold a great part of the internet: an IPv4 range of /8 or wider, an IPv6 one of /32 or wider.
        var broadRanges: [String] {
            (ipRanges ?? []).compactMap(\.cidrAddress).filter { range in
                guard let bits = range.split(separator: "/").last.flatMap({ Int($0) }) else { return false }
                return range.contains(":") ? bits <= 32 : bits <= 8
            }
        }
    }

    /// Conditional Access policies with every condition and control, and the facts an assessment asks first: whether
    /// MFA is required of everyone and of admins, whether legacy authentication is blocked, which policies only report,
    /// and whom enforcing policies leave out.
    struct ConditionalAccess: ServiceOperation {
        struct Input: Decodable, Sendable { let state: String?, limit: Int? }
        static let name = "conditional-access"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The Conditional Access policies, enabled, report-only and disabled, each with whom it includes and excludes by user, group, role and guest, its apps, locations, platforms, client apps, risk levels, grant controls (block, MFA, authentication strength, compliant device) and session controls; led by whether MFA is required for all users and for each privileged role, whether legacy authentication is blocked, which policies only report, whom enforcing policies exclude, broad trusted locations, and whether security defaults are on. Needs Policy.Read.All."
        static let states = ["enabled", "enabledForReportingButNotEnforced", "disabled"]
        static let input = JSONSchema.object([
            "state": .string("Only list policies in this state; the facts above always cover every policy.", oneOf: states),
            "limit": .integer("How many policies to list, at most. 100 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 policies.") }
            let wanted = input.state?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let wanted, !Self.states.contains(wanted) { throw ServiceError.input("A state is enabled, enabledForReportingButNotEnforced or disabled.") }
            let listing = try await Entra.read(.accessPolicies) {
                try await Entra.list(service, ["identity", "conditionalAccess", "policies"], query: [:], as: AccessPolicy.self)
            }
            let policies = listing.value.sorted { ($0.displayName ?? $0.id).lowercased() < ($1.displayName ?? $1.id).lowercased() }
            var gaps: [String] = []
            // Names for what the policies name by ID, each read as far as it can be; what is not named shows its ID.
            var locations: [String: NamedLocation] = [:]
            do {
                let read = try await Entra.read(.accessPolicies) {
                    try await Entra.list(service, ["identity", "conditionalAccess", "namedLocations"], query: [:], as: NamedLocation.self)
                }
                locations = Dictionary(read.value.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
                if !read.complete { gaps.append("Not every named location was read, so some show their ID.") }
            } catch {
                gaps.append("Named locations were not read, so they show their ID: \(error.localizedDescription)")
            }
            var roles = Entra.privilegedRoles
            if let found = try? await Entra.roleNames(service) {
                roles.merge(found.names) { first, _ in first }
                if !found.complete { gaps.append("Not every role's name was read, so some show their ID.") }
            } else {
                gaps.append("Role names were not read, so roles other than the privileged ones show their ID.")
            }
            let users = Set(policies.flatMap { policy in ["includeUsers", "excludeUsers", "includeGroups", "excludeGroups"].flatMap { Self.values(policy, "users", $0) } })
            let (objects, unnamed) = await Entra.objectNames(users, service)
            if unnamed > 0 { gaps.append("\(unnamed) user\(unnamed == 1 ? "" : "s") or group\(unnamed == 1 ? "" : "s") could not be named, so they show their ID.") }
            let apps = await Entra.appNames(Set(policies.flatMap { policy in ["includeApplications", "excludeApplications"].flatMap { Self.values(policy, "applications", $0) } }), service)
            let defaults = await Entra.securityDefaults(service)
            if let gap = defaults.gap { gaps.append(gap) }
            let names = Names(objects: objects, roles: roles, apps: apps, locations: locations)

            let enabled = policies.filter { $0.state == "enabled" }, reporting = policies.filter { $0.state == "enabledForReportingButNotEnforced" }
            let disabled = policies.count - enabled.count - reporting.count
            var facts: [String] = [], flagged: [String] = []
            facts.append("\(policies.count) Conditional Access polic\(policies.count == 1 ? "y" : "ies"): \(enabled.count) enabled, \(reporting.count) report-only, \(disabled) disabled."
                         + (defaults.enabled.map { $0 ? " Security defaults are on." : " Security defaults are off." } ?? ""))

            // MFA for everyone: an enabled policy that asks it of all users in all apps, with no condition narrowing when.
            let everyone = enabled.filter { Self.mfa($0) && Self.allUsers($0) && Self.allApps($0) && Self.narrowing($0, names).isEmpty }
            if !everyone.isEmpty {
                facts.append("MFA for all users: required by " + everyone.map { Self.named($0) + (Self.excluded($0, names).map { " (excluding \($0))" } ?? "") }.joined(separator: "; ") + ".")
            } else {
                let partly = enabled.filter { Self.mfa($0) && Self.allUsers($0) }.map { policy in
                    let limits = (Self.allApps(policy) ? [] : ["some apps"]) + Self.narrowing(policy, names)
                    return "\(Self.named(policy)) requires it only for \(limits.joined(separator: ", "))"
                }
                let optional = enabled.filter { Self.offersMFA($0) && !Self.mfa($0) && Self.allUsers($0) }.map { policy in
                    "\(Self.named(policy)) targets All users but lets them \(Self.grant(policy).replacingOccurrences(of: "require ", with: "use "))"
                }
                let scoped = enabled.filter { Self.mfa($0) && !Self.allUsers($0) }.map(Self.named)
                let said = "MFA for all users: no enabled policy targets All users and requires MFA in every app without conditions"
                    + ((partly + optional).isEmpty ? "" : "; " + (partly + optional).joined(separator: "; "))
                    + (scoped.isEmpty ? "" : "; check group-scoped policies such as " + scoped.prefix(5).joined(separator: ", ")
                        + (scoped.count > 5 ? " and \(scoped.count - 5) more" : "") + ", which may reach everyone between them")
                    + (defaults.enabled == true ? ". Security defaults are on, which ask everyone to register for MFA and use it when Microsoft finds it needed." : ".")
                facts.append(said)
                flagged.append(said)
            }

            // MFA for each privileged role: a policy for all apps without conditions that reaches the role and does not exclude it.
            let mfaAllApps = enabled.filter { Self.mfa($0) && Self.allApps($0) && Self.narrowing($0, names).isEmpty }
            let uncovered = Entra.privilegedRoles.keys.sorted { (Entra.privilegedRoles[$0] ?? $0) < (Entra.privilegedRoles[$1] ?? $1) }.filter { role in
                !mfaAllApps.contains { policy in
                    let included = Self.allUsers(policy) || Self.values(policy, "users", "includeRoles").contains { $0.lowercased() == role }
                    return included && !Self.values(policy, "users", "excludeRoles").contains { $0.lowercased() == role }
                }
            }
            if uncovered.isEmpty {
                facts.append("MFA for admins: every privileged role, Global Administrator among them, must use MFA in every app under an enabled policy.")
            } else {
                let said = "MFA for admins: no enabled policy requires MFA in every app without conditions of " + uncovered.map { Entra.privilegedRoles[$0] ?? $0 }.joined(separator: ", ")
                    + (defaults.enabled == true ? ". Security defaults are on, which require MFA of most of these roles." : ".")
                facts.append(said)
                flagged.append(said)
            }

            // Legacy authentication: Exchange ActiveSync and other clients, which cannot do MFA, blocked for everyone.
            let legacy = enabled.filter { Self.blocks($0) && Self.legacyOnly($0) }
            let blocking = legacy.filter { Self.allUsers($0) && Self.allApps($0) }
            if !blocking.isEmpty {
                facts.append("Legacy authentication: blocked for all users by " + blocking.map { Self.named($0) + (Self.excluded($0, names).map { " (excluding \($0))" } ?? "") }.joined(separator: "; ") + ".")
            } else {
                let said = "Legacy authentication: not blocked for all users by any enabled policy"
                    + (legacy.isEmpty ? "" : "; only for some, by " + legacy.map(Self.named).joined(separator: ", "))
                    + (defaults.enabled == true ? ". Security defaults are on, which block it." : ".")
                facts.append(said)
                if defaults.enabled != true { flagged.append(said) }
            }

            if !reporting.isEmpty {
                let said = "Report-only, so not enforced: " + reporting.map { "\(Self.named($0)) (would \(Self.grant($0)))" }.joined(separator: "; ") + "."
                facts.append(said)
                flagged.append(said)
            }
            let exclusions = enabled.filter { Self.mfa($0) || Self.blocks($0) }.compactMap { policy in Self.excluded(policy, names).map { "\(Self.named(policy)) excludes \($0)" } }
            if !exclusions.isEmpty {
                let said = "Exclusions to review, from policies that require MFA or block: " + exclusions.joined(separator: "; ") + "."
                facts.append(said)
                flagged.append(said)
            }
            let trusted = locations.values.filter { $0.isTrusted == true && !$0.broadRanges.isEmpty }.sorted { ($0.displayName ?? $0.id) < ($1.displayName ?? $1.id) }
            if !trusted.isEmpty {
                let said = "Broad trusted locations: " + trusted.map { "\"\($0.displayName ?? $0.id)\" (\($0.broadRanges.joined(separator: ", ")))" }.joined(separator: "; ") + "."
                facts.append(said)
                flagged.append(said)
            }

            let shown = policies.filter { wanted == nil || $0.state == wanted }
            var lines = facts
            lines.append(wanted.map { "Policies in the state \($0):" } ?? "Policies:")
            for policy in shown.prefix(limit) { lines += Self.lines(policy, names) }
            if shown.isEmpty { lines.append("None.") }
            if shown.count > limit { lines.append("\(shown.count - limit) more matched than are listed; narrow by state, or raise limit.") }
            lines += gaps
            if !listing.complete { lines.append(Entra.stopped(listing, "Conditional Access policies").trimmingCharacters(in: .whitespacesAndNewlines) + " The facts above cover only those read.") }

            struct Listed: Encodable {
                let id: String, name: String?, state: String?, modified: String?, said: [String]
                let conditions: GoogleCloud.JSON?, grantControls: GoogleCloud.JSON?, sessionControls: GoogleCloud.JSON?
            }
            struct Kept: Encodable {
                let policies: [Listed]; let facts: [String]; let gaps: [String]; let securityDefaults: Bool?
                let mfaForAllUsers: [String]; let privilegedRolesWithoutMFA: [String]; let legacyBlockedBy: [String]; let reportOnly: [String]
                let matched: Int; let complete: Bool
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                policies: shown.prefix(limit).map { Listed(id: $0.id, name: $0.displayName, state: $0.state, modified: $0.modifiedDateTime, said: Array(Self.lines($0, names).dropFirst()),
                                                           conditions: $0.conditions, grantControls: $0.grantControls, sessionControls: $0.sessionControls) },
                facts: facts, gaps: flagged, securityDefaults: defaults.enabled, mfaForAllUsers: everyone.map(Self.named),
                privilegedRolesWithoutMFA: uncovered.map { Entra.privilegedRoles[$0] ?? $0 }, legacyBlockedBy: blocking.map(Self.named),
                reportOnly: reporting.map(Self.named), matched: shown.count, complete: listing.complete))
        }

        /// What the policies name by ID, by name where it was read.
        struct Names {
            let objects: [String: String], roles: [String: String], apps: [String: String], locations: [String: NamedLocation]

            func object(_ id: String) -> String { objects[id.lowercased()] ?? id }
            func role(_ id: String) -> String { roles[id.lowercased()] ?? id }
            func app(_ id: String) -> String {
                switch id {
                case "All": "all apps"
                case "None": "no app"
                case "Office365": "Office 365"
                case "MicrosoftAdminPortals": "Microsoft admin portals"
                default: apps[id.lowercased()] ?? id
                }
            }
            func location(_ id: String) -> String {
                switch id {
                case "All": "any location"
                case "AllTrusted": "trusted locations"
                default: locations[id.lowercased()].map { "\"\($0.displayName ?? $0.id)\"\($0.isTrusted == true ? " (trusted)" : "")" } ?? id
                }
            }
        }

        static func named(_ policy: AccessPolicy) -> String { "\"\(policy.displayName ?? policy.id)\"" }

        static func values(_ policy: AccessPolicy, _ path: String...) -> [String] {
            path.reduce(policy.conditions) { $0?[$1] }?.strings ?? []
        }

        static func controls(_ policy: AccessPolicy) -> Set<String> { Set((policy.grantControls?["builtInControls"]?.strings ?? []).map { $0.lowercased() }) }

        static func strength(_ policy: AccessPolicy) -> GoogleCloud.JSON? {
            guard let strength = policy.grantControls?["authenticationStrength"], strength != .null else { return nil }
            return strength
        }

        /// Whether it offers MFA, as a built-in control or an authentication strength, whether or not something else will do.
        static func offersMFA(_ policy: AccessPolicy) -> Bool { controls(policy).contains("mfa") || strength(policy) != nil }

        /// The controls besides MFA it names: built-in ones, terms of use and custom controls.
        static func others(_ policy: AccessPolicy) -> [String] {
            Array(controls(policy).subtracting(["mfa"])) + (policy.grantControls?["termsOfUse"]?.strings ?? [])
                + (policy.grantControls?["customAuthenticationFactors"]?.strings ?? [])
        }

        /// Whether it requires MFA: with AND, beside whatever else it names; with OR, only when nothing else will do, as
        /// one choice of a compliant or joined device, an approved app or the like lets people in without MFA.
        static func mfa(_ policy: AccessPolicy) -> Bool {
            guard offersMFA(policy) else { return false }
            if (policy.grantControls?["operator"]?.text ?? "OR").uppercased() == "AND" { return true }
            return others(policy).isEmpty
        }
        static func blocks(_ policy: AccessPolicy) -> Bool { controls(policy).contains("block") }
        static func allUsers(_ policy: AccessPolicy) -> Bool { values(policy, "users", "includeUsers").contains("All") }
        static func allApps(_ policy: AccessPolicy) -> Bool { values(policy, "applications", "includeApplications").contains("All") }

        /// The client app types it applies to, all of them when it names none.
        static func clients(_ policy: AccessPolicy) -> Set<String> {
            let types = Set(values(policy, "clientAppTypes").map { $0.lowercased() })
            return types.isEmpty || types.contains("all") ? ["all"] : types
        }

        /// Whether it reaches legacy authentication: Exchange ActiveSync and other clients, all of them or those alone.
        static func legacyOnly(_ policy: AccessPolicy) -> Bool {
            let types = clients(policy)
            return types.contains("all") || (types.contains("exchangeactivesync") && types.contains("other"))
        }

        /// The conditions besides users and apps that keep it from applying everywhere, said plainly.
        static func narrowing(_ policy: AccessPolicy, _ names: Names) -> [String] {
            var said: [String] = []
            let include = values(policy, "locations", "includeLocations"), exclude = values(policy, "locations", "excludeLocations")
            if !include.isEmpty, !include.contains("All") { said.append("only from " + include.map(names.location).joined(separator: ", ")) }
            if !exclude.isEmpty { said.append("not from " + exclude.map(names.location).joined(separator: ", ")) }
            let platforms = values(policy, "platforms", "includePlatforms")
            if !platforms.isEmpty, !platforms.contains("all") { said.append("only on " + platforms.joined(separator: ", ")) }
            let excludedPlatforms = values(policy, "platforms", "excludePlatforms")
            if !excludedPlatforms.isEmpty { said.append("not on " + excludedPlatforms.joined(separator: ", ")) }
            if !clients(policy).contains("all") { said.append("only for client apps " + clients(policy).sorted().joined(separator: ", ")) }
            for (key, word) in [("signInRiskLevels", "sign-in risk"), ("userRiskLevels", "user risk"), ("servicePrincipalRiskLevels", "app risk")] {
                let levels = values(policy, key)
                if !levels.isEmpty { said.append("only at \(word) " + levels.joined(separator: ", ")) }
            }
            if let filter = policy.conditions?["devices"]?["deviceFilter"]?["rule"]?.text {
                said.append("devices \(policy.conditions?["devices"]?["deviceFilter"]?["mode"]?.text ?? "matching"): \(filter)")
            }
            if let flows = policy.conditions?["authenticationFlows"]?["transferMethods"]?.text { said.append("only for the sign-in flows \(flows)") }
            if !values(policy, "applications", "includeUserActions").isEmpty { said.append("only for the actions " + values(policy, "applications", "includeUserActions").joined(separator: ", ")) }
            if !values(policy, "applications", "includeAuthenticationContextClassReferences").isEmpty { said.append("only for authentication contexts") }
            return said
        }

        /// Whom it leaves out: users, groups, roles and guests, by name; nil when nobody.
        static func excluded(_ policy: AccessPolicy, _ names: Names) -> String? {
            var said = values(policy, "users", "excludeGroups").map { "group \(names.object($0))" }
            said += values(policy, "users", "excludeRoles").map { "role \(names.role($0))" }
            said += values(policy, "users", "excludeUsers").map { $0 == "GuestsOrExternalUsers" ? "guests and external users" : "user \(names.object($0))" }
            if let guests = policy.conditions?["users"]?["excludeGuestsOrExternalUsers"], guests != .null {
                said.append("guests and external users of the kinds \(guests["guestOrExternalUserTypes"]?.text ?? "some")")
            }
            return said.isEmpty ? nil : said.joined(separator: ", ")
        }

        /// Whom it includes.
        static func included(_ policy: AccessPolicy, _ names: Names) -> String {
            var said = values(policy, "users", "includeUsers").map { id -> String in
                switch id {
                case "All": "all users"
                case "None": "nobody"
                case "GuestsOrExternalUsers": "guests and external users"
                default: "user \(names.object(id))"
                }
            }
            said += values(policy, "users", "includeGroups").map { "group \(names.object($0))" }
            said += values(policy, "users", "includeRoles").map { "role \(names.role($0))" }
            if let guests = policy.conditions?["users"]?["includeGuestsOrExternalUsers"], guests != .null {
                said.append("guests and external users of the kinds \(guests["guestOrExternalUserTypes"]?.text ?? "some")")
            }
            return said.isEmpty ? "nobody named" : said.joined(separator: ", ")
        }

        /// What it grants or requires.
        static func grant(_ policy: AccessPolicy) -> String {
            let controls = policy.grantControls?["builtInControls"]?.strings ?? []
            if controls.map({ $0.lowercased() }).contains("block") { return "block access" }
            let words = controls.map { control -> String in
                switch control.lowercased() {
                case "mfa": "MFA"
                case "compliantdevice": "a compliant device"
                case "domainjoineddevice": "a hybrid-joined device"
                case "approvedapplication": "an approved client app"
                case "compliantapplication": "an app protection policy"
                case "passwordchange": "a password change"
                default: control
                }
            } + (strength(policy).map { ["the authentication strength \"\($0["displayName"]?.text ?? "?")\""] } ?? [])
              + (policy.grantControls?["termsOfUse"]?.strings.isEmpty == false ? ["terms of use"] : [])
              + (policy.grantControls?["customAuthenticationFactors"]?.strings.isEmpty == false ? ["a custom control"] : [])
            guard !words.isEmpty else { return "grant access without a control" }
            let joiner = (policy.grantControls?["operator"]?.text ?? "OR").uppercased() == "AND" ? " and " : " or "
            return "require " + words.joined(separator: joiner)
        }

        /// Its session controls, said plainly.
        static func session(_ policy: AccessPolicy) -> [String] {
            let controls = policy.sessionControls
            var said: [String] = []
            if let frequency = controls?["signInFrequency"], frequency["isEnabled"]?.bool == true {
                if frequency["frequencyInterval"]?.text == "everyTime" { said.append("sign in again every time") }
                else if let value = frequency["value"]?.number { said.append("sign in again every \(Int(value)) \(frequency["type"]?.text ?? "")".trimmingCharacters(in: .whitespaces)) }
            }
            if let browser = controls?["persistentBrowser"], browser["isEnabled"]?.bool == true {
                said.append(browser["mode"]?.text == "never" ? "browser sessions never persist" : "browser sessions persist")
            }
            if controls?["applicationEnforcedRestrictions"]?["isEnabled"]?.bool == true { said.append("app-enforced restrictions") }
            if let cloud = controls?["cloudAppSecurity"], cloud["isEnabled"]?.bool == true { said.append("Defender for Cloud Apps \(cloud["cloudAppSecurityType"]?.text ?? "")".trimmingCharacters(in: .whitespaces)) }
            if controls?["disableResilienceDefaults"]?.bool == true { said.append("resilience defaults off") }
            return said
        }

        /// A policy's lines: its name and state, then whom, what and how.
        static func lines(_ policy: AccessPolicy, _ names: Names) -> [String] {
            let state = switch policy.state {
            case "enabled": "enabled"
            case "enabledForReportingButNotEnforced": "report-only"
            case "disabled": "disabled"
            case let other?: other
            case nil: "state not given"
            }
            var lines = ["\(named(policy)) (\(state)\(policy.modifiedDateTime.map { ", changed \($0)" } ?? "")):"]
            lines.append("  Users: \(included(policy, names))\(excluded(policy, names).map { "; excluding \($0)" } ?? "")")
            let apps = values(policy, "applications", "includeApplications").map(names.app), notApps = values(policy, "applications", "excludeApplications").map(names.app)
            lines.append("  Apps: \(apps.isEmpty ? "none named" : apps.joined(separator: ", "))\(notApps.isEmpty ? "" : "; excluding " + notApps.joined(separator: ", "))")
            let conditions = narrowing(policy, names)
            if !conditions.isEmpty { lines.append("  Conditions: " + conditions.joined(separator: "; ")) }
            lines.append("  Grant: \(grant(policy))")
            let controls = session(policy)
            if !controls.isEmpty { lines.append("  Session: " + controls.joined(separator: ", ")) }
            return lines
        }
    }
}

// MARK: - Authentication methods

extension Entra {
    /// The authentication methods policy as Graph gives it; each method's settings differ, so they are kept as given.
    struct MethodsPolicy: Codable, Sendable {
        let id: String?, displayName: String?, lastModifiedDateTime: String?, policyVersion: String?, policyMigrationState: String?
        let reconfirmationInDays: Double?
        let registrationEnforcement: GoogleCloud.JSON?, systemCredentialPreferences: GoogleCloud.JSON?, reportSuspiciousActivitySettings: GoogleCloud.JSON?
        let authenticationMethodConfigurations: [GoogleCloud.JSON]?
    }

    /// Which sign-in methods are on and for whom, the registration campaign, and whether security defaults are on.
    struct AuthMethodsPolicy: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "auth-methods-policy"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The authentication methods policy: each method (passkeys and security keys, Microsoft Authenticator, SMS, voice call, email one-time passcode, Temporary Access Pass, OATH tokens, certificates and external methods) on or off and for which users and groups, with its key settings, such as whether SMS may be used to sign in; the registration campaign; whether the policy has replaced the legacy MFA and password reset ones; and whether security defaults are on; led by weak methods on and whether a phishing-resistant one is. Needs Policy.Read.All."
        static let input = JSONSchema.object([:])

        /// Each method's name, by the ID Graph gives its configuration.
        static let methods = [
            "fido2": "Passkeys (FIDO2)", "microsoftauthenticator": "Microsoft Authenticator", "sms": "SMS", "voice": "Voice call",
            "email": "Email one-time passcode", "temporaryaccesspass": "Temporary Access Pass", "softwareoath": "Third-party software OATH tokens",
            "hardwareoath": "Hardware OATH tokens", "x509certificate": "Certificate-based authentication", "qrcodepin": "QR code",
        ]
        /// Methods an attacker can intercept or take over, by configuration ID.
        static let weak: Set<String> = ["sms", "voice", "email"]
        /// Methods that resist phishing, by configuration ID.
        static let phishingResistant: Set<String> = ["fido2", "x509certificate"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let policy: MethodsPolicy?, failure: Error?
            do {
                policy = try await Entra.read(.methodsPolicy) { try await Entra.get(service, ["policies", "authenticationMethodsPolicy"], as: MethodsPolicy.self) }
                failure = nil
            } catch { policy = nil; failure = error }
            let defaults = await Entra.securityDefaults(service)
            if policy == nil, defaults.enabled == nil, let failure { throw failure }
            let configurations = policy?.authenticationMethodConfigurations ?? []
            let targets = configurations.flatMap { ($0["includeTargets"]?.array ?? []) + ($0["excludeTargets"]?.array ?? []) }
                + (policy?.registrationEnforcement?["authenticationMethodsRegistrationCampaign"]?["includeTargets"]?.array ?? [])
                + (policy?.registrationEnforcement?["authenticationMethodsRegistrationCampaign"]?["excludeTargets"]?.array ?? [])
            let (objects, unnamed) = await Entra.objectNames(Set(targets.compactMap { $0["id"]?.text }), service)
            let whom = { (target: GoogleCloud.JSON) -> String in
                guard let id = target["id"]?.text else { return "?" }
                if id == "all_users" { return "all users" }
                return "\(target["targetType"]?.text ?? "group") \(objects[id.lowercased()] ?? id)"
            }

            var facts: [String] = [], gaps: [String] = [], lines: [String] = []
            if let enabled = defaults.enabled {
                facts.append(enabled ? "Security defaults are on: everyone registers for MFA, admins use it at every sign-in, and legacy authentication is blocked; Conditional Access cannot be used beside them."
                                     : "Security defaults are off, so Conditional Access policies alone decide when MFA is required: conditional-access says whether they do.")
            }
            struct Method: Encodable { let id: String, name: String, state: String, includes: [String], excludes: [String], said: [String], settings: GoogleCloud.JSON }
            var methods: [Method] = []
            for configuration in configurations {
                let id = configuration["id"]?.text ?? "?", key = id.lowercased()
                let name = Self.methods[key] ?? configuration["displayName"]?.text.map { "External method \"\($0)\"" } ?? id
                let state = configuration["state"]?.text ?? "?"
                let includes = (configuration["includeTargets"]?.array ?? []).map(whom), excludes = (configuration["excludeTargets"]?.array ?? []).map(whom)
                var said: [String] = []
                let include = configuration["includeTargets"]?.array ?? []
                if include.contains(where: { $0["isRegistrationRequired"]?.bool == true }) { said.append("registration required") }
                switch key {
                case "sms":
                    let signIn = include.contains { $0["isUsableForSignIn"]?.bool == true }
                    said.append(signIn ? "usable to sign in, not only for MFA" : "for MFA and password reset, not to sign in")
                case "voice":
                    if let office = configuration["isOfficePhoneAllowed"]?.bool { said.append(office ? "office phones allowed" : "office phones not allowed") }
                case "email":
                    if let external = configuration["allowExternalIdToUseEmailOtp"]?.text { said.append("guests' email one-time passcode \(external)") }
                case "fido2":
                    if let attestation = configuration["isAttestationEnforced"]?.bool { said.append(attestation ? "attestation enforced" : "attestation not enforced") }
                    if configuration["keyRestrictions"]?["isEnforced"]?.bool == true { said.append("only some key models \(configuration["keyRestrictions"]?["enforcementType"]?.text ?? "")".trimmingCharacters(in: .whitespaces)) }
                    if configuration["isSelfServiceRegistrationAllowed"]?.bool == false { said.append("people may not register their own") }
                case "microsoftauthenticator":
                    let features = configuration["featureSettings"]
                    for (feature, word) in [("numberMatchingRequiredState", "number matching"), ("displayAppInformationRequiredState", "app name shown"),
                                            ("displayLocationInformationRequiredState", "location shown"), ("companionAppAllowedState", "companion app")] {
                        if let value = features?[feature]?["state"]?.text { said.append("\(word) \(value)") }
                    }
                    let modes = Set(include.compactMap { $0["authenticationMode"]?.text })
                    if !modes.isEmpty { said.append("mode " + modes.sorted().joined(separator: ", ")) }
                    if configuration["isSoftwareOathEnabled"]?.bool == true { said.append("its one-time codes allowed") }
                case "temporaryaccesspass":
                    if let once = configuration["isUsableOnce"]?.bool { said.append(once ? "usable once" : "usable more than once") }
                    if let longest = configuration["maximumLifetimeInMinutes"]?.number { said.append("valid up to \(Okta.spoken(minutes: longest))") }
                case "x509certificate":
                    if let mode = configuration["authenticationModeConfiguration"]?["x509CertificateAuthenticationDefaultMode"]?.text {
                        said.append(mode == "x509CertificateMultiFactor" ? "counts as multifactor" : "counts as a single factor")
                    }
                default: break
                }
                let on = state.lowercased() == "enabled"
                lines.append("\(name): \(on ? "on" : state)" + (on ? " for " + (includes.isEmpty ? "nobody named" : includes.joined(separator: ", ")) + (excludes.isEmpty ? "" : ", excluding " + excludes.joined(separator: ", ")) : "")
                             + (said.isEmpty || !on ? "" : "; " + said.joined(separator: ", ")))
                methods.append(Method(id: id, name: name, state: state, includes: includes, excludes: excludes, said: said, settings: configuration))
            }
            let on = methods.filter { $0.state.lowercased() == "enabled" }
            let weakOn = on.filter { Self.weak.contains($0.id.lowercased()) }
            if !weakOn.isEmpty {
                let said = "Weak methods on: " + weakOn.map { "\($0.name) for \($0.includes.joined(separator: ", "))\($0.said.isEmpty ? "" : " (\($0.said.joined(separator: ", ")))")" }.joined(separator: "; ") + "."
                facts.append(said)
                gaps.append(said)
            } else if policy != nil {
                facts.append("Weak methods on: none of SMS, voice call or email one-time passcode.")
            }
            let resistant = on.filter { Self.phishingResistant.contains($0.id.lowercased()) }
            if policy != nil {
                if resistant.isEmpty {
                    let said = "Phishing-resistant methods on: none; neither passkeys (FIDO2) nor certificates are on. Windows Hello for Business is set up outside this policy."
                    facts.append(said)
                    gaps.append(said)
                } else {
                    facts.append("Phishing-resistant methods on: " + resistant.map { "\($0.name) for \($0.includes.joined(separator: ", "))" }.joined(separator: "; ") + ".")
                }
            }
            if let campaign = policy?.registrationEnforcement?["authenticationMethodsRegistrationCampaign"] {
                let state = campaign["state"]?.text ?? "?"
                let targets = (campaign["includeTargets"]?.array ?? []).map { "\(whom($0))\($0["targetedAuthenticationMethod"]?.text.map { " (\($0))" } ?? "")" }
                facts.append("Registration campaign: \(state == "default" ? "Microsoft-managed" : state)"
                             + (targets.isEmpty || state == "disabled" ? "" : ", asking " + targets.joined(separator: ", ") + " to register")
                             + (campaign["snoozeDurationInDays"]?.number.map { ", snoozed up to \(Int($0)) day\($0 == 1 ? "" : "s") at a time" } ?? "") + ".")
            }
            if let migration = policy?.policyMigrationState {
                let said = switch migration {
                case "migrationComplete": "Migration: complete; this policy alone decides which methods people may use."
                case "preMigration", "migrationInProgress":
                    "Migration: \(migration == "preMigration" ? "not started" : "in progress"); the legacy MFA and self-service password reset settings also still decide which methods people may use, which Microsoft Graph does not read: check them in the admin center."
                default: "Migration: \(migration)."
                }
                facts.append(said)
                if migration != "migrationComplete" { gaps.append(said) }
            }
            if let preferred = policy?.systemCredentialPreferences?["state"]?.text { facts.append("System-preferred MFA: \(preferred).") }
            if let report = policy?.reportSuspiciousActivitySettings?["state"]?.text { facts.append("Reporting suspicious activity: \(report).") }

            var text = facts
            if !lines.isEmpty { text.append("Methods:") }
            text += lines
            if let failure { text.append("The authentication methods policy was not read: \(failure.localizedDescription)") }
            if let gap = defaults.gap { text.append(gap) }
            if unnamed > 0 { text.append("\(unnamed) group\(unnamed == 1 ? "" : "s") or user\(unnamed == 1 ? "" : "s") could not be named, so they show their ID.") }
            struct Kept: Encodable {
                let securityDefaults: Bool?, migrationState: String?, lastModified: String?; let methods: [Method]; let facts: [String]; let gaps: [String]
                let registrationEnforcement: GoogleCloud.JSON?; let complete: Bool
            }
            return try ServiceResult(text: text.joined(separator: "\n"), structured: Kept(
                securityDefaults: defaults.enabled, migrationState: policy?.policyMigrationState, lastModified: policy?.lastModifiedDateTime, methods: methods,
                facts: facts, gaps: gaps, registrationEnforcement: policy?.registrationEnforcement, complete: policy != nil && defaults.gap == nil))
        }
    }
}
