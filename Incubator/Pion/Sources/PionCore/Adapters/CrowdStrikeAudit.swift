import Foundation
import NoodleCore
import NoodleToolConnections

/// CrowdStrike Falcon Detection's reads for auditing how Falcon is set up: its prevention policies with the
/// protections each turns on and the hosts it reaches, and the exclusions that keep Falcon from blocking or seeing
/// what matches them. Each needs a Read scope of its own, and none changes anything.
extension CrowdStrike {
    static let preventionRead = Scope(name: "Prevention policies", access: "Read")
    static let mlExclusionsRead = Scope(name: "Machine Learning Exclusions", access: "Read")
    static let ioaExclusionsRead = Scope(name: "IOA Exclusions", access: "Read")
    static let svExclusionsRead = Scope(name: "Sensor Visibility Exclusions", access: "Read")

    static let preventionNeed = Need(title: "Prevention policies", scope: preventionRead)
    static let mlExclusionsNeed = Need(title: "Machine learning exclusions", scope: mlExclusionsRead)
    static let ioaExclusionsNeed = Need(title: "IOA exclusions", scope: ioaExclusionsRead)
    static let svExclusionsNeed = Need(title: "Sensor visibility exclusions", scope: svExclusionsRead)

    /// Text from a field that may be text, a number or a flag; nil for anything else or when empty.
    fileprivate static func text<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> String? {
        if let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil { return value.isEmpty ? nil : value }
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil { return value.rounded() == value ? String(Int64(value)) : String(value) }
        if let value = (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return String(value) }
        return nil
    }

    /// A host group as a policy or exclusion names it: an object with its ID and name, or its ID alone.
    struct NamedGroup: Decodable, Sendable, Encodable {
        let id: String?, name: String?
        enum Keys: String, CodingKey { case id, name }
        init(from decoder: Decoder) throws {
            if let id = try? decoder.singleValueContainer().decode(String.self) { self.id = id; name = nil; return }
            let container = try decoder.container(keyedBy: Keys.self)
            id = CrowdStrike.text(container, .id)
            name = CrowdStrike.text(container, .name)
        }
        var said: String { name ?? id ?? "a group without an ID" }
    }

    // MARK: Prevention policies

    /// A prevention policy as Falcon gives it, read field by field so a field it leaves out or gives in another shape
    /// is unknown rather than a failure; only its ID must be there.
    struct PreventionPolicy: Decodable, Sendable {
        struct Value: Decodable, Sendable {
            let enabled: Bool?, detection: String?, prevention: String?
            enum Keys: String, CodingKey { case enabled, detection, prevention }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
                detection = CrowdStrike.text(container, .detection)?.uppercased()
                prevention = CrowdStrike.text(container, .prevention)?.uppercased()
            }
        }
        struct Setting: Decodable, Sendable {
            let id: String?, name: String?, type: String?, value: Value?
            enum Keys: String, CodingKey { case id, name, type, value }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                id = CrowdStrike.text(container, .id); name = CrowdStrike.text(container, .name); type = CrowdStrike.text(container, .type)?.lowercased()
                value = (try? container.decodeIfPresent(Value.self, forKey: .value)) ?? nil
            }
            var title: String { name.map { $0.replacingOccurrences(of: "&amp;", with: "&") } ?? id ?? "a setting without a name" }
            /// Whether it is off: a toggle not enabled, or a slider whose prevention, or detection when it has no
            /// prevention, is DISABLED. Nil when Falcon does not say.
            var off: Bool? {
                guard let value else { return nil }
                if type == "toggle" || (value.enabled != nil && value.detection == nil) { return value.enabled.map { !$0 } }
                if let level = value.prevention ?? value.detection { return level == "DISABLED" }
                return nil
            }
            var said: String {
                guard let value else { return "\(title) not given" }
                if let enabled = value.enabled, value.detection == nil { return "\(title) \(enabled ? "on" : "off")" }
                let levels = [value.detection.map { "detection \($0)" }, value.prevention.map { "prevention \($0)" }].compactMap { $0 }
                return "\(title) " + (levels.isEmpty ? "not given" : levels.joined(separator: ", "))
            }
        }
        struct Category: Decodable, Sendable { let name: String?; let settings: [Setting]? }

        let id: String
        let name: String?, description: String?, platform: String?, enabled: Bool?, groups: [NamedGroup]
        let settings: [Setting]
        let createdBy: String?, created: String?, modifiedBy: String?, modified: String?

        enum Keys: String, CodingKey {
            case id, name, description, platform_name, enabled, groups, prevention_settings, created_by, created_timestamp, modified_by, modified_timestamp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard let id = CrowdStrike.text(container, .id) else { throw ServiceError.unreadable }
            self.id = id
            name = CrowdStrike.text(container, .name); description = CrowdStrike.text(container, .description)
            platform = CrowdStrike.text(container, .platform_name); enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
            groups = ((try? container.decodeIfPresent([NamedGroup].self, forKey: .groups)) ?? nil) ?? []
            settings = (((try? container.decodeIfPresent([Category].self, forKey: .prevention_settings)) ?? nil) ?? []).flatMap { $0.settings ?? [] }
            createdBy = CrowdStrike.text(container, .created_by); created = CrowdStrike.text(container, .created_timestamp)
            modifiedBy = CrowdStrike.text(container, .modified_by); modified = CrowdStrike.text(container, .modified_timestamp)
        }

        /// Falcon names each platform's default policy platform_default, and shows it as Default.
        var isDefault: Bool { name?.lowercased() == "platform_default" }
        var title: String { isDefault ? "Default (\(platform ?? "platform unknown"))" : name ?? id }
    }

    /// The protections an audit checks first, by Falcon's ID for each, in the order they are said: tampering,
    /// quarantine, machine learning, then exploit, ransomware and other behaviour-based protections.
    static let keyPreventionSettings = [
        "SensorTamperingProtection", "NextGenAV", "CloudAntiMalware", "OnSensorMLSlider", "AdwarePUP", "OnSensorMLAdwarePUPSlider",
        "IntelPrevention", "PreventSuspiciousProcesses", "ScriptBasedExecutionMonitoring", "MaliciousPowershell", "CredentialDumping",
        "VolumeShadowCopyProtect", "BackupDeletion", "Cryptowall", "FileEncryption", "Locky", "FileSystemAccess", "ProcessHollowing",
        "ApplicationExploitationActivity", "ForceASLR", "ForceDEP", "HeapSprayPreallocation", "NullPageAllocation", "SEHOverwriteProtection",
        "DetectOnWrite", "QuarantineOnWrite", "VulnerableDriverProtection", "SuspiciousKernelDrivers",
    ]

    /// Where a setting stands among those checked first, by its ID or, for one Falcon names otherwise, its name.
    static func keyRank(_ setting: PreventionPolicy.Setting) -> Int? {
        if let id = setting.id, let index = keyPreventionSettings.firstIndex(of: id) { return index }
        let name = setting.title.lowercased()
        if name.contains("tamper") { return 0 }
        if name.hasPrefix("quarantine") { return 1 }
        return nil
    }

    /// One policy as listed, with what it turns off and how many hosts it reaches.
    struct KeptPolicy: Encodable, Sendable {
        let id: String, name: String, platform: String?, enabled: Bool?, isDefault: Bool
        let groups: [String]
        var hosts: Int?
        let keySettings: [String], keyOff: [String], otherOff: [String]
        let createdBy: String?, created: String?, modifiedBy: String?, modified: String?

        var line: String {
            var about = [platform ?? "platform unknown", enabled == false ? "disabled" : enabled == true ? "enabled" : "enabled or not not given"]
            about.append(hosts.map { CrowdStrike.plural($0, "host") } ?? "hosts not counted")
            if !isDefault { about.append(groups.isEmpty ? "no host groups" : "groups " + groups.prefix(10).joined(separator: ", ") + (groups.count > 10 ? " and \(groups.count - 10) more" : "")) }
            if let modified { about.append("modified \(modified)\(modifiedBy.map { " by \($0)" } ?? "")") }
            var line = "\(name) [\(id)] (\(about.joined(separator: "; ")))"
            if !keySettings.isEmpty { line += ": " + keySettings.joined(separator: "; ") }
            if !otherOff.isEmpty { line += "; also off: " + otherOff.prefix(15).joined(separator: ", ") + (otherOff.count > 15 ? " and \(otherOff.count - 15) more" : "") }
            return line
        }
    }

    static func kept(_ policy: PreventionPolicy) -> KeptPolicy {
        let ranked = policy.settings.compactMap { setting in keyRank(setting).map { (setting, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        let key = Set(ranked.compactMap(\.id))
        let others = policy.settings.filter { setting in keyRank(setting) == nil && !(setting.id.map(key.contains) ?? false) }
        return KeptPolicy(id: policy.id, name: policy.title, platform: policy.platform, enabled: policy.enabled, isDefault: policy.isDefault,
                          groups: policy.groups.map(\.said), hosts: nil, keySettings: ranked.map(\.said), keyOff: ranked.filter { $0.off == true }.map(\.title),
                          otherOff: others.filter { $0.off == true }.map(\.title), createdBy: policy.createdBy, created: policy.created,
                          modifiedBy: policy.modifiedBy, modified: policy.modified)
    }

    static func policies(_ count: Int, _ kind: String? = nil) -> String { "\(count) \(kind.map { $0 + " " } ?? "")polic\(count == 1 ? "y" : "ies")" }

    /// The most policies whose hosts are counted, one request each.
    static let memberCounts = 60

    struct PreventionPolicies: ServiceOperation {
        struct Input: Decodable, Sendable { let platform: String?, limit: Int? }
        static let name = "prevention-policies"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Prevention policies by platform, in the order Falcon applies them, each with whether it is enabled, its host groups, how many hosts it reaches and its protections (sensor tampering protection, quarantine, machine learning levels, exploit and ransomware protections), led by disabled policies, hosts on each platform's default policy or whose policy is not yet applied, and protections turned off in enabled policies."
        static let input = JSONSchema.object([
            "platform": .string("Only this platform's policies.", oneOf: CrowdStrike.platforms),
            "limit": .integer("How many policies, at most. 100 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 policies.") }
            let platform = try input.platform.map { try ServiceInput.oneOf($0, CrowdStrike.platforms, "platform") }
            var query: [String: String?] = ["filter": platform.map { "platform_name:'\($0)'" }, "sort": "precedence.asc"]
            let listing: Listing<PreventionPolicy>
            do {
                listing = try await CrowdStrike.read(CrowdStrike.preventionNeed) {
                    try await CrowdStrike.list(service, ["policy", "combined", "prevention", "v1"], query: query, as: PreventionPolicy.self, paging: .offset,
                                               size: min(limit, 500), limit: limit)
                }
            } catch ServiceError.refused {
                // A Falcon that does not sort by precedence lists them as it keeps them; the order is then said to be unknown.
                query["sort"] = nil
                listing = try await CrowdStrike.read(CrowdStrike.preventionNeed) {
                    try await CrowdStrike.list(service, ["policy", "combined", "prevention", "v1"], query: query, as: PreventionPolicy.self, paging: .offset,
                                               size: min(limit, 500), limit: limit)
                }
            }
            let ordered = query["sort"] != nil
            var policies = listing.value.prefix(limit).map(CrowdStrike.kept)
            // Policies listed by platform, each platform's in Falcon's order and its default last, as Falcon applies it
            // to hosts no other policy reaches.
            let platforms = NSOrderedSet(array: policies.map { $0.platform ?? "platform unknown" }).compactMap { $0 as? String }
            policies = platforms.flatMap { name in
                let own = policies.filter { ($0.platform ?? "platform unknown") == name }
                return own.filter { !$0.isDefault } + own.filter(\.isDefault)
            }

            // How many hosts each reaches, as Falcon counts its members, the defaults and enabled ones first.
            let counted = Array((policies.filter(\.isDefault) + policies.filter { !$0.isDefault && $0.enabled != false }).prefix(CrowdStrike.memberCounts))
            var gaps: [String] = []
            let counts = await withTaskGroup(of: (String, Result<Int?, Error>).self) { group in
                for policy in counted {
                    group.addTask {
                        do {
                            let page = try await CrowdStrike.get(service, ["policy", "queries", "prevention-members", "v1"], query: ["id": policy.id, "limit": "1"], as: String.self)
                            _ = try page.items()
                            return (policy.id, .success(page.meta?.pagination?.total))
                        } catch { return (policy.id, .failure(error)) }
                    }
                }
                return await group.reduce(into: [String: Result<Int?, Error>]()) { $0[$1.0] = $1.1 }
            }
            for index in policies.indices {
                if case .success(let total)? = counts[policies[index].id] { policies[index].hosts = total }
            }
            if let failure = counts.values.compactMap({ if case .failure(let error) = $0 { return error }; return nil }).first {
                gaps.append("the hosts some policies reach (\(CrowdStrike.fix(for: failure, CrowdStrike.preventionNeed) ?? failure.localizedDescription))")
            }
            let uncounted = policies.count - counted.count
            if uncounted > 0 { gaps.append("the hosts of \(CrowdStrike.policies(uncounted)) past the first \(CrowdStrike.memberCounts) counted, or disabled") }

            // Hosts whose prevention policy Falcon has not yet applied, by the hosts' own record.
            var notApplied: Int?
            do {
                let filter = ["device_policies.prevention.applied:false", platform.map { "platform_name:'\($0)'" }].compactMap { $0 }.joined(separator: "+")
                let page = try await CrowdStrike.read(CrowdStrike.hostsNeed) {
                    try await CrowdStrike.get(service, ["devices", "queries", "devices", "v1"], query: ["filter": filter, "limit": "1"], as: String.self)
                }
                _ = try page.items()
                notApplied = page.meta?.pagination?.total
                if notApplied == nil { gaps.append("how many hosts have not yet applied their policy (Falcon gave no count)") }
            } catch {
                gaps.append("how many hosts have not yet applied their policy (\(error.localizedDescription))")
            }

            let disabled = policies.filter { $0.enabled == false }
            let defaults = policies.filter(\.isDefault)
            let weakened = policies.filter { $0.enabled != false && !$0.keyOff.isEmpty }
            var lines: [String] = []
            if policies.isEmpty {
                lines.append("Falcon lists no prevention policies\(platform.map { " for \($0)" } ?? "")\(listing.complete ? "" : " in what was read").")
            } else {
                let byPlatform = platforms.map { name in "\(policies.filter { ($0.platform ?? "platform unknown") == name }.count) \(name)" }
                lines.append("\(CrowdStrike.policies(policies.count, "prevention")): \(byPlatform.joined(separator: ", ")).")
                if !disabled.isEmpty {
                    lines.append("Disabled (\(disabled.count)): " + disabled.map { "\($0.name) [\($0.platform ?? "?")]" }.joined(separator: ", ")
                                 + ". A disabled policy protects nothing: hosts in its groups fall to the next policy, or their platform's default.")
                }
                if !defaults.isEmpty {
                    lines.append("On each platform's default policy, which every host no other policy reaches falls to: "
                                 + defaults.map { "\($0.platform ?? "?") \($0.hosts.map { CrowdStrike.plural($0, "host") } ?? "hosts not counted")" }.joined(separator: ", ") + ".")
                }
                if let notApplied { lines.append("Hosts whose prevention policy is not yet applied: \(notApplied).") }
                if weakened.isEmpty {
                    lines.append("No enabled policy turns off a protection checked first.")
                } else {
                    lines.append("Protections turned off in enabled policies:")
                    lines += weakened.map { "⚠ \($0.name) [\($0.platform ?? "?")\($0.hosts.map { ", \(CrowdStrike.plural($0, "host"))" } ?? "")]: " + $0.keyOff.joined(separator: ", ") }
                }
                lines.append(ordered ? "Policy by policy, each platform's in the order Falcon applies them, its default last:" : "Policy by policy (Falcon did not sort them by precedence, so the order is not Falcon's):")
                lines += policies.prefix(40).map(\.line)
                if policies.count > 40 { lines.append("\(policies.count - 40) more in the structured result.") }
            }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")).") }
            let cut = listing.value.count > limit || (listing.more && listing.stopped == nil)
            if cut { lines.append("More policies match than the \(policies.count) kept\(listing.total.map { " (Falcon says \($0))" } ?? ""): give a platform, or raise limit.") }
            else if !listing.complete { lines.append(String(CrowdStrike.stopped(listing, "prevention policies").dropFirst())) }
            struct Kept: Encodable {
                let policies: [KeptPolicy]; let disabled: Int; let weakened: Int; let hostsNotApplied: Int?; let ordered: Bool; let couldNotRead: [String]
                let total: Int?; let complete: Bool
            }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(policies: policies, disabled: disabled.count, weakened: weakened.count, hostsNotApplied: notApplied, ordered: ordered,
                                                      couldNotRead: gaps, total: listing.total, complete: listing.complete && !cut && gaps.isEmpty))
        }
    }

    // MARK: Exclusions

    /// An exclusion of any of the three kinds, as Falcon gives it, read field by field; only its ID must be there.
    struct Exclusion: Decodable, Sendable {
        let id: String
        let value: String?, regexp: String?, excludedFrom: [String], groups: [NamedGroup], global: Bool?
        let name: String?, description: String?, pattern: String?, imageRegex: String?, commandLineRegex: String?, descendants: Bool?
        let createdBy: String?, created: String?, modifiedBy: String?, modified: String?

        enum Keys: String, CodingKey {
            case id, value, regexp_value, excluded_from, groups, applied_globally, name, description, pattern_id, pattern_name, ifn_regex, cl_regex
            case is_descendant_process, created_by, created_on, modified_by, last_modified
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard let id = CrowdStrike.text(container, .id) else { throw ServiceError.unreadable }
            self.id = id
            value = CrowdStrike.text(container, .value); regexp = CrowdStrike.text(container, .regexp_value)
            excludedFrom = ((try? container.decodeIfPresent([String].self, forKey: .excluded_from)) ?? nil) ?? []
            groups = ((try? container.decodeIfPresent([NamedGroup].self, forKey: .groups)) ?? nil) ?? []
            global = (try? container.decodeIfPresent(Bool.self, forKey: .applied_globally)) ?? nil
            name = CrowdStrike.text(container, .name); description = CrowdStrike.text(container, .description)
            pattern = CrowdStrike.text(container, .pattern_name) ?? CrowdStrike.text(container, .pattern_id)
            imageRegex = CrowdStrike.text(container, .ifn_regex); commandLineRegex = CrowdStrike.text(container, .cl_regex)
            descendants = (try? container.decodeIfPresent(Bool.self, forKey: .is_descendant_process)) ?? nil
            createdBy = CrowdStrike.text(container, .created_by); created = CrowdStrike.text(container, .created_on)
            modifiedBy = CrowdStrike.text(container, .modified_by); modified = CrowdStrike.text(container, .last_modified)
        }

        /// Whether it applies to every host: Falcon says so, or names the group all.
        var isGlobal: Bool { global == true || groups.contains { $0.id?.lowercased() == "all" } }
    }

    /// The three kinds of exclusion, each with its endpoints and what it keeps Falcon from doing.
    struct ExclusionKind: Sendable {
        let key: String, title: String, need: Need, path: String
        let effect: String
    }

    static let exclusionKinds = [
        ExclusionKind(key: "ml", title: "Machine learning exclusions", need: mlExclusionsNeed, path: "ml-exclusions",
                      effect: "files matching it are not blocked or uploaded on machine learning's say"),
        ExclusionKind(key: "ioa", title: "IOA exclusions", need: ioaExclusionsNeed, path: "ioa-exclusions",
                      effect: "behaviour matching it does not raise that indicator of attack's detection or prevention"),
        ExclusionKind(key: "sensor-visibility", title: "Sensor visibility exclusions", need: svExclusionsNeed, path: "sv-exclusions",
                      effect: "Falcon stops recording what processes matching it do, so nothing they do is detected or kept"),
    ]

    /// Why a path pattern reaches more than it should, or nil when it names a narrow place. Falcon's patterns take *
    /// within one folder and ** across folders.
    static func broadPath(_ value: String) -> String? {
        let path = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/").lowercased()
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.allSatisfy({ $0.allSatisfy { $0 == "*" } }) { return "matches every file" }
        // The parts after a drive letter or a volume, such as C: or \Device\HarddiskVolume3.
        let isDrive = { (part: String) in (part.count == 2 && part.hasSuffix(":")) || part == "device" || part.hasPrefix("harddiskvolume") }
        let body = Array(parts.drop(while: isDrive))
        if body.count < parts.count, body.allSatisfy({ $0.allSatisfy { $0 == "*" } }) { return "a whole drive" }
        if let first = body.first, first.allSatisfy({ $0 == "*" }) || first == "**" { return "any folder, as it starts with a wildcard" }
        let writable = ["users", "temp", "tmp", "appdata", "downloads", "programdata", "public", "shm"]
        if path.hasSuffix("**"), body.contains(where: { part in writable.contains(part) }) { return "a folder people or programs may write to, and everything below it" }
        if path.hasSuffix("**"), body.count <= 2 { return "a top-level folder and everything below it" }
        return nil
    }

    /// Why an IOA exclusion's patterns reach more than they should, or nil.
    static func broadIOA(_ exclusion: Exclusion) -> String? {
        let any = { (pattern: String?) in pattern.map { [".*", ".+", "^.*$", "(.*)", ".*.*"].contains($0.trimmingCharacters(in: .whitespaces)) } ?? true }
        switch (any(exclusion.imageRegex), any(exclusion.commandLineRegex)) {
        case (true, true): return "any process with any command line"
        case (true, false): return "any program, by its command line alone"
        case (false, true): return "any command line of its program"
        default: return nil
        }
    }

    /// One exclusion as listed.
    struct KeptExclusion: Encodable, Sendable {
        let kind: String, id: String, pattern: String, scope: String, global: Bool, broad: String?
        let excludedFrom: [String], name: String?, indicator: String?, descendants: Bool?
        let createdBy: String?, created: String?, modifiedBy: String?, modified: String?

        var line: String {
            var parts = [global ? "every host" : scope]
            if let broad { parts.append("broad: \(broad)") }
            if !excludedFrom.isEmpty { parts.append("excluded from \(excludedFrom.joined(separator: " and "))") }
            if let indicator { parts.append("indicator \(indicator)") }
            if descendants == true { parts.append("their child processes too") }
            parts.append("created \(created ?? "at a time not given")\(createdBy.map { " by \($0)" } ?? "")")
            if let modified { parts.append("modified \(modified)\(modifiedBy.map { " by \($0)" } ?? "")") }
            return "\(name.map { "\($0): " } ?? "")`\(String(pattern.prefix(300)))` [\(id)] — " + parts.joined(separator: "; ")
        }
    }

    static func kept(_ exclusion: Exclusion, _ kind: ExclusionKind) -> KeptExclusion {
        let pattern: String, broad: String?
        if kind.key == "ioa" {
            pattern = "program \(exclusion.imageRegex ?? ".*"), command line \(exclusion.commandLineRegex ?? ".*")"
            broad = broadIOA(exclusion)
        } else {
            pattern = exclusion.value ?? exclusion.regexp ?? "pattern not given"
            broad = exclusion.value.flatMap(broadPath)
        }
        let scope = exclusion.groups.isEmpty ? "no host groups given" : "groups " + exclusion.groups.prefix(10).map(\.said).joined(separator: ", ")
            + (exclusion.groups.count > 10 ? " and \(exclusion.groups.count - 10) more" : "")
        return KeptExclusion(kind: kind.key, id: exclusion.id, pattern: pattern, scope: scope, global: exclusion.isGlobal, broad: broad,
                             excludedFrom: exclusion.excludedFrom, name: exclusion.name, indicator: exclusion.pattern, descendants: exclusion.descendants,
                             createdBy: exclusion.createdBy, created: exclusion.created, modifiedBy: exclusion.modifiedBy, modified: exclusion.modified)
    }

    struct Exclusions: ServiceOperation {
        struct Input: Decodable, Sendable { let kind: String?, limit: Int? }
        static let name = "exclusions"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Machine learning, IOA and sensor visibility exclusions, each with its pattern, whether it applies to every host or which host groups, what it is excluded from, who made and last changed it and when, led by broad ones: those for every host, and patterns that match every file, a whole drive, any folder or any process. Optionally one kind."
        static let input = JSONSchema.object([
            "kind": .string("Only this kind of exclusion.", oneOf: CrowdStrike.exclusionKinds.map(\.key)),
            "limit": .integer("How many of each kind, at most. 500 when left out.", minimum: 1, maximum: 2000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 500
            guard (1...2000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 2000 of each kind.") }
            let kinds = try input.kind.map { key in
                guard let kind = CrowdStrike.exclusionKinds.first(where: { $0.key == key }) else {
                    throw ServiceError.input("kind is one of \(CrowdStrike.exclusionKinds.map(\.key).joined(separator: ", ")).")
                }
                return [kind]
            } ?? CrowdStrike.exclusionKinds
            var read: [(ExclusionKind, [KeptExclusion], Listing<String>, [String])] = []
            var refused: [(ExclusionKind, Error)] = []
            for kind in kinds {
                do {
                    let (listing, found, missing) = try await CrowdStrike.read(kind.need) {
                        let listing = try await CrowdStrike.list(service, ["policy", "queries", kind.path, "v1"], query: ["sort": "last_modified.desc"], as: String.self,
                                                                 paging: .offset, size: min(limit, 500), limit: limit)
                        let ids = Array(NSOrderedSet(array: listing.value).compactMap { $0 as? String }.prefix(limit))
                        let (found, missing) = try await CrowdStrike.entities(ids, batch: 100, id: { (exclusion: Exclusion) in exclusion.id }) { asked in
                            try await CrowdStrike.get(service, ["policy", "entities", kind.path, "v1"], repeated: ["ids": asked], as: Exclusion.self)
                        }
                        return (listing, found, missing)
                    }
                    read.append((kind, found.map { CrowdStrike.kept($0, kind) }, listing, missing))
                } catch {
                    refused.append((kind, error))
                }
            }
            // With nothing read and every kind refused, the read is refused, in the words of the first refusal.
            if read.isEmpty, let (_, error) = refused.first { throw error }

            func order(_ items: [KeptExclusion]) -> [KeptExclusion] {
                items.enumerated().sorted { a, b in
                    let (x, y) = ((a.element.global ? 0 : 2) + (a.element.broad == nil ? 1 : 0), (b.element.global ? 0 : 2) + (b.element.broad == nil ? 1 : 0))
                    return x != y ? x < y : a.offset < b.offset
                }.map(\.element)
            }
            var lines: [String] = []
            lines.append(read.map { kind, items, _, _ in
                "\(kind.title): \(items.count) (\(items.filter(\.global).count) for every host, \(items.filter { $0.broad != nil }.count) broad)"
            }.joined(separator: "; ") + ".")
            let broad = read.flatMap { kind, items, _, _ in order(items).filter { $0.global || $0.broad != nil }.map { (kind, $0) } }
            if broad.isEmpty {
                lines.append("No exclusion applies to every host or has a broad pattern" + (read.allSatisfy { $0.2.complete && $0.3.isEmpty } ? "." : ", in what was read."))
            } else {
                lines.append("For every host or broad (\(broad.count)):")
                lines += broad.prefix(60).map { kind, item in "⚠ \(kind.title.dropLast()): \(item.line)" }
                if broad.count > 60 { lines.append("\(broad.count - 60) more in the structured result.") }
            }
            for (kind, items, listing, missing) in read where !items.isEmpty || !listing.complete || !missing.isEmpty {
                lines.append("\(kind.title), broad and for every host first (\(kind.effect)):")
                lines += order(items).prefix(60).map { "  " + $0.line }
                if items.count > 60 { lines.append("  \(items.count - 60) more in the structured result.") }
                if !missing.isEmpty { lines.append("  Falcon listed \(CrowdStrike.plural(missing.count, "exclusion")) it then did not describe: \(missing.prefix(10).joined(separator: ", ")).") }
                let cut = listing.more && listing.stopped == nil
                if cut { lines.append("  More match than the \(items.count) kept\(listing.total.map { " (Falcon says \($0))" } ?? ""): raise limit.") }
                else if !listing.complete { lines.append("  " + String(CrowdStrike.stopped(listing, kind.title.lowercased()).dropFirst())) }
            }
            for (kind, error) in refused { lines.append("\(kind.title) not read: \(error.localizedDescription)") }
            struct Part: Encodable { let kind: String; let exclusions: [KeptExclusion]; let total: Int?; let missing: [String]; let complete: Bool }
            struct Kept: Encodable { let kinds: [Part]; let broadOrGlobal: Int; let notRead: [String]; let complete: Bool }
            let parts = read.map { kind, items, listing, missing in
                Part(kind: kind.key, exclusions: order(items), total: listing.total, missing: missing, complete: listing.complete && missing.isEmpty)
            }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(kinds: parts, broadOrGlobal: broad.count, notRead: refused.map { $0.0.key },
                                                      complete: refused.isEmpty && parts.allSatisfy(\.complete)))
        }
    }
}
