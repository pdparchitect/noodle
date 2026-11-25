import Foundation
import NoodleCore
import NoodleToolConnections

/// A Duo account's authentication, administrator and telephony logs, its users with their phones, tokens and security
/// keys, its admins, applications, phones, policies, bypass codes and global settings, read through Duo's Admin API.
/// Duo Detection only reads; Duo Containment, a tool of its own with keys of its own, acts.
///
/// Duo's Admin API has no OAuth. Each tool uses an Admin API application's integration key and secret key, kept in
/// Keychain and never seen here: the connection signs each request with them, as Duo's v5 signing asks. What an
/// application may do is set by the permissions ticked on it in the Duo Admin Panel, which check-access reports.
///
/// Both tools' guide is Incubator/Pion/docs/tools/duo.md. Change it with the setup steps, permissions or operations here.
public enum Duo {
    public static let preset = ToolDefinition(
        id: "a36b202b-569a-4959-8dd0-7ba241963902", name: "Duo Detection",
        summary: "Authentication, administrator and telephony logs, users with their devices, admins, applications, phones, policies, bypass codes and settings of a Duo account, read-only.",
        defaultInstructions: """
        Use Duo Detection to learn what happened to an identity behind Duo: auth-logs reads the authentication log by \
        user, result (success, denied or fraud), reason, factor, application and time, with where each attempt came from \
        and the device that approved it; user reads one user's status, phones, hardware tokens, security keys, groups, \
        bypass codes (counted, never shown) and last login; admin-logs reads what administrators changed, and \
        telephony-logs the SMS and calls Duo sent. To audit the account, users leads with users in bypass status, not \
        enrolled or locked out, admins with owners and admins who sign in without a hardware token or security key, \
        integrations with the applications Duo protects and the Admin API applications that can change Duo, phones \
        with tampered, unencrypted or unlocked devices, and policies, settings and bypass-codes with what they let \
        through, such as SMS or phone calls allowed, new users let in without enrolling, long remembered devices, \
        networks that skip Duo, and bypass codes that never expire. The alert watch checks every five minutes and wakes \
        you with a note naming security-events, which reads what it reads for the note's window: fraud users reported, \
        attempts Duo denied from anonymous networks, restricted locations or denied networks, bypass codes created or \
        viewed, users or groups set to bypass, admins added or changed, Admin API applications made or their secret \
        keys viewed, policies and settings changed, and what Trust Monitor surfaced. Duo keeps logs for 180 days and \
        publishes new authentications about two minutes late, and asks that each log be read at most about once a \
        minute, so page through a log slowly. When a tool is refused or something you need seems missing, run \
        check-access and tell the champion exactly which permission it says to tick. Silence is not proof: every result \
        says when it stopped before reading everything. Record what you find as evidence, citing the user, the time \
        window and the transaction ID. These tools only read: recommend disabling a user, removing a device or deleting \
        their bypass codes to the champion, or use Duo Containment, with the user, why, and how to undo it.
        """,
        iconName: "duo",
        configuration: .connection(.init(endpointTemplate: "https://{host}", fields: fields, tokenHeader: "Authorization",
                                         composedToken: keys, adapter: "duo")),
        setup: setup)

    static let fields = [ToolField(key: "host", title: "API hostname", placeholder: "api-xxxxxxxx.duosecurity.com", kind: .host)]
    /// The application's two keys, kept together and never sent: the connection signs each request with them.
    static let keys = ComposedToken(first: "Integration key", second: "Secret key", format: .duoSignature)

    static func applicationSteps(_ name: String, permissions: String) -> [String] {
        [
            "In the Duo Admin Panel, signed in as an administrator with the **Owner** role, which alone can make an Admin API application, open **Applications › Application Catalog**, find **Admin API** and choose **+ Add**. Name it \(name), kept for this tool alone.",
            "Under **Permissions**, \(permissions) Under **Networks for API access** you can limit the application to the networks this Mac uses. Save.",
        ]
    }

    static let keysStep = "Give the **API hostname**, such as `api-xxxxxxxx.duosecurity.com`, and the application's **Integration key** and **Secret key**, then choose **Add & Connect** and ask an agent to run check-access. Duo's Admin API has no OAuth, so these keys are a long-lived secret: Pion keeps them in this Mac's Keychain and uses them only to sign each request, never sending the secret key. Delete the application in Duo to revoke them."

    static let setup = applicationSteps("Pion Detection", permissions: "tick only **Grant read log** and **Grant resource - Read**, which read the logs, users, phones, policies, bypass codes and applications. Add **Grant administrators - Read** to audit admins and **Grant read information** for the account summary check-access shows. **Grant settings** lets agents read the global settings, but Duo has no read-only setting for it: it also lets these keys change them, though Pion only reads, so leave it off unless you want settings audited. Leave every write permission off.") + [keysStep]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        AuthLogs(), AdminLogs(), TelephonyLogs(), UserDetails(), SecurityEvents(), CheckAccess(),
        Users(), Admins(), Integrations(), Phones(), Settings(), Policies(), BypassCodes(),
        DisableUser(), EnableUser(), ClearBypass(), DeleteBypassCodes(), RemovePhone(), RemoveToken(), RemoveSecurityKey(),
        SendEnrollment(), SendActivation(), ContainmentCheckAccess(),
    ]

    /// Paced, as Duo rate limits its logs per account.
    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents(), simultaneousRequests: 2)

    // MARK: Limits

    /// The most pages one listing reads.
    static let maximumPages = 10
    /// How many days Duo keeps its logs.
    static let logDays = 180.0

    // MARK: Inputs

    /// A Duo ID: `prefix` and 18 more upper-case letters and digits, such as DU and 18 more for a user.
    static func id(_ value: String, prefix: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 20, value.hasPrefix(prefix),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains) else {
            throw ServiceError.input("Give \(name) as Duo's ID: \(prefix) and 18 more upper-case letters and digits.")
        }
        return value
    }

    static func isUserID(_ value: String) -> Bool { (try? id(value, prefix: "DU", "the user")) != nil }

    /// A username, as Duo's users listing takes it to look one up: one line, no longer than Duo allows.
    static func username(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceError.input("Give the user's Duo username or user ID (DU…).")
        }
        return value
    }

    /// A value of Duo's own vocabulary, such as a reason or a factor: letters, digits, spaces and a few marks.
    static func word(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 100,
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-()&.").contains) else {
            throw ServiceError.input("Give \(name) as Duo names it, such as user_marked_fraud or duo_push.")
        }
        return value
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func milliseconds(_ date: Date) -> String { String(Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))) }

    /// A window within the logs' 180 days, since before until; `days` back from now when since is left out.
    static func window(_ since: String?, _ until: String?, days: Double, now: Date = Date()) throws -> (since: Date, until: Date) {
        let from: Date? = try since.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantPast } ?? now.addingTimeInterval(-days * 86_400)
        let to: Date? = try until.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantFuture } ?? now
        guard let from, let to, from < to, from >= now.addingTimeInterval(-logDays * 86_400 - 60), to <= now.addingTimeInterval(60) else {
            throw ServiceError.input("Give a time range within the last 180 days, Duo's logs', with since before until.")
        }
        return (from, to)
    }

    // MARK: Values

    /// One of Duo's values as text, whatever JSON type it came as: a string, number or flag, or for an object such as
    /// the admin or application that did something, its name or key.
    struct Loose: Codable, Sendable, Hashable {
        let text: String?

        init(_ text: String?) { self.text = text }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { text = nil }
            else if let value = try? container.decode(String.self) { text = value }
            else if let value = try? container.decode(Bool.self) { text = String(value) }
            else if let value = try? container.decode(Int64.self) { text = String(value) }
            else if let value = try? container.decode(Double.self) { text = String(value) }
            else if let value = try? container.decode([String: Loose].self) { text = value["name"]?.text ?? value["username"]?.text ?? value["key"]?.text }
            else { text = nil }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }

        /// As a moment: a Unix time in seconds, or in milliseconds when that large, or an ISO 8601 time.
        var date: Date? {
            guard let text, !text.isEmpty else { return nil }
            if let number = Double(text) {
                guard number > 0 else { return nil }
                return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1_000 : number)
            }
            return ServiceAlert.time(text) ?? ServiceAlert.time(text + "Z")
        }

        /// As an ISO 8601 time, or the text as Duo gave it.
        var shown: String? { date.map(Duo.iso) ?? (text?.isEmpty == false ? text : nil) }
    }

    /// Where the next page starts, as Duo's metadata gives it: an offset for most listings, a time and transaction for
    /// the v2 logs, as two strings or one joined by a comma.
    struct NextOffset: Decodable, Sendable {
        let value: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) { value = String(number) }
            else if let text = try? container.decode(String.self) { value = text.isEmpty ? nil : text }
            else if let pair = try? container.decode([Loose].self) { value = pair.compactMap(\.text).joined(separator: ",") }
            else { value = nil }
        }
    }

    struct Metadata: Decodable, Sendable { let next_offset: NextOffset?; let total_objects: Loose? }

    /// Duo's envelope around every answer.
    struct Answer<Value: Decodable>: Decodable {
        let stat: String?
        let response: Value?
        let metadata: Metadata?
    }

    // MARK: Requests

    /// Whether the connection's host is one of Duo's API hosts: Pion signs requests for nowhere else.
    static func isDuoHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), host.hasPrefix("api-") else { return false }
        return host.hasSuffix(".duosecurity.com") || host.hasSuffix(".duofederal.com")
    }

    /// What Duo said when it refused: its code, message and the parameter it named.
    static func reason(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServiceClient.reason(data) }
        let message = object["message"] as? String
        let detail = object["message_detail"] as? String
        let code = (object["code"] as? Int).map(String.init) ?? object["code"] as? String
        let words = [message, detail.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        guard !words.isEmpty else { return ServiceClient.reason(data) }
        let line = code.map { "\($0): \(words)" } ?? words
        return String(line.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(300))
    }

    /// One request to the account. Duo's refusals are said in its own words.
    static func exchange(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], repeated: [String: [String]] = [:],
                         method: String = "GET", body: [String: String]? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        guard isDuoHost(service.base.host) else {
            throw ServiceError.input("This connection's API hostname, \(service.base.host ?? "?"), is not one of Duo's, such as api-xxxxxxxx.duosecurity.com: Pion signs requests only for Duo. Correct it in Settings › Tools.")
        }
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        // Duo takes a change's parameters as JSON, under exactly this type, and signs the body's bytes as sent.
        let answer = try await service.exchange(path, query: query, repeated: repeated, method: method, body: encoded, contentType: "application/json",
                                                returning: Set(300...599))
        let status = answer.response.statusCode
        let said = reason(answer.data)
        switch status {
        case 200..<300: return answer
        case 401: throw ServiceError.rejected(said)
        case 403: throw ServiceError.forbidden(said)
        case 404: throw ServiceError.notFound
        case 429: throw ServiceError.rateLimited(said)
        case 400, 405, 409: throw said.map(ServiceError.refused) ?? ServiceError.status(status)
        default: throw ServiceError.status(status, said)
        }
    }

    /// An answer's response, unwrapped from Duo's envelope.
    static func get<Value: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], repeated: [String: [String]] = [:],
                                      as: Value.Type = Value.self) async throws -> (value: Value, metadata: Metadata?) {
        let data = try await exchange(service, path, query: query, repeated: repeated).data
        let answer: Answer<Value>
        do { answer = try JSONDecoder().decode(Answer<Value>.self, from: data) } catch { throw ServiceError.unreadable }
        guard let value = answer.response else { throw ServiceError.unreadable }
        return (value, answer.metadata)
    }

    // MARK: Listings

    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// Why it stopped before the end, when not for its page limit, such as a page Duo failed to give.
        var stopped: String? = nil
        var total: Int? = nil
        var complete: Bool { !more && stopped == nil }
    }

    /// A listing paged by offset, page after page up to `pages`, each of `limit` items. When a page after the first
    /// fails, what earlier pages held is kept and the listing says why it stopped.
    static func list<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], limit: Int,
                                      pages: Int = maximumPages, as: Item.Type) async throws -> Listing<Item> {
        var found = Listing<Item>()
        var offset = 0
        while found.pages < pages {
            var query = query
            query["limit"] = String(limit)
            query["offset"] = String(offset)
            let page: (value: [Item], metadata: Metadata?)
            do { page = try await get(service, path, query: query, as: [Item].self) } catch {
                guard found.pages > 0 else { throw error }
                found.more = true
                found.stopped = error.localizedDescription
                return found
            }
            found.pages += 1
            found.value += page.value
            found.total = page.metadata?.total_objects?.text.flatMap { Int($0) } ?? found.total
            guard let next = page.metadata?.next_offset?.value.flatMap({ Int($0) }), next > offset, !page.value.isEmpty else {
                found.more = false
                return found
            }
            found.more = true
            offset = next
        }
        return found
    }

    static func stopped<Item>(_ listing: Listing<Item>, _ name: String) -> String {
        if let reason = listing.stopped {
            return "\nIncomplete: stopped at page \(listing.pages + 1) reading \(name) because \(reason); what the \(listing.pages) page\(listing.pages == 1 ? "" : "s") before held is kept."
        }
        let of = listing.total.map { " of \($0)" } ?? ""
        return listing.more ? "\nIncomplete: read \(listing.value.count)\(of) \(name) in \(listing.pages) page\(listing.pages == 1 ? "" : "s"), the most read at once; more remain." : ""
    }

    // MARK: Refusals

    /// What one thing a tool reads or does needs, to say which permission to tick when Duo refuses it.
    struct Need: Sendable {
        let title: String, permission: String
        var note: String? = nil
        static let logs = Need(title: "Logs", permission: "Grant read log")
        static let resources = Need(title: "Users, phones, policies and applications", permission: "Grant resource - Read")
        static let admins = Need(title: "Administrators", permission: "Grant administrators - Read",
                                 note: "Duo also needs Grant resource - Read for it, and does not offer its Administrators API to accounts set up through Cisco Security Cloud Control after May 11, 2026.")
        static let settings = Need(title: "Global settings", permission: "Grant settings",
                                   note: "Duo has no read-only form of it: it also lets these keys change the settings.")
        static let information = Need(title: "Account summary", permission: "Grant read information")
        static let trustMonitor = Need(title: "Trust Monitor", permission: "Grant read log",
                                       note: "Trust Monitor is part of Duo Premier and Duo Advantage; on other editions Duo refuses it whatever the permissions.")
        static let write = Need(title: "Changes to users and devices", permission: "Grant resource - Write")
    }

    /// What to change when Duo refused, from what it said; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        switch error {
        case ServiceError.rejected:
            return "Duo did not accept the request's signature: the integration key or secret key is wrong, the application was deleted or is not an Admin API application, or this Mac's clock is more than a few minutes off. Check the keys in Settings › Tools."
        case ServiceError.forbidden:
            return "the Admin API application lacks \(need.permission): in the Duo Admin Panel, open **Applications**, the application this tool uses, tick \(need.permission) under **Permissions** and save; an Owner must do it. If it is ticked, check the application's **Networks for API access**.\(need.note.map { " " + $0 } ?? "")"
        default: return nil
        }
    }

    /// A request, with Duo's refusal said as which permission to tick.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("Duo refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    // MARK: Users

    struct Group: Codable, Sendable { let group_id: String?; let name: String?; let status: Loose? }
    struct Phone: Codable, Sendable {
        let phone_id: String?, number: String?, name: String?, platform: String?, type: String?, model: String?, os_version: String?
        let activated: Bool?, capabilities: [String]?, last_seen: Loose?, tampered: String?, encrypted: String?, screenlock: String?
        let fingerprint: String?, quarantined: Bool?, sms_passcodes_sent: Bool?
        struct Owner: Codable, Sendable { let user_id: String?; let username: String? }
        let users: [Owner]?

        /// What Duo reports of the device's health that an audit asks about, the worst first.
        var concerns: [String] {
            var found: [String] = []
            if tampered?.lowercased() == "tampered" { found.append("jailbroken or rooted") }
            if encrypted?.lowercased() == "unencrypted" { found.append("unencrypted") }
            if screenlock?.lowercased() == "unlocked" { found.append("no screen lock") }
            if fingerprint?.lowercased() == "disabled" { found.append("no biometrics") }
            if activated == false { found.append("Duo Mobile not activated") }
            if quarantined == true { found.append("quarantined") }
            return found
        }

        var sentence: String {
            var parts = ["\(name?.isEmpty == false ? name! : (number ?? phone_id ?? "?"))"]
            if let number, !number.isEmpty, name?.isEmpty == false { parts.append(number) }
            parts.append([platform, model, os_version].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " "))
            if let capabilities, !capabilities.isEmpty { parts.append("can use " + capabilities.joined(separator: ", ")) }
            if let seen = last_seen?.shown { parts.append("last seen \(seen)") }
            parts += concerns
            return parts.filter { !$0.isEmpty }.joined(separator: ", ") + " [\(phone_id ?? "?")]"
        }
    }
    struct Token: Codable, Sendable { let token_id: String?; let type: String?; let serial: String? }
    struct SecurityKey: Codable, Sendable { let webauthnkey: String?; let credential_name: String?; let label: String?; let date_added: Loose?; let date_last_used: Loose? }

    struct User: Codable, Sendable {
        let user_id: String
        let username: String?, realname: String?, email: String?, status: String?, lockout_reason: String?
        let is_enrolled: Bool?, last_login: Loose?, created: Loose?, last_directory_sync: Loose?
        let phones: [Phone]?, tokens: [Token]?, webauthncredentials: [SecurityKey]?, groups: [Group]?
        let aliases: [String: Loose]?

        var named: String { "\(username ?? user_id) (\(user_id))" }

        var sentence: String {
            var parts = ["\(realname?.isEmpty == false ? realname! + " " : "")\(named)", status ?? "of unknown status"]
            if let lockout_reason, !lockout_reason.isEmpty { parts.append("locked out for \(lockout_reason)") }
            if is_enrolled == false { parts.append("not enrolled") }
            parts.append(last_login?.shown.map { "last logged in \($0)" } ?? "never logged in")
            let devices = [(phones?.count ?? 0, "phone"), (tokens?.count ?? 0, "hardware token"), (webauthncredentials?.count ?? 0, "security key")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            parts.append(devices.isEmpty ? "no devices" : devices.joined(separator: ", "))
            if last_directory_sync?.date != nil { parts.append("synced from a directory") }
            return parts.joined(separator: ", ")
        }
    }

    /// The user an ID or username names. A username must be the user's own or one of their aliases, as Duo matches either.
    static func resolve(_ value: String, on service: ServiceClient) async throws -> User {
        if isUserID(value) {
            let user = try await read(.resources) { try await get(service, ["admin", "v1", "users", value.trimmingCharacters(in: .whitespaces)], as: User.self).value }
            return user
        }
        let name = try username(value)
        let users = try await read(.resources) { try await get(service, ["admin", "v1", "users"], query: ["username": name], as: [User].self).value }
        guard let user = users.first(where: { $0.username?.lowercased() == name.lowercased() || ($0.aliases ?? [:]).values.contains { $0.text?.lowercased() == name.lowercased() } }) else {
            throw ServiceError.input("Duo has no user named \(name). Give their exact username, an alias, or their user ID (DU…).")
        }
        _ = try id(user.user_id, prefix: "DU", "the user")
        return user
    }
}
