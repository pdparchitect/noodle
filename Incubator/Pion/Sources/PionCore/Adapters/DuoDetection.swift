import Foundation
import NoodleCore
import NoodleToolConnections

/// Duo Detection's investigation reads: the authentication, administrator and telephony logs, one user as Duo knows
/// them, and check-access.
extension Duo {
    // MARK: Authentication log

    /// An entry of the v2 authentication log.
    struct AuthLog: Decodable, Sendable {
        struct Place: Decodable, Sendable { let city: String?; let state: String?; let country: String? }
        struct AccessDevice: Decodable, Sendable {
            let ip: String?, hostname: String?, os: String?, os_version: String?, browser: String?, browser_version: String?
            let location: Place?, is_encryption_enabled: Loose?, is_firewall_enabled: Loose?, is_password_set: Loose?
        }
        struct AuthDevice: Decodable, Sendable { let ip: String?; let name: String?; let key: String?; let location: Place? }
        struct Named: Decodable, Sendable { let key: String?; let name: String? }
        let txid: String?, timestamp: Loose?, isotimestamp: String?, result: String?, reason: String?, factor: String?, event_type: String?
        let email: String?, alias: String?, trusted_endpoint_status: String?
        let access_device: AccessDevice?, auth_device: AuthDevice?, application: Named?, user: Named?

        var time: Date? { ServiceAlert.time(isotimestamp) ?? timestamp?.date }

        static func place(_ place: Place?) -> String? {
            let parts = [place?.city, place?.state, place?.country].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    struct AuthLogPage: Decodable, Sendable { let authlogs: [AuthLog]?; let metadata: Metadata? }

    /// One attempt as a result keeps it.
    struct KeptAuth: Encodable {
        let txid: String?, time: String?, result: String?, reason: String?, factor: String?, user: String?, userID: String?, email: String?
        let application: String?, applicationKey: String?, accessIP: String?, accessLocation: String?, accessOS: String?, accessBrowser: String?
        let accessHostname: String?, authDevice: String?, authDeviceIP: String?, authDeviceLocation: String?, trustedEndpoint: String?

        init(_ log: AuthLog) {
            txid = log.txid; time = log.time.map(Duo.iso) ?? log.isotimestamp; result = log.result; reason = log.reason; factor = log.factor
            user = log.user?.name; userID = log.user?.key; email = log.email; application = log.application?.name; applicationKey = log.application?.key
            accessIP = log.access_device?.ip; accessLocation = AuthLog.place(log.access_device?.location)
            accessOS = [log.access_device?.os, log.access_device?.os_version].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            accessBrowser = [log.access_device?.browser, log.access_device?.browser_version].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            accessHostname = log.access_device?.hostname; authDevice = log.auth_device?.name ?? log.auth_device?.key
            authDeviceIP = log.auth_device?.ip; authDeviceLocation = AuthLog.place(log.auth_device?.location); trustedEndpoint = log.trusted_endpoint_status
        }

        var line: String {
            var line = "\(time ?? "?") \(result ?? "?")"
            if let reason, !reason.isEmpty { line += " (\(reason))" }
            line += " \(user ?? userID ?? "?")"
            if let factor { line += " by \(factor)" }
            if let application { line += " to \(application)" }
            if let accessIP { line += " from \(accessIP)" }
            if let accessLocation { line += " (\(accessLocation))" }
            if let accessOS { line += ", \(accessOS)" }
            if let accessBrowser { line += ", \(accessBrowser)" }
            if let authDevice { line += "; approved on \(authDevice)\(authDeviceLocation.map { " in \($0)" } ?? "")" }
            return line + " [\(txid ?? "?")]"
        }
    }

    /// A v2 log's next_offset, as Duo gives it back: a time in milliseconds and a transaction ID, joined by a comma.
    static func logOffset(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 13, parts[0].allSatisfy(\.isNumber), (1...64).contains(parts[1].count),
              parts[1].unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefABCDEF0123456789-").contains) else {
            throw ServiceError.input("Give nextOffset exactly as the last result gave it: a 13-digit time and a transaction ID, joined by a comma.")
        }
        return value
    }

    struct AuthLogs: ServiceOperation {
        struct Input: Decodable, Sendable {
            let user: String?, result: String?, reason: String?, factor: String?, application: String?, ip: String?
            let since: String?, until: String?, limit: Int?, nextOffset: String?
        }
        static let name = "auth-logs"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Duo's authentication log, newest first, by user, result, reason, factor, application and time, with each attempt's access device (IP, location, operating system, browser), the device that approved it and the transaction ID; one page per call, with the offset to read on. Duo keeps 180 days and publishes new attempts about two minutes late."
        static let input = JSONSchema.object([
            "user": .string("The user's Duo username or user ID (DU…)."),
            "result": .string("Only attempts with this result.", oneOf: ["success", "denied", "fraud"]),
            "reason": .string("Only attempts with this reason, as Duo names it, such as user_marked_fraud, location_restricted, anonymous_ip, denied_by_policy or bypass_user."),
            "factor": .string("Only attempts with this factor, as Duo names it, such as duo_push, sms_passcode, phone_call or bypass_code."),
            "application": .string("Only attempts to this application, by its integration key (DI…)."),
            "ip": .string("Only attempts from or approved at this IP address, matched within the page read."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 180 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many attempts, at most. 100 when left out.", minimum: 1, maximum: 1_000),
            "nextOffset": .string("Where to read on from, exactly as the last result gave it, with the same filters and window."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 100
            guard (1...1_000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 1000 attempts.") }
            let (since, until) = try Duo.window(input.since, input.until, days: 1)
            var repeated: [String: [String]] = [:]
            var named: String?
            if let user = input.user {
                // A user ID goes as it is, so the log reads without Grant resource - Read; a username is looked up.
                if Duo.isUserID(user) {
                    let id = try Duo.id(user, prefix: "DU", "the user")
                    repeated["users"] = [id]
                    named = id
                } else {
                    let resolved = try await Duo.resolve(user, on: service)
                    repeated["users"] = [resolved.user_id]
                    named = resolved.named
                }
            }
            if let result = input.result { repeated["results"] = [try ServiceInput.oneOf(result, ["success", "denied", "fraud"], "result")] }
            if let reason = input.reason { repeated["reasons"] = [try Duo.word(reason, "the reason")] }
            if let factor = input.factor { repeated["factors"] = [try Duo.word(factor, "the factor")] }
            if let application = input.application { repeated["applications"] = [try Duo.id(application, prefix: "DI", "the application's integration key")] }
            let ip = try input.ip.map(ServiceInput.ip)
            var query: [String: String?] = ["mintime": Duo.milliseconds(since), "maxtime": Duo.milliseconds(until), "limit": String(limit), "sort": "ts:desc"]
            if let offset = input.nextOffset { query["next_offset"] = try Duo.logOffset(offset) }
            let page = try await Duo.read(.logs) {
                try await Duo.get(service, ["admin", "v2", "logs", "authentication"], query: query, repeated: repeated, as: AuthLogPage.self).value
            }
            let logs = (page.authlogs ?? []).map(KeptAuth.init).filter { log in ip.map { log.accessIP == $0 || log.authDeviceIP == $0 } ?? true }
            let next = page.metadata?.next_offset?.value
            let window = "from \(Duo.iso(since)) to \(Duo.iso(until))\(named.map { " for \($0)" } ?? "")"
            let lines = logs.prefix(25).map(\.line)
            var text = logs.isEmpty ? "No authentication attempts match \(window)\(ip == nil ? "" : " in the page read")."
                : "\(logs.count) attempt\(logs.count == 1 ? "" : "s") \(window), newest first:\n" + lines.joined(separator: "\n")
                    + (logs.count > lines.count ? "\n… and \(logs.count - lines.count) more in the structured result." : "")
            if let next { text += "\nMore attempts match, older than these: call again with nextOffset \(next), the same filters and window." }
            if ip != nil { text += "\nThe IP address was matched within the \((page.authlogs ?? []).count) attempts read; Duo does not search by it." }
            struct Kept: Encodable { let attempts: [KeptAuth]; let since: String; let until: String; let nextOffset: String?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(attempts: logs, since: Duo.iso(since), until: Duo.iso(until), nextOffset: next, complete: next == nil))
        }
    }

    // MARK: Administrator log

    /// An entry of the administrator log.
    struct AdminLog: Decodable, Sendable {
        let action: String?, description: Loose?, isotimestamp: String?, object: Loose?, timestamp: Loose?, username: String?
        var time: Date? { ServiceAlert.time(isotimestamp) ?? timestamp?.date }

        /// What changed, as Duo describes it, on one short line.
        var change: String? {
            guard let text = description?.text, !text.isEmpty else { return nil }
            return String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(240))
        }

        /// The fields Duo's description names, when it is JSON.
        var fields: [String: Any] {
            guard let text = description?.text, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }

        var line: String {
            var line = "\(time.map(Duo.iso) ?? isotimestamp ?? "?") \(action ?? "?") by \(username?.isEmpty == false ? username! : "Duo")"
            if let object = object?.text, !object.isEmpty { line += " on \(object)" }
            if let change { line += ": \(change)" }
            return line
        }
    }

    /// The administrator log from `since`, oldest first: Duo gives at most the 1000 earliest from then.
    static func adminLog(_ service: ServiceClient, since: Date) async throws -> [AdminLog] {
        try await read(.logs) {
            try await get(service, ["admin", "v1", "logs", "administrator"], query: ["mintime": String(Int64(since.timeIntervalSince1970))], as: [AdminLog].self).value
        }
    }

    static let adminLogPage = 1_000

    struct AdminLogs: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?; let until: String?; let action: String?; let admin: String?; let object: String? }
        static let name = "admin-logs"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What Duo administrators and the Admin API changed, newest first, by action (such as bypass_create, user_update, admin_create, policy_update or integration_skey_view), administrator and the user or object changed, with Duo's description of each change. Duo gives the 1000 earliest entries from since at a time, and the result says when more follow."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 180 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "action": .string("Only this action, as Duo names it, such as bypass_create or user_update."),
            "admin": .string("Only changes by this administrator, by the name or email the log shows."),
            "object": .string("Only changes to this user or object, by the name the log shows."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Duo.window(input.since, input.until, days: 1)
            let action = try input.action.map { try Duo.word($0, "the action") }
            let admin = try input.admin.map { try Duo.username($0).lowercased() }
            let object = try input.object.map { try Duo.username($0).lowercased() }
            let read = try await Duo.adminLog(service, since: since)
            let cut = read.count >= Duo.adminLogPage
            let entries = read.filter { entry in
                guard let time = entry.time, time <= until.addingTimeInterval(1) else { return false }
                if let action, entry.action != action { return false }
                if let admin, entry.username?.lowercased() != admin { return false }
                if let object, entry.object?.text?.lowercased() != object { return false }
                return true
            }.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
            let window = "from \(Duo.iso(since)) to \(Duo.iso(until))"
            let lines = entries.prefix(30).map(\.line)
            var text = entries.isEmpty ? "No administrator log entries match \(window)\(cut ? " in what was read" : "")."
                : "\(entries.count) entr\(entries.count == 1 ? "y" : "ies") \(window), newest first:\n" + lines.joined(separator: "\n")
                    + (entries.count > lines.count ? "\n… and \(entries.count - lines.count) more in the structured result." : "")
            let readUntil = read.compactMap(\.time).max()
            if cut { text += "\nIncomplete: Duo gave its 1000 earliest entries from since, up to \(readUntil.map(Duo.iso) ?? "?"); call again with since \(readUntil.map(Duo.iso) ?? "later") for what follows." }
            struct Entry: Encodable { let time: String?; let action: String?; let admin: String?; let object: String?; let description: String? }
            struct Kept: Encodable { let entries: [Entry]; let since: String; let until: String; let complete: Bool; let readUntil: String? }
            let kept = entries.map { Entry(time: $0.time.map(Duo.iso), action: $0.action, admin: $0.username, object: $0.object?.text, description: $0.change) }
            return try ServiceResult(text: text, structured: Kept(entries: kept, since: Duo.iso(since), until: Duo.iso(until), complete: !cut,
                                                                  readUntil: cut ? readUntil.map(Duo.iso) : Duo.iso(until)))
        }
    }

    // MARK: Telephony log

    struct TelephonyLogs: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?; let until: String?; let limit: Int?; let nextOffset: String? }
        static let name = "telephony-logs"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The SMS and phone calls Duo sent, newest first, with the phone number, why (such as an authentication or an administrator login), the credits each used and the transaction it served; one page per call, with the offset to read on. A burst to one number, or calls a user did not ask for, can mean push or call fatigue."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 180 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many, at most. 100 when left out.", minimum: 1, maximum: 1_000),
            "nextOffset": .string("Where to read on from, exactly as the last result gave it, with the same window."),
        ])

        struct Item: Codable, Sendable {
            let telephony_id: String?, txid: String?, ts: Loose?, type: String?, phone: String?, context: String?, credits: Loose?
        }
        struct Page: Decodable { let items: [Item]?; let metadata: Metadata? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 100
            guard (1...1_000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 1000 events.") }
            let (since, until) = try Duo.window(input.since, input.until, days: 1)
            var query: [String: String?] = ["mintime": Duo.milliseconds(since), "maxtime": Duo.milliseconds(until), "limit": String(limit), "sort": "ts:desc"]
            if let offset = input.nextOffset { query["next_offset"] = try Duo.logOffset(offset) }
            let page = try await Duo.read(.logs) { try await Duo.get(service, ["admin", "v2", "logs", "telephony"], query: query, as: Page.self).value }
            let items = page.items ?? []
            let next = page.metadata?.next_offset?.value
            let byPhone = Dictionary(grouping: items) { $0.phone ?? "?" }.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
            let window = "from \(Duo.iso(since)) to \(Duo.iso(until))"
            var text = items.isEmpty ? "Duo sent no SMS or calls \(window)."
                : "\(items.count) SMS or call\(items.count == 1 ? "" : "s") \(window), newest first:\n" + items.prefix(25).map { item in
                    "\(item.ts?.shown ?? "?") \(item.type ?? "?") to \(item.phone ?? "?")\(item.context.map { " for \($0)" } ?? "")\(item.credits?.text.map { ", \($0) credits" } ?? "") [\(item.txid ?? item.telephony_id ?? "?")]"
                }.joined(separator: "\n")
            if items.count > 25 { text += "\n… and \(items.count - 25) more in the structured result." }
            if let top = byPhone.first, top.1 >= 5 { text += "\nMost to one number: \(top.1) to \(top.0)." }
            if let next { text += "\nMore follow, older than these: call again with nextOffset \(next) and the same window." }
            struct Kept: Encodable { let events: [Item]; let since: String; let until: String; let nextOffset: String?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(events: items, since: Duo.iso(since), until: Duo.iso(until), nextOffset: next, complete: next == nil))
        }
    }

    // MARK: One user

    /// A bypass code's metadata, as Duo lists it: never the code itself, which its API does not give.
    struct BypassCode: Codable, Sendable {
        struct Owner: Codable, Sendable { let user_id: String?; let username: String? }
        let bypass_code_id: String?, admin_email: String?, created: Loose?, expiration: Loose?, reuse_count: Loose?, user: Owner?

        var neverExpires: Bool { expiration?.date == nil }
        var unlimited: Bool { reuse_count?.text == nil }
    }

    /// The bypass codes a user holds, counted and dated, never shown.
    static func bypassCodes(of user: String, on service: ServiceClient) async throws -> Listing<BypassCode> {
        try await list(service, ["admin", "v1", "users", user, "bypass_codes"], limit: 500, pages: 1, as: BypassCode.self)
    }

    static func describe(_ codes: [BypassCode]) -> String {
        guard !codes.isEmpty else { return "No bypass codes." }
        let forever = codes.filter(\.neverExpires).count, unlimited = codes.filter(\.unlimited).count
        let newest = codes.compactMap { $0.created?.date }.max().map(Duo.iso) ?? "?"
        let makers = Set(codes.compactMap(\.admin_email)).sorted().prefix(3).joined(separator: ", ")
        var parts = ["\(codes.count) bypass code\(codes.count == 1 ? "" : "s"), the newest made \(newest)"]
        if !makers.isEmpty { parts.append("by \(makers)") }
        if forever > 0 { parts.append("\(forever) never expire\(forever == 1 ? "s" : "")") }
        if unlimited > 0 { parts.append("\(unlimited) can be used without limit") }
        return parts.joined(separator: ", ") + " (Pion never shows the codes)."
    }

    struct UserDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user"
        static let jobs: Set<ToolJob> = [.detection, .audit, .containment]
        static let summary = "One user as Duo knows them: status (and why locked out), whether enrolled, last login, phones with their IDs, platforms and health, hardware tokens and security keys with their IDs, groups, and their bypass codes, counted and dated but never shown. It changes nothing; read it before acting."
        static let input = JSONSchema.object(["user": .string("The user's Duo username, an alias, or user ID (DU…).")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try await Duo.resolve(input.user, on: service)
            var lines = [user.sentence + "."]
            if let email = user.email, !email.isEmpty { lines.append("Email: \(email).") }
            let phones = user.phones ?? [], tokens = user.tokens ?? [], keys = user.webauthncredentials ?? []
            lines.append(phones.isEmpty ? "No phones." : "Phones: " + phones.map(\.sentence).joined(separator: "; ") + ".")
            if !tokens.isEmpty { lines.append("Hardware tokens: " + tokens.map { "\($0.type ?? "?") \($0.serial ?? "") [\($0.token_id ?? "?")]" }.joined(separator: ", ") + ".") }
            if !keys.isEmpty {
                lines.append("Security keys: " + keys.map { key in
                    "\(key.credential_name ?? key.label ?? "?") (\(key.label ?? "?"), added \(key.date_added?.shown ?? "?"), last used \(key.date_last_used?.shown ?? "never")) [\(key.webauthnkey ?? "?")]"
                }.joined(separator: ", ") + ".")
            }
            let groups = user.groups ?? []
            if !groups.isEmpty {
                lines.append("Groups: " + groups.map { "\($0.name ?? "?")\($0.status?.text.map { " (\($0))" } ?? "")" }.joined(separator: ", ")
                             + ". A group's status, such as Bypass, can override the user's own.")
            }
            var codes: [BypassCode]?
            do { codes = try await Duo.read(.resources) { try await Duo.bypassCodes(of: user.user_id, on: service) }.value }
            catch { lines.append("Bypass codes could not be read: \(error.localizedDescription)") }
            if let codes { lines.append(Duo.describe(codes)) }
            lines.append("Read at \(Duo.iso(Date())).")
            struct Kept: Encodable {
                let user: User; let bypassCodes: Int?; let bypassCodesNeverExpiring: Int?
            }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(user: user, bypassCodes: codes?.count, bypassCodesNeverExpiring: codes?.filter(\.neverExpires).count))
        }
    }

    // MARK: Access

    /// One line of check-access: ✓ when the probe worked, else what Duo refused and which permission to tick.
    static func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
        do { try await probe(); return "✓ \(need.title) (\(need.permission))" }
        catch { return "✗ \(need.title): " + (fix(for: error, need) ?? error.localizedDescription) }
    }

    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly which permission to tick on the Duo Admin API application; whether Trust Monitor is available; the account's edition and size; and which Admin API applications can change Duo. It changes nothing."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let now = Date()
            let window: [String: String?] = ["mintime": Duo.milliseconds(now.addingTimeInterval(-3_600)), "maxtime": Duo.milliseconds(now.addingTimeInterval(-120)), "limit": "1"]
            var lines: [String] = []
            lines.append(await Duo.check(.logs) { _ = try await Duo.exchange(service, ["admin", "v2", "logs", "authentication"], query: window) })
            lines.append(await Duo.check(.resources) { _ = try await Duo.exchange(service, ["admin", "v1", "users"], query: ["limit": "1"]) })
            lines.append(await Duo.check(.admins) { _ = try await Duo.exchange(service, ["admin", "v1", "admins"], query: ["limit": "1"]) })
            var trust = await Duo.check(.trustMonitor) { _ = try await Duo.exchange(service, ["admin", "v1", "trust_monitor", "events"], query: window) }
            if trust.hasPrefix("✗"), lines.first?.hasPrefix("✓") == true {
                trust = "· Trust Monitor: Duo refused it though the logs read, so this edition most likely lacks Trust Monitor, part of Duo Premier and Duo Advantage; security-events reads the logs without it."
            }
            lines.append(trust)
            struct Summary: Decodable { let edition: String?; let user_count: Loose?; let admin_count: Loose?; let integration_count: Loose? }
            do {
                let summary = try await Duo.get(service, ["admin", "v1", "info", "summary"], as: Summary.self).value
                lines.append("✓ Account summary (Grant read information): \(summary.edition ?? "unknown edition"), \(summary.user_count?.text ?? "?") users, \(summary.admin_count?.text ?? "?") admins, \(summary.integration_count?.text ?? "?") applications.")
            } catch {
                lines.append("· Account summary: not read (optional): " + (Duo.fix(for: error, .information) ?? error.localizedDescription))
            }
            if let writers = try? await Duo.list(service, ["admin", "v3", "integrations"], limit: 500, pages: 2, as: Integration.self).value
                .filter({ $0.type == "adminapi" && $0.canChangeDuo }) {
                lines.append(writers.isEmpty ? "· No Admin API application can change users, admins, applications or settings."
                    : "· Admin API applications that can change Duo: " + writers.map { "\($0.name ?? "?") (\($0.grants.joined(separator: ", ")))" }.joined(separator: "; ")
                        + ". If this tool's own application is among them, untick those permissions, Grant settings included: Duo Detection only reads.")
            }
            lines.append("· Pion cannot see which application this connection's keys belong to; its permissions are those ticked on it in the Duo Admin Panel.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}

private extension String {
    /// Nil for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
