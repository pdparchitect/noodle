import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Defender XDR: its alerts and incidents, advanced hunting across devices, email, identities and apps, and
/// the devices Defender for Endpoint sees, read through Microsoft Graph as the admin who signs in. Each account is one
/// tenant. Microsoft Defender XDR Detection only reads; Microsoft Defender XDR Containment, a tool of its own with a sign-in
/// of its own, acts on devices through the Defender for Endpoint API.
///
/// Both sign in as Microsoft Entra ID's tools do: OAuth at the tenant's own address, an authorization code and PKCE,
/// through a public client app registration made for each tool, with no client secret. One sign-in gets tokens for one
/// API, so Detection reads Microsoft Graph alone and Containment the Defender for Endpoint API alone. Devices come from
/// advanced hunting's DeviceInfo: the Defender for Endpoint API reads a device or its machine actions only with
/// Machine.ReadWrite, which could also change devices' tags, so Detection leaves machine actions to Containment.
///
/// Both tools' guide is Incubator/Pion/docs/tools/defender.md. Change it with the setup steps, permissions or operations here.
public enum Defender {
    public static let preset = ToolDefinition(
        id: "eef1f5bd-b131-448f-9f37-0a3ba0beb217", name: "Microsoft Defender XDR Detection",
        summary: "Alerts, incidents, advanced hunting and devices across Microsoft Defender XDR, read-only.",
        defaultInstructions: """
        Use Microsoft Defender XDR Detection to see what Microsoft's detections found: alerts and incidents by severity, \
        status, source and time; alert reads one alert with its evidence, including each device's Defender for Endpoint \
        ID and each file's SHA1, which Microsoft Defender XDR Containment acts on; incident reads one incident with its \
        alerts. hunt runs KQL across the advanced hunting tables, such as DeviceProcessEvents, DeviceNetworkEvents, \
        EmailEvents and IdentityLogonEvents. Who holds which Microsoft Entra role is in IdentityInfo's AssignedRoles, \
        such as IdentityInfo | where AssignedRoles has "Global Administrator", for auditing who holds what. For what an \
        account touched, DeviceFileEvents holds files created, copied or moved on devices; CloudAppEvents holds what it \
        did in Microsoft 365 apps, such as ActionType "FileDownloaded", "FileAccessed" or "FileSyncDownloadedFull" in \
        SharePoint and OneDrive, or mailbox access; and EmailEvents the mail it sent and received. Keep hunting queries \
        narrow, with a time filter and a row limit. devices lists the devices Defender for Endpoint reported in the last \
        30 days, with their onboarding, sensor health and exposure; device reads one with its addresses and alerts. The \
        alert watch checks every five minutes and wakes you with a note naming security-events, which reads what it \
        reads for the note's window: new high-severity alerts that are not resolved, and high-severity incidents that \
        are active, in progress or awaiting action. A note may name a feed the watch could not read: security-events \
        says why, so tell the champion and treat that feed's silence as unknown. When a tool is refused or something \
        you need seems missing, run check-access and tell the champion exactly what it says to change. Silence is not \
        proof: every result says when it stopped before reading everything or matched more than it kept, and the \
        signed-in admin sees only the devices their Defender roles cover. Record each query and what it returned as \
        evidence, with the query itself as the method. These tools only read: recommend isolating a device or other \
        responses to the champion, or use Microsoft Defender XDR Containment, with the device, why, and how to undo it.
        """,
        iconName: "defender",
        configuration: .connection(.init(endpointTemplate: "https://graph.microsoft.com/v1.0", fields: Entra.fields,
                                         oauth: Entra.oauth(scopes: auditScopes), oauthClientField: "clientID", oauthPathField: "tenant",
                                         oauthPathExcludes: Entra.generic, adapter: "defender")),
        setup: setup)

    /// Only reading permissions: alerts, incidents and advanced hunting, and the signed-in admin's own profile and
    /// tenant, which check-access names.
    static let auditScopes = ["SecurityAlert.Read.All", "SecurityIncident.Read.All", "ThreatHunting.Read.All", "User.Read"]

    static let setup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it Pion Defender Detection, kept for this tool alone, and keep **Single tenant**. Under **Redirect URI**, choose **Public client/native (mobile & desktop)** and give \(Entra.redirects). Add no client secret or certificate: Pion keeps none and signs in with PKCE.",
        "Under **API permissions**, choose **Add a permission › Microsoft Graph › Delegated permissions** and add exactly \(auditScopes.map { "`\($0)`" }.joined(separator: ", ")) (a new app has `User.Read` already). Choose **Grant admin consent**. Pion asks for these and `offline_access`, and refuses a sign-in that lacks any.",
        "Under **Enterprise applications**, open the app: in **Properties**, set **Assignment required?** to **Yes**, and under **Users and groups** assign only the admin who will sign in.",
        "Microsoft allows a request only when both the app's permissions and the signed-in admin's role allow it. Keep an admin for Pion Defender Detection alone, such as pion-defender-detection@contoso.com, with only the **Security Reader** role, which reads alerts, incidents and advanced hunting and changes nothing. If your tenant uses Microsoft Defender XDR's unified role-based access, give that admin a custom role with only **Security data basics (read)** instead, over every device group it should see.",
        "Alerts, incidents and advanced hunting need Microsoft Defender XDR, such as Microsoft 365 E5 or a Defender for Endpoint, Office 365, Identity or Cloud Apps plan; each plan fills only its own hunting tables, which check-access lists.",
        "Give the **Directory (tenant) ID** and the app's **Application (client) ID** from its **Overview**. Choose **Add & Connect** and sign in as that admin. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Alerts(), AlertDetails(), Incidents(), IncidentDetails(), Hunt(), Devices(), DeviceDetails(),
                                                              SecurityEvents(), CheckAccess()],
                                                 trigger: NewSecurityEvents(),
                                                 // Graph throttles each app in each tenant, advanced hunting most of all.
                                                 simultaneousRequests: 4)

    // MARK: Limits

    /// The most pages one listing reads.
    static let maximumPages = 10
    /// How many days the security API's alerts and incidents may be searched back, as Defender keeps them.
    static let keptDays = 180.0
    /// How many days of DeviceInfo devices and device read back.
    static let deviceDays = 30
    /// The most rows Defender's advanced hunting returns for one query.
    static let huntRows = 100_000

    // MARK: Requests

    /// The hosts a next page may be on: Graph for Detection, the Defender for Endpoint API for Containment.
    static let hosts: Set<String> = ["graph.microsoft.com", "api.security.microsoft.com"]

    /// One request, for the tenant the connection names, to `api`, as said in what it refused: its refusals in its own
    /// words, and when it throttles, after the transport has waited as Retry-After asked and tried again, how long it
    /// asked to wait.
    static func exchange(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET",
                         body: Data? = nil, api: String) async throws -> (data: Data, response: HTTPURLResponse) {
        _ = try Entra.tenant(service)
        let answer = try await service.exchange(path, query: query, method: method, body: body, returning: Set(300...599))
        let status = answer.response.statusCode, said = Entra.reason(answer.data)
        switch status {
        case 200..<300: return answer
        case 429:
            let wait = answer.response.value(forHTTPHeaderField: "Retry-After").map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { Int($0) }.map { "\(api) asked to wait \($0) seconds before trying again" }
            throw ServiceError.rateLimited([wait, said].compactMap { $0 }.joined(separator: "; "))
        case 401: throw ServiceError.rejected(said)
        case 403: throw ServiceError.forbidden(said)
        case 404: throw ServiceError.notFound
        case 400, 405, 409, 412, 422: throw said.map(ServiceError.refused) ?? ServiceError.status(status)
        default: throw ServiceError.status(status, said)
        }
    }

    static func get<Answer: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], api: String = "Microsoft Graph",
                                       as: Answer.Type = Answer.self) async throws -> Answer {
        let data = try await exchange(service, path, query: query, api: api).data
        do { return try JSONDecoder().decode(Answer.self, from: data) } catch { throw ServiceError.unreadable }
    }

    /// One page: a value list, with the address of the next when there is one. A page without its value is unreadable,
    /// never an empty one.
    struct Page<Item: Decodable>: Decodable {
        let value: [Item]
        let nextLink: String?
        enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink" }
    }

    /// Where the next page starts: the $skiptoken or $skip its link gives, taken alone, from a link on the host just read,
    /// one of `hosts`, over https and at the path just read; nil at the end. A link anywhere else is never followed.
    enum Next: Equatable { case end, page(String, String), unfollowable }

    static func next(_ link: String?, service: ServiceClient, path: [String]) -> Next {
        guard let link, !link.isEmpty else { return .end }
        let expected = path.reduce(service.base) { $0.appendingPathComponent($1) }
        guard let url = URLComponents(string: link), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), hosts.contains(host), host == service.base.host?.lowercased(),
              url.path.lowercased() == expected.path.lowercased() else { return .unfollowable }
        let items = url.queryItems ?? []
        if let token = items.first(where: { $0.name.lowercased() == "$skiptoken" })?.value, !token.isEmpty, token.count <= 4_096 { return .page("$skiptoken", token) }
        if let skip = items.first(where: { $0.name.lowercased() == "$skip" })?.value, let count = Int(skip), count > 0, count <= 10_000_000 {
            return .page("$skip", String(count))
        }
        return .unfollowable
    }

    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// Why it stopped before the end, when not for its page limit, such as a page that failed.
        var stopped: String? = nil
        var stoppedAt: Int? = nil
        /// Where the next page starts, when it stopped at its page limit, or at `limit`, with more to read.
        var next: (name: String, value: String)? = nil
        var complete: Bool { !more && stopped == nil }
    }

    /// A listing, page after page, up to `pages` or until `limit` items are kept. Each next page is asked of the same
    /// path with the same query and the paging value its link gave; `from` starts from one a listing stopped at before,
    /// with the query it came from. Only a link ends a listing, as an empty page may still have one after it.
    ///
    /// When a page after the first fails, what earlier pages held is kept and the listing says where and why it
    /// stopped, unless `partial` is false, for a reader that must have all or nothing.
    static func list<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?], as: Item.Type, api: String = "Microsoft Graph",
                                      pages: Int = maximumPages, limit: Int? = nil, from: (name: String, value: String)? = nil, partial: Bool = true,
                                      matching: (Item) -> Bool = { _ in true }) async throws -> Listing<Item> {
        var query = query
        if let from { query[from.name] = from.value }
        var found = Listing<Item>()
        while found.pages < pages {
            let page: Page<Item>
            do { page = try await get(service, path, query: query, api: api, as: Page<Item>.self) } catch {
                guard partial, found.pages > 0 else { throw error }
                found.more = true
                found.next = nil
                found.stoppedAt = found.pages + 1
                found.stopped = error.localizedDescription
                return found
            }
            found.pages += 1
            found.value += page.value.filter(matching)
            switch next(page.nextLink, service: service, path: path) {
            case .end:
                found.more = false
                found.next = nil
                return found
            case .unfollowable:
                found.more = true
                found.next = nil
                found.stoppedAt = found.pages + 1
                found.stopped = "\(api) gave a next page on another address, or without a $skiptoken or $skip, which Pion does not follow"
                return found
            case .page(let name, let value):
                found.more = true
                found.next = (name, value)
                if let limit, found.value.count >= limit { return found }
                query["$skiptoken"] = nil
                query["$skip"] = nil
                query[name] = value
            }
        }
        return found
    }

    static func stopped<Item>(_ listing: Listing<Item>, _ name: String) -> String {
        if let reason = listing.stopped {
            return "\nIncomplete: stopped at page \(listing.stoppedAt ?? listing.pages + 1) reading \(name) because \(reason); what the \(listing.pages) page\(listing.pages == 1 ? "" : "s") before held is kept."
        }
        return listing.more ? "\nIncomplete: stopped after \(listing.pages) page\(listing.pages == 1 ? "" : "s") reading \(name), the most read at once; more remain." : ""
    }

    /// A window of at most `maximum` days, since before until; `days` back from now when since is left out.
    static func window(_ since: String?, _ until: String?, days: Double, maximum: Double = keptDays) throws -> (since: Date, until: Date) {
        let now = Date()
        let from: Date? = try since.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantPast } ?? now.addingTimeInterval(-days * 86_400)
        let to: Date? = try until.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantFuture } ?? now
        guard let from, let to, from <= to, from >= now.addingTimeInterval(-maximum * 86_400 - 60), to <= now.addingTimeInterval(60) else {
            throw ServiceError.input("Give a time range within the last \(Int(maximum)) days, with since before until.")
        }
        return (from, to)
    }

    // MARK: Refusals

    /// What one thing a tool reads or does needs, to say what to change when it is refused: the app's permission, the
    /// admin's role, and what the tenant must have.
    struct Need: Sendable {
        let title: String, scope: String, role: String
        var licence = "Microsoft Defender XDR"
        var api = "Microsoft Graph"
    }

    static let alertsNeed = Need(title: "Alerts", scope: "SecurityAlert.Read.All", role: "Security Reader, or Security data basics (read) in Defender's unified roles")
    static let incidentsNeed = Need(title: "Incidents", scope: "SecurityIncident.Read.All", role: "Security Reader, or Security data basics (read) in Defender's unified roles")
    static let huntingNeed = Need(title: "Advanced hunting", scope: "ThreatHunting.Read.All", role: "Security Reader, or Security data basics (read) in Defender's unified roles")
    static let profileNeed = Need(title: "The signed-in admin", scope: "User.Read", role: "any role")

    /// Whether the service refused for want of a licence or a tenant set up for Defender, rather than a permission.
    static func unlicensed(_ error: Error) -> Bool {
        guard case ServiceError.forbidden(let reason?) = error else { return false }
        let lower = reason.lowercased()
        return lower.contains("licen") || lower.contains("not provisioned") || lower.contains("subscription") || lower.contains("not onboarded")
    }

    /// What to change when a request was refused, from what the service said; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        switch error {
        case ServiceError.rejected:
            return "Microsoft did not accept the sign-in: it expired or was revoked, the admin's account was disabled or their password changed, or a Conditional Access policy now blocks it. Connect the tool again in Settings › Tools."
        case ServiceError.forbidden where unlicensed(error):
            return "this needs \(need.licence) in the tenant, which it lacks or has not set up, so it cannot be read."
        case ServiceError.forbidden:
            return "either the app lacks the delegated permission \(need.scope), which its Setup Steps list (add it, grant admin consent, then connect the tool again in Settings › Tools), or the signed-in admin lacks a role that allows it, such as \(need.role)."
        case ServiceError.input(let said) where said.contains("no one tenant"):
            return said
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
            throw ServiceError.input("\(need.api) refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    // MARK: Inputs

    static let severities = ["unknown", "informational", "low", "medium", "high"]
    static let alertStatuses = ["unknown", "new", "inProgress", "resolved"]
    static let incidentStatuses = ["active", "resolved", "inProgress", "redirected", "awaitingAction"]
    static let sources = ["microsoftDefenderForEndpoint", "microsoftDefenderForIdentity", "microsoftDefenderForCloudApps", "microsoftDefenderForOffice365",
                          "microsoft365Defender", "azureAdIdentityProtection", "microsoftAppGovernance", "dataLossPrevention", "microsoftDefenderForCloud",
                          "microsoftSentinel", "microsoftInsiderRiskManagement"]

    /// An alert's or incident's ID as Graph gives it: letters, digits, hyphens, underscores and dots.
    static func id(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(value.count), value != ".", value != "..",
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains) else {
            throw ServiceError.input("Give \(name) exactly as alerts or incidents list it.")
        }
        return value
    }

    /// A Defender for Endpoint device ID: 40 hexadecimal characters.
    static func deviceID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.count == 40 && value.allSatisfy(\.isHexDigit) ? value : nil
    }

    /// A device's name as KQL compares it: a host name's letters, digits, dots, hyphens and underscores, nothing that
    /// could end a string.
    static func deviceName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...255).contains(value.count),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains) else {
            throw ServiceError.input("Give the device's name as Defender shows it, such as lt-0423 or lt-0423.contoso.com, or its 40-character Defender for Endpoint ID.")
        }
        return value
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
}

// MARK: - Alerts and incidents

extension Defender {
    /// An entity an alert names, by its most telling name: its host, account, file, process, address, URL or mailbox.
    struct Evidence: Decodable, Sendable {
        enum Keys: String, CodingKey {
            case type = "@odata.type", hostName, deviceDnsName, mdeDeviceId, userAccount, fileDetails, imageFile, ipAddress, url, primaryAddress, verdict, remediationStatus
        }
        struct Account: Decodable { let userPrincipalName: String?; let accountName: String? }
        struct File: Decodable { let fileName: String?; let sha1: String?; let sha256: String? }
        let type: String?, name: String?, device: String?, sha1: String?, verdict: String?, remediation: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            func text(_ key: Keys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
            let account = (try? container.decodeIfPresent(Account.self, forKey: .userAccount)) ?? nil
            let file = ((try? container.decodeIfPresent(File.self, forKey: .fileDetails)) ?? nil) ?? ((try? container.decodeIfPresent(File.self, forKey: .imageFile)) ?? nil)
            let candidates: [String?] = [text(.deviceDnsName), text(.hostName), account?.userPrincipalName, account?.accountName, file?.fileName,
                                         text(.ipAddress), text(.url), text(.primaryAddress)]
            name = candidates.lazy.compactMap { $0 }.first { !$0.isEmpty }
            device = text(.mdeDeviceId).flatMap(Defender.deviceID)
            sha1 = file?.sha1.flatMap { $0.count == 40 && $0.allSatisfy(\.isHexDigit) ? $0.lowercased() : nil }
            verdict = text(.verdict)
            remediation = text(.remediationStatus)
        }

        var kind: String { Graph.kind(type)?.replacingOccurrences(of: "Evidence", with: "") ?? "entity" }
        var shown: String? {
            guard let name else { return device.map { "device \($0)" } }
            var parts = [String]()
            if let device { parts.append("Defender for Endpoint ID \(device)") }
            if let sha1 { parts.append("SHA1 \(sha1)") }
            return "\(name) (\(kind)\(parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")))"
        }
    }

    struct Alert: Decodable, Sendable {
        let id: String, title: String?, severity: String?, status: String?, category: String?, serviceSource: String?, detectionSource: String?
        let createdDateTime: String?, lastUpdateDateTime: String?, incidentId: String?, alertWebUrl: String?, mitreTechniques: [String]?
        let description: String?, recommendedActions: String?, classification: String?, determination: String?, assignedTo: String?
        let evidence: [Evidence]?
    }

    struct KeptAlert: Encodable {
        let id: String, title: String?, severity: String?, status: String?, category: String?, source: String?, created: String?
        let incident: String?, link: String?, techniques: [String], entities: [String]
        init(_ alert: Alert) {
            id = alert.id; title = alert.title; severity = alert.severity; status = alert.status; category = alert.category
            source = alert.serviceSource; created = alert.createdDateTime; incident = alert.incidentId; link = alert.alertWebUrl
            techniques = alert.mitreTechniques ?? []
            entities = (alert.evidence ?? []).compactMap(\.shown)
        }
        var line: String {
            var line = "\(created ?? "?") \(severity ?? "severity unknown") \(status ?? "status unknown"): \(title ?? id) [\(id)]"
            if let incident { line += " (incident \(incident))" }
            if !entities.isEmpty { line += " — " + entities.prefix(5).joined(separator: ", ") + (entities.count > 5 ? ", …" : "") }
            return line
        }
    }

    struct Alerts: ServiceOperation {
        struct Input: Decodable, Sendable { let severity: String?, status: String?, source: String?, incident: String?, since: String?, until: String?, limit: Int? }
        static let name = "alerts"
        static let summary = "Security alerts across Microsoft Defender XDR by severity, status, source, incident and time, with the entities each involves, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "severity": .string("The severity.", oneOf: Defender.severities),
            "status": .string("The status.", oneOf: Defender.alertStatuses),
            "source": .string("The product that raised it.", oneOf: Defender.sources),
            "incident": .string("Only the alerts of this incident, by its ID."),
            "since": .string("The earliest creation time, in ISO 8601. The last 7 days when left out, at most 180 days."),
            "until": .string("The latest creation time, in ISO 8601. Now when left out."),
            "limit": .integer("How many alerts, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let severity = input.severity { filter.append("severity eq '\(try ServiceInput.oneOf(severity, Defender.severities, "severity"))'") }
            if let status = input.status { filter.append("status eq '\(try ServiceInput.oneOf(status, Defender.alertStatuses, "status"))'") }
            if let source = input.source { filter.append("serviceSource eq '\(try ServiceInput.oneOf(source, Defender.sources, "source"))'") }
            if let incident = input.incident { filter.append("incidentId eq '\(try Defender.id(incident, "the incident"))'") }
            let (since, until) = try Defender.window(input.since, input.until, days: 7)
            filter.append("createdDateTime ge \(Entra.iso(since)) and createdDateTime le \(Entra.iso(until))")
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 alerts.") }
            let listing = try await Defender.read(Defender.alertsNeed) {
                try await Defender.list(service, ["security", "alerts_v2"], query: ["$filter": filter.joined(separator: " and "), "$top": String(min(limit, 100))],
                                        as: Alert.self, limit: limit)
            }
            let alerts = listing.value.prefix(limit).map(KeptAlert.init).sorted { ($0.created ?? "") > ($1.created ?? "") }
            let window = "created from \(Entra.iso(since)) to \(Entra.iso(until))"
            var text = alerts.isEmpty ? "No alerts \(window) match\(listing.complete ? "" : " in what was read")."
                : "\(Defender.plural(alerts.count, "alert")) \(window), newest first:\n" + alerts.prefix(30).map(\.line).joined(separator: "\n")
            if alerts.count > 30 { text += "\n\(alerts.count - 30) more in the structured result." }
            if listing.value.count > limit || (listing.more && listing.stopped == nil && listing.value.count >= limit) {
                text += "\nMore alerts match than the \(alerts.count) kept, which are those Graph listed first, not necessarily the newest: narrow the window or the severity."
            } else {
                text += Defender.stopped(listing, "alerts")
            }
            struct Kept: Encodable { let alerts: [KeptAlert]; let since: String; let until: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(alerts: Array(alerts), since: Entra.iso(since), until: Entra.iso(until),
                                                                  complete: listing.complete && listing.value.count <= limit))
        }
    }

    struct AlertDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "alert"
        static let summary = "One alert in full: what it says, how to respond, its classification and every entity in its evidence, with each device's Defender for Endpoint ID and each file's SHA1, which Microsoft Defender XDR Containment acts on."
        static let input = JSONSchema.object(["id": .string("The alert's ID, as alerts lists it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try Defender.id(input.id, "the alert")
            let alert = try await Defender.read(Defender.alertsNeed) { try await Defender.get(service, ["security", "alerts_v2", id], as: Alert.self) }
            guard alert.id == id else { throw ServiceError.input("Graph answered for alert \(alert.id), not \(id), so nothing it said is shown.") }
            let kept = KeptAlert(alert)
            var lines = [kept.line]
            lines.append("Source: \(alert.serviceSource ?? "unknown")\(alert.detectionSource.map { ", detected by \($0)" } ?? ""); category \(alert.category ?? "unknown"); classification \(alert.classification ?? "not set")\(alert.determination.map { ", \($0)" } ?? ""); assigned to \(alert.assignedTo ?? "nobody"); last updated \(alert.lastUpdateDateTime ?? "unknown").")
            if let description = alert.description, !description.isEmpty { lines.append("Description: " + String(description.prefix(1_500))) }
            if let actions = alert.recommendedActions, !actions.isEmpty { lines.append("Recommended actions: " + String(actions.prefix(1_500))) }
            let evidence = alert.evidence ?? []
            lines.append(evidence.isEmpty ? "Graph listed no evidence for it." : "Evidence: " + evidence.map { item in
                (item.shown ?? item.kind) + [item.verdict.map { "verdict \($0)" }, item.remediation.map { "remediation \($0)" }].compactMap { $0 }.map { ", " + $0 }.joined()
            }.joined(separator: "; ") + ".")
            if let link = alert.alertWebUrl { lines.append("In the Defender portal: \(link)") }
            struct Device: Encodable { let name: String?; let id: String }
            struct Kept: Encodable { let alert: KeptAlert; let devices: [Device]; let files: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(alert: kept, devices: evidence.compactMap { item in item.device.map { Device(name: item.name, id: $0) } },
                                                      files: Array(NSOrderedSet(array: evidence.compactMap(\.sha1))) as? [String] ?? []))
        }
    }

    struct Incident: Codable, Sendable {
        let id: String, displayName: String?, severity: String?, status: String?, createdDateTime: String?, lastUpdateDateTime: String?
        let assignedTo: String?, classification: String?, determination: String?, incidentWebUrl: String?
        var line: String { "\(createdDateTime ?? "?") \(severity ?? "severity unknown") \(status ?? "status unknown"): \(displayName ?? id) [\(id)]\(assignedTo.map { ", assigned to \($0)" } ?? "")" }
    }

    struct Incidents: ServiceOperation {
        struct Input: Decodable, Sendable { let severity: String?, status: String?, since: String?, until: String?, limit: Int? }
        static let name = "incidents"
        static let summary = "Incidents, which gather related alerts, by severity, status and time, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "severity": .string("The severity.", oneOf: Defender.severities),
            "status": .string("The status.", oneOf: Defender.incidentStatuses),
            "since": .string("The earliest creation time, in ISO 8601. The last 30 days when left out, at most 180 days."),
            "until": .string("The latest creation time, in ISO 8601. Now when left out."),
            "limit": .integer("How many incidents, at most. 50 when left out.", minimum: 1, maximum: 200),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let severity = input.severity { filter.append("severity eq '\(try ServiceInput.oneOf(severity, Defender.severities, "severity"))'") }
            if let status = input.status { filter.append("status eq '\(try ServiceInput.oneOf(status, Defender.incidentStatuses, "status"))'") }
            let (since, until) = try Defender.window(input.since, input.until, days: 30)
            filter.append("createdDateTime ge \(Entra.iso(since)) and createdDateTime le \(Entra.iso(until))")
            let limit = input.limit ?? 50
            guard (1...200).contains(limit) else { throw ServiceError.input("Ask for between 1 and 200 incidents.") }
            let listing = try await Defender.read(Defender.incidentsNeed) {
                try await Defender.list(service, ["security", "incidents"], query: ["$filter": filter.joined(separator: " and "), "$top": String(min(limit, 50))],
                                        as: Incident.self, limit: limit)
            }
            let incidents = listing.value.prefix(limit).sorted { ($0.createdDateTime ?? "") > ($1.createdDateTime ?? "") }
            let window = "created from \(Entra.iso(since)) to \(Entra.iso(until))"
            var text = incidents.isEmpty ? "No incidents \(window) match\(listing.complete ? "" : " in what was read")."
                : "\(Defender.plural(incidents.count, "incident")) \(window), newest first:\n" + incidents.prefix(30).map(\.line).joined(separator: "\n")
            if incidents.count > 30 { text += "\n\(incidents.count - 30) more in the structured result." }
            let cut = listing.value.count > limit || (listing.more && listing.stopped == nil && listing.value.count >= limit)
            text += cut ? "\nMore incidents match than the \(incidents.count) kept, which are those Graph listed first, not necessarily the newest: narrow the window, severity or status."
                : Defender.stopped(listing, "incidents")
            struct Kept: Encodable { let incidents: [Incident]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(incidents: Array(incidents), complete: listing.complete && !cut))
        }
    }

    struct IncidentDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "incident"
        static let summary = "One incident with each of its alerts and the entities they involve."
        static let input = JSONSchema.object(["id": .string("The incident's ID, as incidents lists it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try Defender.id(input.id, "the incident")
            struct Expanded: Decodable {
                let id: String, displayName: String?, severity: String?, status: String?, createdDateTime: String?, lastUpdateDateTime: String?
                let assignedTo: String?, classification: String?, determination: String?, incidentWebUrl: String?, alerts: [Alert]?
            }
            let incident = try await Defender.read(Defender.incidentsNeed) {
                try await Defender.get(service, ["security", "incidents", id], query: ["$expand": "alerts"], as: Expanded.self)
            }
            guard incident.id == id else { throw ServiceError.input("Graph answered for incident \(incident.id), not \(id), so nothing it said is shown.") }
            let alerts = (incident.alerts ?? []).map(KeptAlert.init).sorted { ($0.created ?? "") > ($1.created ?? "") }
            var lines = ["\(incident.displayName ?? id) [\(id)]: \(incident.severity ?? "severity unknown"), \(incident.status ?? "status unknown"), created \(incident.createdDateTime ?? "?"), last updated \(incident.lastUpdateDateTime ?? "?"); assigned to \(incident.assignedTo ?? "nobody"); classification \(incident.classification ?? "not set")\(incident.determination.map { ", \($0)" } ?? "")."]
            lines.append(incident.alerts == nil ? "Graph did not list its alerts, so which it holds is not known; read them with alerts and this incident's ID."
                : alerts.isEmpty ? "Graph listed no alerts in it." : "\(Defender.plural(alerts.count, "alert")):\n" + alerts.prefix(40).map(\.line).joined(separator: "\n"))
            if alerts.count > 40 { lines.append("\(alerts.count - 40) more in the structured result.") }
            if let link = incident.incidentWebUrl { lines.append("In the Defender portal: \(link)") }
            struct Kept: Encodable { let id: String; let name: String?; let severity: String?; let status: String?; let alerts: [KeptAlert]?; let link: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(id: id, name: incident.displayName, severity: incident.severity, status: incident.status,
                                                      alerts: incident.alerts == nil ? nil : alerts, link: incident.incidentWebUrl))
        }
    }
}

// MARK: - Advanced hunting

extension Defender {
    /// A query's answer as Graph gives it: its columns and rows, both there, or it is unreadable.
    struct Answer: Decodable {
        struct Column: Decodable { let name: String }
        let schema: [Column]
        let results: [[String: CellValue]]
    }

    /// Runs one KQL query, with a refusal said as what to change and Graph's words when the query itself was wrong.
    static func hunt(_ query: String, timespan: String? = nil, _ service: ServiceClient) async throws -> Answer {
        struct Body: Encodable { let Query: String; let Timespan: String? }
        let body = try JSONEncoder().encode(Body(Query: query, Timespan: timespan))
        return try await read(huntingNeed) {
            let data = try await exchange(service, ["security", "runHuntingQuery"], method: "POST", body: body, api: "Microsoft Graph").data
            do { return try JSONDecoder().decode(Answer.self, from: data) } catch { throw ServiceError.unreadable }
        }
    }

    /// What a hunt's row count says: that Defender may have cut it at its limit.
    static func capped(_ count: Int) -> String {
        count >= huntRows ? "\nDefender returns at most \(huntRows) rows for one query, so more may match: narrow it, or summarize." : ""
    }

    struct Hunt: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, timespan: String? }
        static let name = "hunt"
        static let summary = "Run a KQL query over Defender's advanced hunting tables, such as DeviceProcessEvents or EmailEvents, saying when the results may be cut short. Read-only."
        static let input = JSONSchema.object([
            "query": .string("The KQL query. Filter by time and end with take or limit to keep results small."),
            "timespan": .string("How far back, in ISO 8601, such as P7D or 2026-11-13T00:00:00Z/P1D. 30 days when left out."),
        ], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let query = try ServiceInput.query(input.query)
            var timespan: String?
            if let given = input.timespan?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
                guard given.count <= 60, given.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789PTYMWDHS:-+./Z").contains) else {
                    throw ServiceError.input("Give the timespan in ISO 8601, such as P7D or 2026-11-13T00:00:00Z/P1D.")
                }
                timespan = given
            }
            let answer = try await Defender.hunt(query, timespan: timespan, service)
            let columns = answer.schema.map(\.name)
            let result = try ServiceTable(columns: columns, rows: answer.results.map { row in columns.map { row[$0] ?? .none } }).result()
            return result.adding(Defender.capped(answer.results.count) + (answer.results.isEmpty ? " That is not proof nothing happened: a table fills only with the Defender plan that feeds it, which check-access lists, and the admin sees only the devices their roles cover." : ""))
        }
    }

    /// A device's latest DeviceInfo row, by name.
    struct Device: Encodable {
        let id: String, name: String?, platform: String?, os: String?, onboarding: String?, sensorHealth: String?, exposure: String?
        let group: String?, internetFacing: Bool?, publicIP: String?, lastSeen: String?, entraDevice: String?, tags: [String]
        init(_ row: [String: CellValue]) {
            func text(_ key: String) -> String? { if case .text(let value)? = row[key], !value.isEmpty { return value }; return nil }
            id = text("DeviceId") ?? "?"; name = text("DeviceName"); platform = text("OSPlatform"); os = text("OSVersion")
            onboarding = text("OnboardingStatus"); sensorHealth = text("SensorHealthState"); exposure = text("ExposureLevel")
            group = text("MachineGroup"); publicIP = text("PublicIP"); lastSeen = text("Timestamp"); entraDevice = text("AadDeviceId")
            if case .flag(let flag)? = row["IsInternetFacing"] { internetFacing = flag } else { internetFacing = nil }
            var tags: [String] = []
            for key in ["DeviceManualTags", "DeviceDynamicTags"] {
                switch row[key] {
                case .list(let list)?: tags += list
                case .text(let text)? where !text.isEmpty && text != "[]":
                    tags += ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String]) ?? [text]
                default: break
                }
            }
            self.tags = tags
        }
        var line: String {
            "\(name ?? "unnamed") [\(id)]: \(platform ?? "platform unknown")\(os.map { " \($0)" } ?? ""), onboarding \(onboarding ?? "unknown"), sensor \(sensorHealth ?? "unknown"), exposure \(exposure ?? "unknown")\(internetFacing == true ? ", internet-facing" : "")\(group.map { ", group \($0)" } ?? ""), last seen \(lastSeen ?? "unknown")"
        }
    }

    static let platforms = ["Windows10", "Windows11", "WindowsServer2012R2", "WindowsServer2016", "WindowsServer2019", "WindowsServer2022", "WindowsServer2025",
                            "macOS", "Linux", "iOS", "Android"]

    struct Devices: ServiceOperation {
        struct Input: Decodable, Sendable { let name: String?, platform: String?, onboarding: String?, limit: Int? }
        static let name = "devices"
        static let summary = "The devices Defender for Endpoint reported in the last 30 days, newest seen first, by the start of their name, platform and onboarding, with each one's Defender for Endpoint ID, sensor health, exposure and device group, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "name": .string("The start of the device's name."),
            "platform": .string("The platform.", oneOf: Defender.platforms),
            "onboarding": .string("The onboarding status.", oneOf: ["Onboarded", "Can be onboarded", "Unsupported", "Insufficient info"]),
            "limit": .integer("How many devices, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 devices.") }
            var query = "DeviceInfo\n| where Timestamp > ago(\(Defender.deviceDays)d)"
            if let name = input.name { query += "\n| where DeviceName startswith \"\(try Defender.deviceName(name))\"" }
            if let platform = input.platform { query += "\n| where OSPlatform == \"\(try ServiceInput.oneOf(platform, Defender.platforms, "platform"))\"" }
            if let onboarding = input.onboarding {
                query += "\n| where OnboardingStatus == \"\(try ServiceInput.oneOf(onboarding, ["Onboarded", "Can be onboarded", "Unsupported", "Insufficient info"], "onboarding"))\""
            }
            query += "\n| summarize arg_max(Timestamp, *) by DeviceId\n| order by Timestamp desc\n| take \(limit + 1)"
            let answer = try await Defender.hunt(query, service)
            let devices = answer.results.prefix(limit).map(Device.init)
            var text = devices.isEmpty ? "Defender for Endpoint reported no device that matches in the last \(Defender.deviceDays) days, among those the signed-in admin may see. That is not proof there is none: a device not onboarded, outside the admin's device groups or silent for longer is not listed."
                : "\(Defender.plural(devices.count, "device")), newest seen first:\n" + devices.prefix(40).map(\.line).joined(separator: "\n")
            if devices.count > 40 { text += "\n\(devices.count - 40) more in the structured result." }
            if answer.results.count > limit { text += "\nMore devices match than the \(limit) kept: give more of the name, a platform or a higher limit." }
            text += "\nRead with advanced hunting: \(query.replacingOccurrences(of: "\n", with: " "))"
            struct Kept: Encodable { let devices: [Device]; let query: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(devices: Array(devices), query: query, complete: answer.results.count <= limit))
        }
    }

    struct DeviceDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let device: String }
        static let name = "device"
        static let summary = "One device as Defender for Endpoint last reported it in 30 days: platform, onboarding, sensor health, exposure, device group, tags and Entra device ID, its network addresses, and the alerts that named it, saying what it could not read."
        static let input = JSONSchema.object(["device": .string("The device's 40-character Defender for Endpoint ID, or its exact name.")], required: ["device"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let match: String
            if let id = Defender.deviceID(input.device) { match = "DeviceId == \"\(id)\"" }
            else { match = "DeviceName =~ \"\(try Defender.deviceName(input.device))\"" }
            let infoQuery = "DeviceInfo\n| where Timestamp > ago(\(Defender.deviceDays)d) and \(match)\n| summarize arg_max(Timestamp, *) by DeviceId\n| take 5"
            let info = try await Defender.hunt(infoQuery, service)
            let found = info.results.map(Device.init)
            guard let device = found.first, Defender.deviceID(device.id) != nil else {
                return try ServiceResult(text: "Defender for Endpoint reported no device \(input.device) in the last \(Defender.deviceDays) days, among those the signed-in admin may see. It may be named otherwise, not onboarded, outside the admin's device groups or silent for longer; devices lists them by the start of their name.",
                                         structured: ["found": false])
            }
            var lines = [device.line]
            if found.count > 1 { lines.append("⚠ \(found.count) devices answer to that name: \(found.map { "\($0.name ?? "?") [\($0.id)]" }.joined(separator: ", ")). The rest of this reads only the first; give an ID.") }
            lines.append("Entra device ID \(device.entraDevice ?? "not given"); public IP \(device.publicIP ?? "not given"); tags \(device.tags.isEmpty ? "none given" : device.tags.joined(separator: ", ")).")
            var gaps: [String] = []
            var addresses: [String] = []
            do {
                let network = try await Defender.hunt("DeviceNetworkInfo\n| where Timestamp > ago(7d) and DeviceId == \"\(device.id)\"\n| summarize arg_max(Timestamp, IPAddresses, MacAddress) by NetworkAdapterName\n| take 20", service)
                for row in network.results {
                    if case .text(let text)? = row["IPAddresses"], let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] {
                        addresses += list.compactMap { $0["IPAddress"] as? String }
                    }
                }
                lines.append(addresses.isEmpty ? "No network addresses reported in the last 7 days." : "Addresses in the last 7 days: \(Array(NSOrderedSet(array: addresses)).compactMap { $0 as? String }.joined(separator: ", ")).")
            } catch { gaps.append("its network addresses (\(error.localizedDescription))") }
            var alertLines: [String] = []
            do {
                let alerts = try await Defender.hunt("AlertEvidence\n| where Timestamp > ago(\(Defender.deviceDays)d) and DeviceId == \"\(device.id)\"\n| distinct AlertId\n| join kind=inner (AlertInfo | where Timestamp > ago(\(Defender.deviceDays)d) | summarize arg_max(Timestamp, Title, Severity, ServiceSource) by AlertId) on AlertId\n| order by Timestamp desc\n| take 31", service)
                alertLines = alerts.results.prefix(30).map { row in
                    "\(row["Timestamp"]?.shown ?? "?") \(row["Severity"]?.shown ?? "?"): \(row["Title"]?.shown ?? "?") [\(row["AlertId"]?.shown ?? "?")]"
                }
                lines.append(alertLines.isEmpty ? "No alert named it in the last \(Defender.deviceDays) days." : "Alerts that named it in the last \(Defender.deviceDays) days, newest first:\n" + alertLines.joined(separator: "\n"))
                if alerts.results.count > 30 { lines.append("More alerts named it than the 30 shown: use alerts or hunt AlertEvidence.") }
            } catch { gaps.append("the alerts that named it (\(error.localizedDescription))") }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")).") }
            lines.append("Whether it is isolated or its apps restricted, and the actions taken on it, are read by Microsoft Defender XDR Containment's device and machine-actions.")
            struct Kept: Encodable { let found: Bool; let device: Device; let addresses: [String]; let alerts: [String]; let couldNotRead: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(found: true, device: device, addresses: addresses, alerts: alertLines, couldNotRead: gaps))
        }
    }
}

// MARK: - Access

extension Defender {
    /// The hunting tables each Defender plan fills, to say which have data.
    static let planTables: [(table: String, plan: String)] = [
        ("DeviceInfo", "Defender for Endpoint"), ("EmailEvents", "Defender for Office 365"), ("IdentityLogonEvents", "Defender for Identity"),
        ("CloudAppEvents", "Defender for Cloud Apps"),
    ]

    /// Tries each thing Detection reads once, says what works and what to change for what does not, which hunting tables
    /// have data, and who is signed in.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly what to change: the app's permissions, the admin's role or what the tenant lacks; which tenant it reads and who is signed in; and which Defender plans' hunting tables have data in the last 7 days, as hunting an empty table finds nothing. It changes nothing."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ \(need.title)" }
                catch { return "✗ \(need.title): " + (Defender.fix(for: error, need) ?? error.localizedDescription) }
            }
            var lines = [await Entra.tenantLine(service)]
            lines.append(await check(Defender.alertsNeed) { _ = try await Defender.get(service, ["security", "alerts_v2"], query: ["$top": "1"], as: Page<Entra.IgnoredItem>.self) })
            lines.append(await check(Defender.incidentsNeed) { _ = try await Defender.get(service, ["security", "incidents"], query: ["$top": "1"], as: Page<Entra.IgnoredItem>.self) })
            do {
                let tables = Defender.planTables.map(\.table).joined(separator: ", ")
                let answer = try await Defender.hunt("union isfuzzy=true withsource=Table \(tables)\n| where Timestamp > ago(7d)\n| summarize Rows = count() by Table", service)
                lines.append("✓ \(Defender.huntingNeed.title)")
                var counts: [String: String] = [:]
                for row in answer.results { if let table = row["Table"]?.shown { counts[table] = row["Rows"]?.shown } }
                let filled = Defender.planTables.filter { counts[$0.table].map { $0 != "0" } ?? false }
                let empty = Defender.planTables.filter { counts[$0.table].map { $0 == "0" } ?? true }
                if !filled.isEmpty { lines.append("✓ Data in the last 7 days from: \(filled.map { "\($0.plan) (\($0.table))" }.joined(separator: ", ")).") }
                if !empty.isEmpty { lines.append("⚠ No data in the last 7 days from: \(empty.map { "\($0.plan) (\($0.table))" }.joined(separator: ", ")). Without that plan, or outside the admin's device groups, hunting its tables finds nothing, which is not proof nothing happened\(empty.contains { $0.table == "DeviceInfo" } ? "; devices and device read DeviceInfo" : "").") }
            } catch {
                lines.append("✗ \(Defender.huntingNeed.title): " + (Defender.fix(for: error, Defender.huntingNeed) ?? error.localizedDescription))
            }
            do {
                let me = try await Defender.read(Defender.profileNeed) { try await Entra.me(service) }
                lines.append("· Signed in as \(me.userPrincipalName ?? me.id). Give them only Security Reader, or Security data basics (read) in Defender's unified roles: this tool's permissions only read, whatever their roles allow, but an admin kept for it needs no more.")
            } catch {
                lines.append("· Who is signed in: not read: \(error.localizedDescription)")
            }
            lines.append("· The app's consented permissions are not read here, as that takes a directory permission this tool does not ask for; Pion refuses a sign-in that lacks any it asks for: \((Defender.auditScopes + ["offline_access"]).joined(separator: ", ")).")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
