import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// CrowdStrike Falcon Containment: responding on one customer's hosts, through an API client of its own with only the
/// scopes its actions take, kept apart from Detection's so the detection client stays read-only. Every action that cuts a host
/// off, blocks something, ends a process or hides an alert waits for the champion's approval, and each says what
/// recovering from it involves.
///
/// Falcon takes containment as a request the sensor carries out when it next connects, so a request taken is not a
/// done one: the host's status says containment_pending until the sensor confirms it. Each action reads what it acts on
/// first and refuses unless that read is whole, then reads it again afterwards and says done only when Falcon names the
/// same host, indicator or alert with what was approved; anything else is reported unverified, with Falcon's ID for
/// the request. Real Time Response runs only `kill`, checked before and after with the read-only `ps`, in a session Pion
/// opens and closes itself: never a command of the agent's own, a script, or a file put on or deleted from the host.
/// An indicator is Pion's only by Pion's own record of what block-ioc made, never by what Falcon's copy of it says.
extension CrowdStrike {
    public static let containment = ToolDefinition(
        id: "b45bd8da-f506-4792-bebf-0951df94d438", name: "CrowdStrike Falcon Containment",
        summary: "Contain a host or lift containment, block a hash, domain or IP address and remove what it blocked, kill a process through Real Time Response, and close or reopen alerts, in CrowdStrike Falcon.",
        defaultInstructions: """
        Use CrowdStrike Falcon Containment to respond on hosts Falcon protects. Find the host with CrowdStrike Falcon \
        Detection first, by hosts, host or an alert, which give its 32-character device ID, then read it here with host: \
        its containment status, whether its sensor is online, and whether Falcon's record holds a hint that it runs \
        Kubernetes workloads or containers, which is a hint, not verified, or none. Record it as evidence before acting. \
        contain-host cuts the host off the network, keeping it connected to Falcon, until lift-containment, which must \
        be asked for explicitly; give workloads exactly as host said it, and say in the approval reason that containing \
        a host cuts off every workload on it, and what host's hint suggests runs there. block-ioc adds a custom \
        indicator: a SHA256 or MD5 Falcon blocks (prevent) or alerts on (detect), or a domain or IP address it alerts \
        on (detect only, as Falcon blocks no network indicator), and gives its ID; Pion keeps a record of each one it \
        makes, and unblock-ioc removes one by that ID only if the record says Pion made it and Falcon still holds it \
        as made. rtr-kill-process ends one process by its PID and name through Real Time Response, only when ps lists \
        that PID as that process; it cannot be undone. close-alert closes alerts, which hides them from the open queue. \
        All six are held for the champion's approval: give the exact host, indicator, process or alert, and in \
        --approval-reason why, the expected effect and how to undo it, with the Investigation as \
        --approval-conversation; give the same reason as the comment, which Falcon records where it can. \
        update-alert-status sets alerts in progress or reopens them, without approval. Pion refuses a malformed ID, a \
        host it cannot find, a host already in the state asked for or with the opposite pending, a host offline for \
        Real Time Response, an indicator it has no record of making, and anything it could not read whole first. A \
        request taken is not a request done: containment is pending until the sensor confirms it, so poll with \
        action-status; a result Pion could not verify is never reported done and keeps Falcon's request ID. Run \
        check-access when something is refused, and tell the champion exactly what it says to change.
        """,
        iconName: "crowdstrike",
        configuration: .connection(.init(endpointTemplate: "https://{region}", fields: [regionField],
                                         clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://{region}/oauth2/token"),
                                         adapter: "crowdstrike-containment")),
        setup: containmentSetup)

    /// Containment's scopes, each the narrowest Falcon has for what its actions do: reading and containing hosts,
    /// reading and updating alerts, reading and changing custom indicators, and Real Time Response's read-only and
    /// active-responder commands. No admin commands, which run scripts and put files.
    static let containmentScopes = [Scope(name: "Hosts", access: "Read"), Scope(name: "Hosts", access: "Write"), Scope(name: "Alerts", access: "Read"),
                                    Scope(name: "Alerts", access: "Write"), Scope(name: "IOC Management", access: "Read"), Scope(name: "IOC Management", access: "Write"),
                                    Scope(name: "Real time response", access: "Read"), Scope(name: "Real time response", access: "Write")]

    static let containmentSetup = [
        "In the Falcon console, open **Support and resources › API clients and keys** and choose **Create API client**. Name it Pion Falcon Containment, kept for this tool alone, apart from Pion Falcon Detection's.",
        "Give it only these scopes: \(containmentScopes.map(\.shown).joined(separator: ", ")). Never give it **Real time response (admin): Write**, which runs scripts and puts files, or any other Write scope; Falcon offers no way to check a client's scopes without trying a change, so check them on the client's page.",
        "Choose **Create**, and copy the **Client ID** and **Secret** here; Falcon shows the secret only once.",
        "For rtr-kill-process, the hosts' response policies, in **Host setup and management › Response policies**, must turn on **Real Time Response**. Pion runs only `ps` and `kill`, so leave **Custom scripts**, **put** and **run** off for it. Containing hosts, indicators and alerts need no policy change.",
        cloudStep,
    ]

    public static let containmentAdapter = OperationAdapter(operations: [
        ContainmentHost(), ActionStatus(), ContainHost(), LiftContainment(), BlockIOC(), UnblockIOC(), RTRKillProcess(), CloseAlert(),
        UpdateAlertStatus(), ContainmentCheckAccess(),
    ], simultaneousRequests: 2)

    // MARK: What it needs

    static let hostsWriteNeed = Need(title: "Containing hosts", scope: Scope(name: "Hosts", access: "Write"))
    static let alertsWriteNeed = Need(title: "Changing alerts", scope: Scope(name: "Alerts", access: "Write"))
    static let iocReadNeed = Need(title: "Custom indicators", scope: Scope(name: "IOC Management", access: "Read"))
    static let iocWriteNeed = Need(title: "Changing custom indicators", scope: Scope(name: "IOC Management", access: "Write"))
    static let rtrReadNeed = Need(title: "Real Time Response sessions and read-only commands", scope: Scope(name: "Real time response", access: "Read"))
    static let rtrWriteNeed = Need(title: "Real Time Response's kill", scope: Scope(name: "Real time response", access: "Write"))

    /// How long to wait between reads of something just asked for, before saying where it stands.
    @TaskLocal static var pauses: [Double] = [1, 2, 3, 5]

    /// What Falcon records of an action where it takes a comment: why, as the approval gave it, marked as Pion's, on one
    /// line.
    static func comment(_ value: String) throws -> String {
        let words = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (3...800).contains(words.count) else {
            throw ServiceError.input("Nothing was changed: give a comment of up to 800 characters saying why, as the approval request does; Falcon records it with the change.")
        }
        return "Requested through Pion after the champion's approval: " + words
    }

    static let hostField = JSONSchema.string("The host's 32-character device ID, as CrowdStrike Falcon Detection's hosts, host or alert gives it.")
    static let commentField = JSONSchema.string("Why: the reason given in the approval request, with the Investigation.")

    /// What Falcon said its ID for the request was, for a result that could not be verified.
    static func traced(_ trace: String?) -> String { trace.map { " Falcon's request ID: \($0)." } ?? "" }
}

// MARK: - Hosts

extension CrowdStrike {
    /// A host read just before acting on it.
    struct Target {
        let host: Host
        let online: String?
        let readAt: String
    }

    /// Reads a host whole, or refuses: a malformed ID, or a host Falcon does not return.
    static func target(_ value: String, on service: ServiceClient) async throws -> Target {
        guard let id = deviceID(value) else {
            throw ServiceError.input("Nothing was changed: give the host's 32-character device ID, as CrowdStrike Falcon Detection's hosts, host or alert gives it.")
        }
        let (found, _) = try await read(hostsNeed) { try await hosts([id], service) }
        guard let host = found.first else {
            throw ServiceError.input("Nothing was changed: Falcon did not return host \(id). It may have been removed or hidden, or the ID mistyped.")
        }
        var online: String?
        do { online = try await read(hostsNeed) { try await onlineStates([id], service) }[id] } catch { online = nil }
        return Target(host: host, online: online, readAt: iso(Date()))
    }

    /// Whether the sensor is connected now, said plainly.
    static func onlineLine(_ online: String?) -> String {
        switch online {
        case "online": "Its sensor is online now."
        case "offline": "Its sensor is offline now, so Falcon carries out containment or its lift when it next connects."
        case let other?: "Its sensor's state is \(other), so whether it is connected is unknown."
        case nil: "Whether its sensor is online could not be read, so it is unknown."
        }
    }

    struct ContainmentHost: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String }
        static let name = "host"
        static let summary = "A host's state before acting: its containment status, said plainly (pending is not done), whether its sensor is online, which Real Time Response needs, and whether Falcon's record holds a hint that it runs Kubernetes workloads or containers (a hint, not verified) or none, which contain-host's workloads must give. It changes nothing."
        static let input = JSONSchema.object(["host": CrowdStrike.hostField], required: ["host"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard CrowdStrike.deviceID(input.host) != nil else { throw ServiceError.input("Give the host's 32-character device ID.") }
            let target = try await CrowdStrike.target(input.host, on: service)
            let (kind, _) = CrowdStrike.workloads(target.host)
            let lines = [target.host.line, "Containment: \(CrowdStrike.containment(target.host.status)).", CrowdStrike.onlineLine(target.online),
                         CrowdStrike.workloadsLine(target.host) + " For contain-host, give workloads \(kind.rawValue).",
                         "Real Time Response: \(target.online == "online" ? "possible, as its sensor is online" : "Pion acts only on a host whose sensor is online now").",
                         "Read at \(target.readAt)."]
            struct Kept: Encodable { let host: String; let name: String?; let status: String?; let online: String?; let workloads: String; let readAt: String }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(host: target.host.id, name: target.host.name, status: target.host.status, online: target.online, workloads: kind.rawValue, readAt: target.readAt))
        }
    }

    struct ActionStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String?, type: String?, value: String? }
        static let name = "action-status"
        static let summary = "Where an action stands: for a host, its containment status (containment_pending and lift_containment_pending are not done; contained and normal are); for an indicator, by type and value, every custom indicator Falcon holds for it and whether Pion's own record says block-ioc made it through this connection. It changes nothing."
        static let input = JSONSchema.object([
            "host": CrowdStrike.hostField,
            "type": .string("An indicator's type.", oneOf: CrowdStrike.iocTypes),
            "value": .string("The indicator's value."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            if let host = input.host {
                guard CrowdStrike.deviceID(host) != nil else { throw ServiceError.input("Give the host's 32-character device ID.") }
                let target = try await CrowdStrike.target(host, on: service)
                let done = ["contained", "normal"].contains(target.host.status ?? "")
                let text = "\(target.host.named): containment \(CrowdStrike.containment(target.host.status)). \(CrowdStrike.onlineLine(target.online))\n\(done ? "Nothing about containment is pending." : "Not settled: poll again; containment or its lift is done only once the status is contained or normal.")\nRead at \(target.readAt)."
                struct Kept: Encodable { let host: String; let status: String?; let settled: Bool; let online: String? }
                return try ServiceResult(text: text, structured: Kept(host: target.host.id, status: target.host.status, settled: done, online: target.online))
            }
            guard let type = input.type, let value = input.value else { throw ServiceError.input("Give a host, or an indicator's type and value.") }
            let (kind, normalised) = try CrowdStrike.indicator(type, value)
            let existing = try await CrowdStrike.indicators(kind, normalised, service)
            let ours = existing.filter { (try? CrowdStrike.recorded($0.id, service)) != nil }.map(\.id)
            let text = existing.isEmpty ? "Falcon holds no custom indicator for \(kind) \(normalised)."
                : existing.map { $0.line + (ours.contains($0.id) ? " — Pion's record says it made this one through this connection" : " — Pion has no record of making this one") }.joined(separator: "\n")
            struct Kept: Encodable { let type: String; let value: String; let indicators: [String]; let recordedAsPions: [String] }
            return try ServiceResult(text: text, structured: Kept(type: kind, value: normalised, indicators: existing.map(\.id), recordedAsPions: ours))
        }
    }

    /// Asks Falcon to contain a host or lift containment, then reads the host until its status shows the request, and
    /// says where it stands: confirmed only when Falcon's answer names the host and its status then follows.
    static func containmentAction(_ action: String, _ target: Target, recovery: String, note: String?, on service: ServiceClient) async throws -> ServiceResult {
        let id = target.host.id
        struct Body: Encodable { let ids: [String] }
        struct Done: Decodable { let id: String? }
        let answer: Envelope<Done>
        do {
            answer = try await read(hostsWriteNeed) {
                try await post(service, ["devices", "entities", "devices-actions", "v2"], query: ["action_name": action], body: Body(ids: [id]), as: Done.self)
            }
        } catch ServiceError.unreadable {
            throw ServiceError.input("Falcon answered the request to \(action == "contain" ? "contain" : "lift containment of") \(target.host.named) with something that could not be read, so whether it took it is not known. Run host before asking again.\n\(recovery)")
        }
        let trace = answer.meta?.trace_id
        if let problems = answer.problems, !(answer.resources ?? []).contains(where: { $0.id.flatMap(deviceID) == id }) {
            throw ServiceError.input("Falcon refused to \(action == "contain" ? "contain" : "lift containment of") \(target.host.named): \(problems). Nothing is reported changed.\(traced(trace))")
        }
        let named = (answer.resources ?? []).contains { $0.id.flatMap(deviceID) == id }
        let pending = action == "contain" ? "containment_pending" : "lift_containment_pending"
        let done = action == "contain" ? "contained" : "normal"
        var status: String?, unread: String?, waited = 0.0
        for pause in pauses {
            await CrowdStrike.pause(pause)
            waited += pause
            do {
                let (found, _) = try await hosts([id], service)
                status = found.first?.status
                unread = found.first == nil ? "Falcon did not return the host" : nil
            } catch { unread = error.localizedDescription }
            if status == done { break }
        }
        var lines: [String] = []
        let verb = action == "contain" ? "contain" : "lift containment of"
        guard named, status == pending || status == done else {
            let why = !named ? "Falcon's answer did not name the host" : unread.map { "reading the host again failed (\($0))" } ?? "its status after \(Int(waited)) seconds is \(CrowdStrike.containment(status))"
            throw ServiceError.input("Falcon took the request to \(verb) \(target.host.named), but it could not be verified: \(why). It is not reported done. Read it with action-status before going on.\(traced(trace))\n\(recovery)")
        }
        lines.append("Asked Falcon to \(verb) \(target.host.named): Falcon named the host in its answer, and after \(Int(waited)) seconds its status is \(CrowdStrike.containment(status)).")
        if status == pending { lines.append("Pending is not done: the sensor carries it out when it next connects. Poll with action-status until the status is \(done).") }
        lines.append(onlineLine(target.online))
        if let note { lines.append(note) }
        lines.append(recovery)
        lines.append("\(target.host.named) was read at \(target.readAt). Falcon takes no condition on the request, so someone else may have acted on it between that read and this request.")
        struct Kept: Encodable { let host: String; let action: String; let status: String?; let done: Bool; let recovery: String; let trace: String? }
        return try ServiceResult(text: lines.joined(separator: "\n"),
                                 structured: Kept(host: id, action: action, status: status, done: status == done, recovery: recovery, trace: trace))
    }

    struct ContainHost: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String; let workloads: String }
        static let name = "contain-host"
        static let recovery = "Recovery: lift-containment restores the host's network access, and must be asked for explicitly; until then the host reaches only the Falcon cloud, so its user cannot work on it, and every workload on it, every pod and container it runs included, is cut off too."
        static let summary = "Contain a host: cut it, and every workload on it, off the network, keeping it connected to Falcon. workloads repeats what host read: kubernetes-suggested or containers-suggested when Falcon's record holds a hint that the host runs Kubernetes workloads or containers, which suggests but does not verify what it is; cannot-tell when it holds none, which is not proof it runs none. \(recovery)"
        static let input = JSONSchema.object([
            "host": CrowdStrike.hostField,
            "workloads": .string("Exactly what host says of the workloads on it, so the approval shows it: kubernetes-suggested, containers-suggested or cannot-tell.",
                                 oneOf: Workloads.allCases.map(\.rawValue)),
        ], required: ["host", "workloads"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let given = try ServiceInput.oneOf(input.workloads, Workloads.allCases.map(\.rawValue), "workloads")
            let target = try await CrowdStrike.target(input.host, on: service)
            let (kind, signs) = CrowdStrike.workloads(target.host)
            guard kind.rawValue == given else {
                throw ServiceError.input("Nothing was changed: the approval gave workloads \(given), but Falcon's record of \(target.host.named) reads \(kind.rawValue)\(signs.isEmpty ? "" : " (hint: \(signs.joined(separator: "; ")), not verified)"). Ask again with workloads \(kind.rawValue), so the approval says what containing it may cut off.")
            }
            switch target.host.status {
            case "contained": throw ServiceError.input("Nothing was changed: \(target.host.named) is already contained. lift-containment lifts it.")
            case "containment_pending": throw ServiceError.input("Nothing was changed: containment of \(target.host.named) is already pending; poll it with action-status.")
            case "lift_containment_pending": throw ServiceError.input("Nothing was changed: a lift of containment of \(target.host.named) is pending, and the two would race. Wait for it with action-status.")
            default: break
            }
            let unknown = target.host.status == nil || target.host.status != "normal" ? "Its containment status before this was \(CrowdStrike.containment(target.host.status)), so whether it was already contained could not be confirmed." : nil
            let note = [CrowdStrike.workloadsLine(target.host), unknown].compactMap { $0 }.joined(separator: " ")
            return try await CrowdStrike.containmentAction("contain", target, recovery: Self.recovery, note: note, on: service)
        }
    }

    struct LiftContainment: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String }
        static let name = "lift-containment"
        static let recovery = "Recovery: contain-host again. Lifting restores the host's full network access, an attacker's still on it included, so lift it only once the champion judges it clean."
        static let summary = "Lift a host's containment, restoring its network access. Held like the rest, as it gives access back. \(recovery)"
        static let input = JSONSchema.object(["host": CrowdStrike.hostField], required: ["host"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await CrowdStrike.target(input.host, on: service)
            switch target.host.status {
            case "normal": throw ServiceError.input("Nothing was changed: \(target.host.named) is not contained, so there is nothing to lift.")
            case "lift_containment_pending": throw ServiceError.input("Nothing was changed: a lift of containment of \(target.host.named) is already pending; poll it with action-status.")
            case "containment_pending": throw ServiceError.input("Nothing was changed: containment of \(target.host.named) is still pending, and the two would race. Wait for it with action-status.")
            default: break
            }
            let unknown = target.host.status != "contained" ? "Its containment status before this was \(CrowdStrike.containment(target.host.status)), so whether it was contained could not be confirmed." : nil
            return try await CrowdStrike.containmentAction("lift_containment", target, recovery: Self.recovery, note: unknown, on: service)
        }
    }
}

// MARK: - Custom indicators

extension CrowdStrike {
    static let iocTypes = ["sha256", "md5", "domain", "ipv4", "ipv6"]
    static let iocSeverities = ["informational", "low", "medium", "high", "critical"]
    static let iocPlatforms = ["windows", "mac", "linux"]
    /// The source Pion gives the indicators it makes, for people reading them in the console. It proves nothing, as
    /// anyone can give an indicator any source: only Pion's own record says which indicators it made.
    static let iocSource = "Pion"

    /// An indicator's type and value, checked and written as Falcon keeps it.
    static func indicator(_ type: String, _ value: String) throws -> (type: String, value: String) {
        let kind = try ServiceInput.oneOf(type.lowercased(), iocTypes, "type")
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "sha256", "md5":
            let length = kind == "sha256" ? 64 : 32
            guard value.count == length, value.allSatisfy(\.isHexDigit) else { throw ServiceError.input("Nothing was changed: give the \(kind.uppercased()) as \(length) hexadecimal characters.") }
            return (kind, value.lowercased())
        case "domain":
            return (kind, try ServiceInput.domain(value))
        default:
            var v4 = in_addr(), v6 = in6_addr()
            let ok = kind == "ipv4" ? inet_pton(AF_INET, value, &v4) == 1 : inet_pton(AF_INET6, value, &v6) == 1
            guard ok else { throw ServiceError.input("Nothing was changed: \"\(value)\" is not an \(kind == "ipv4" ? "IPv4" : "IPv6") address.") }
            return (kind, value.lowercased())
        }
    }

    /// An indicator's ID as Falcon gives it: letters, digits, hyphens and underscores.
    static func indicatorID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(value.count),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains) else { return nil }
        return value
    }

    struct Indicator: Decodable, Sendable {
        let id: String
        let type: String?, value: String?, action: String?, severity: String?, platforms: [String]?, source: String?, description: String?
        let expiration: String?, created_by: String?, created_on: String?, modified_on: String?, applied_globally: Bool?, deleted: Bool?
        let host_groups: [String]?, tags: [String]?, mobile_action: String?
        /// Falcon's version of the indicator, when it gives one, in whatever form.
        let version: CellValue?

        var line: String {
            "\(type ?? "?") \(value ?? "?"): \(action ?? "action unknown")\(severity.map { ", \($0)" } ?? "") on \((platforms ?? []).joined(separator: ", ")), \(scope), expires \(expiration.flatMap { $0.isEmpty ? nil : $0 } ?? "never"), source \(source ?? "not given"), made by \(created_by ?? "unknown") at \(created_on ?? "?") [\(id)]"
        }

        /// Where it applies, as Falcon says: every host, some host groups, or not said.
        var scope: String {
            switch (applied_globally, host_groups ?? []) {
            case (true?, _): "applied on every host"
            case (_, let groups) where !groups.isEmpty: "applied on host groups \(groups.joined(separator: ", "))"
            case (false?, _): "not applied globally, and on no host group Falcon named"
            case (nil, _): "where it applies not given"
            }
        }
    }

    /// Everything about an indicator that says what it does and whether it changed, as Falcon gave it, compared field by
    /// field: what block-ioc's answer said it made is kept, and unblock-ioc removes an indicator only while Falcon still
    /// gives exactly that.
    struct IndicatorSnapshot: Codable, Equatable, Sendable {
        var type: String?, value: String?, action: String?, severity: String?, platforms: [String]?, appliedGlobally: Bool?, hostGroups: [String]?
        var expiration: String?, tags: [String]?, mobileAction: String?, modified: String?, version: String?

        init(_ indicator: Indicator) {
            func text(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0.lowercased() } }
            func list(_ values: [String]?) -> [String]? { values.map { $0.map { $0.lowercased() }.sorted() } }
            func time(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : ServiceAlert.time($0).map(CrowdStrike.iso) ?? $0 } }
            type = text(indicator.type); value = text(indicator.value); action = text(indicator.action); severity = text(indicator.severity)
            platforms = list(indicator.platforms); appliedGlobally = indicator.applied_globally; hostGroups = list(indicator.host_groups)
            expiration = time(indicator.expiration); tags = list(indicator.tags); mobileAction = text(indicator.mobile_action)
            modified = indicator.modified_on.flatMap { $0.isEmpty ? nil : $0 }
            version = indicator.version.flatMap { if case .none = $0 { return nil }; return $0.shown }
        }

        /// Each field Falcon now gives otherwise than this snapshot, or that either leaves out where it must say: an
        /// empty list means the indicator is as it was.
        func differences(_ now: IndicatorSnapshot) -> [String] {
            var found: [String] = []
            func check(_ name: String, was: String?, now: String?, same: Bool, required: Bool) {
                if required, was == nil || now == nil { found.append("\(name) \(was == nil ? "was" : "is") not given, so whether it changed cannot be told"); return }
                if !same { found.append("\(name) \(was ?? "not given") is now \(now ?? "not given")") }
            }
            // One for each kind of field, so a missing value is never mistaken for a present one.
            func compare(_ name: String, _ was: String?, _ now: String?, required: Bool = false) {
                check(name, was: was, now: now, same: was == now, required: required)
            }
            func compare(_ name: String, _ was: [String]?, _ now: [String]?, required: Bool = false) {
                check(name, was: was.map { $0.isEmpty ? "none" : $0.joined(separator: ", ") }, now: now.map { $0.isEmpty ? "none" : $0.joined(separator: ", ") },
                      same: was == now, required: required)
            }
            func compare(_ name: String, _ was: Bool?, _ now: Bool?, required: Bool = false) {
                check(name, was: was.map(String.init), now: now.map(String.init), same: was == now, required: required)
            }
            compare("type", type, now.type, required: true)
            compare("value", value, now.value, required: true)
            compare("action", action, now.action, required: true)
            compare("severity", severity, now.severity, required: true)
            compare("platforms", platforms, now.platforms, required: true)
            compare("applied globally", appliedGlobally, now.appliedGlobally, required: true)
            compare("host groups", hostGroups ?? [], now.hostGroups ?? [] as [String]?)
            compare("expiration", expiration, now.expiration)
            compare("tags", tags ?? [], now.tags ?? [] as [String]?)
            compare("mobile action", mobileAction, now.mobileAction)
            compare("modified_on", modified, now.modified, required: true)
            compare("version", version, now.version)
            return found
        }
    }

    /// Every custom indicator Falcon holds for a type and value, read whole, or the read fails.
    static func indicators(_ type: String, _ value: String, _ service: ServiceClient) async throws -> [Indicator] {
        let listing = try await read(iocReadNeed) {
            try await list(service, ["iocs", "combined", "indicator", "v1"], query: ["filter": "type:'\(type)'+value:'\(value)'"], as: Indicator.self,
                           paging: .after, size: 50, pages: 2, partial: false)
        }
        guard listing.complete else {
            throw ServiceError.input("Nothing was changed: not every custom indicator for \(type) \(value) could be read (\(listing.stopped ?? "more than Pion reads at once")), so whether one exists is not known.")
        }
        return listing.value.filter { $0.type?.lowercased() == type && $0.value?.lowercased() == value && $0.deleted != true }
    }

    // MARK: Pion's record

    /// An indicator block-ioc made: its ID, when, and all Falcon's answer said of it.
    struct IndicatorRecord: Codable, Equatable, Sendable {
        let id: String
        let created: Date
        let made: IndicatorSnapshot
        var type: String { made.type ?? "?" }
        var value: String { made.value ?? "?" }
    }

    /// The indicators block-ioc made, the only ones unblock-ioc removes, by connection and Falcon cloud: kept in memory,
    /// and in the file the app names, so they outlast a relaunch. A connection's client reaches one customer, so the
    /// connection and its cloud name the customer.
    struct IndicatorBook: Sendable {
        var file: URL? = nil
        var records: [String: [IndicatorRecord]] = [:]
    }
    static let indicatorBook = Mutex(IndicatorBook())

    /// Keeps Pion's record of the indicators it made in `file`, reading what it already holds; nil keeps it in memory.
    public static func keepIndicatorRecords(at file: URL?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([String: [IndicatorRecord]].self, from: $0) } ?? [:]
        indicatorBook.withLock { $0 = IndicatorBook(file: file, records: saved) }
    }

    /// Whose record a call reads: its connection, in its Falcon cloud.
    static func recordKey(_ service: ServiceClient) throws -> String {
        guard let account = service.account else {
            throw ServiceError.input("Nothing was changed: Pion cannot tell which connection this is, so it can keep no record of the indicators it makes, and makes none.")
        }
        return "\(account.uuidString.lowercased())@\(try cloud(service).host)"
    }

    static func recorded(_ id: String, _ service: ServiceClient) throws -> IndicatorRecord? {
        let key = try recordKey(service)
        return indicatorBook.withLock { $0.records[key]?.first { $0.id == id } }
    }

    /// Adds or removes a record, saving the file when there is one; a record that could not be saved is said.
    static func changeRecords(_ service: ServiceClient, _ change: (inout [IndicatorRecord]) -> Void) throws {
        let key = try recordKey(service)
        try indicatorBook.withLock { book in
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

    struct BlockIOC: ServiceOperation {
        struct Input: Decodable, Sendable { let type: String; let value: String; let action: String; let severity: String; let platforms: [String]; let expiration: String?; let comment: String }
        static let name = "block-ioc"
        static let recovery = "Recovery: unblock-ioc with the indicator's ID removes it, which ends the blocking and alerting at once; Falcon does not restore a file it quarantined or a process it stopped while the indicator was in force, which a quarantined file's release in the Falcon console does."
        static let summary = "Add a custom indicator, applied to every host, and keep a record that Pion made it, which unblock-ioc needs: a SHA256 or MD5 Falcon blocks (prevent) or alerts on (detect), or a domain, IPv4 or IPv6 address it alerts on (detect only). It refuses when Falcon already holds an indicator for the value, whoever made it. \(recovery)"
        static let input = JSONSchema.object([
            "type": .string("The indicator's type.", oneOf: CrowdStrike.iocTypes),
            "value": .string("The hash, domain or address."),
            "action": .string("prevent blocks the hash on every host; detect alerts on it. Domains and addresses take detect only.", oneOf: ["prevent", "detect"]),
            "severity": .string("The severity of the alert it raises.", oneOf: CrowdStrike.iocSeverities),
            "platforms": .array(.string("A platform.", oneOf: CrowdStrike.iocPlatforms), "The platforms it applies to."),
            "expiration": .string("When it ends, in ISO 8601, within a year. Never when left out."),
            "comment": CrowdStrike.commentField,
        ], required: ["type", "value", "action", "severity", "platforms", "comment"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (type, value) = try CrowdStrike.indicator(input.type, input.value)
            let action = try ServiceInput.oneOf(input.action, ["prevent", "detect"], "action")
            guard action == "detect" || ["sha256", "md5"].contains(type) else {
                throw ServiceError.input("Nothing was changed: Falcon blocks only hashes; a \(type) takes detect, which alerts on it. Block it at the firewall or DNS to stop it.")
            }
            let severity = try ServiceInput.oneOf(input.severity.lowercased(), CrowdStrike.iocSeverities, "severity")
            let platforms = try ServiceInput.list(input.platforms.map { $0.lowercased() }, limit: 3) { try ServiceInput.oneOf($0, CrowdStrike.iocPlatforms, "each platform") }
            guard Set(platforms).count == platforms.count else { throw ServiceError.input("Nothing was changed: give each platform once.") }
            var expiration: Date?
            if let given = input.expiration {
                guard let date = ServiceAlert.time(try ServiceInput.time(given)), date > Date().addingTimeInterval(300), date < Date().addingTimeInterval(366 * 86_400) else {
                    throw ServiceError.input("Nothing was changed: give an expiration in the future, within a year.")
                }
                expiration = date
            }
            let comment = try CrowdStrike.comment(input.comment)
            _ = try CrowdStrike.recordKey(service)
            let existing = try await CrowdStrike.indicators(type, value, service)
            if let held = existing.first {
                let ours = (try? CrowdStrike.recorded(held.id, service)) != nil
                throw ServiceError.input("Nothing was changed: Falcon already holds an indicator for \(type) \(value), \(ours ? "which Pion made through this connection" : "which Pion has no record of making, so it leaves it alone"): \(held.line).\(ours ? " unblock-ioc with its ID removes it, if it should be made again otherwise." : " Change it in the Falcon console if it should block.")")
            }
            struct Item: Encodable {
                let type: String, value: String, action: String, severity: String, platforms: [String], expiration: String?, source: String, description: String, applied_globally: Bool
            }
            struct Body: Encodable { let comment: String; let indicators: [Item] }
            let body = Body(comment: comment, indicators: [Item(type: type, value: value, action: action, severity: severity, platforms: platforms,
                                                                expiration: expiration.map(CrowdStrike.iso), source: CrowdStrike.iocSource, description: comment, applied_globally: true)])
            let answer = try await CrowdStrike.read(CrowdStrike.iocWriteNeed) {
                try await CrowdStrike.post(service, ["iocs", "entities", "indicators", "v1"], query: ["ignore_warnings": "false", "retrodetects": "false"], body: body, as: Indicator.self)
            }
            let trace = answer.meta?.trace_id
            let made = (answer.resources ?? []).first { $0.type?.lowercased() == type && $0.value?.lowercased() == value }
            guard let made, let id = CrowdStrike.indicatorID(made.id) else {
                if let problems = answer.problems {
                    throw ServiceError.input("Falcon refused the indicator for \(type) \(value): \(problems). Nothing is reported made; action-status reads what Falcon holds for it.\(CrowdStrike.traced(trace))")
                }
                throw ServiceError.input("Falcon answered, but did not name the indicator for \(type) \(value), so whether it was made could not be verified, and Pion kept no record of it: unblock-ioc cannot remove it. Read it with action-status, and remove it in the Falcon console if it was made.\(CrowdStrike.traced(trace))\n\(Self.recovery)")
            }
            // Recorded as Falcon made it, whatever was approved, so unblock-ioc can remove one made otherwise too.
            let snapshot = IndicatorSnapshot(made)
            do {
                try CrowdStrike.changeRecords(service) { records in
                    records.removeAll { $0.id == id }
                    records.append(IndicatorRecord(id: id, created: Date(), made: snapshot))
                }
            } catch {
                throw ServiceError.input("Falcon made indicator \(id) for \(type) \(value), but Pion could not keep its record of it (\(error.localizedDescription)), so unblock-ioc cannot remove it: remove it in the Falcon console when it should go.\(CrowdStrike.traced(trace))")
            }
            // Done only when Falcon's answer says it made exactly what was approved: on every host, for as long as asked.
            var differs: [String] = []
            if snapshot.action != action { differs.append("action \(made.action ?? "not given")") }
            if snapshot.severity != severity { differs.append("severity \(made.severity ?? "not given")") }
            if snapshot.platforms.map(Set.init) != Set(platforms) { differs.append("platforms \(snapshot.platforms.map { $0.joined(separator: ", ") } ?? "not given")") }
            if snapshot.appliedGlobally != true || !(snapshot.hostGroups ?? []).isEmpty { differs.append("\(made.scope), not on every host") }
            switch (expiration, snapshot.expiration) {
            case (nil, nil): break
            case (nil, let given?): differs.append("expiration \(given), where none was asked for")
            case (let asked?, let given):
                if given.flatMap(ServiceAlert.time).map({ abs($0.timeIntervalSince(asked)) > 1 }) ?? true { differs.append("expiration \(given ?? "not given"), not \(CrowdStrike.iso(asked))") }
            }
            guard differs.isEmpty else {
                throw ServiceError.input("Falcon made indicator \(id), but not as approved, so it is not reported done. What Falcon says it made: \(made.line). Where it differs: \(differs.joined(separator: "; ")). Pion keeps its record of it, so unblock-ioc with its ID can remove it; read it with action-status.\(CrowdStrike.traced(trace))\n\(Self.recovery)")
            }
            let notes = snapshot.modified == nil ? ["Falcon's answer gave no modified time, so unblock-ioc cannot tell later whether it changed and will leave it in place; remove it in the Falcon console when it should go."] : []
            let lines = ["Falcon made custom indicator \(id): \(type) \(value), \(action == "prevent" ? "blocked" : "alerted on") at \(severity) severity on \(platforms.joined(separator: ", ")), on every host, \(expiration.map { "until \(CrowdStrike.iso($0))" } ?? "with no expiration"). Pion keeps a record that it made it, which unblock-ioc needs.",
                         action == "prevent" ? "Falcon blocks the file from running when hosts next take their policy, within minutes; files already running are not stopped by this." : "Falcon raises an alert where it sees it; it blocks nothing."]
                + notes + [Self.recovery]
            struct Kept: Encodable { let id: String; let type: String; let value: String; let action: String; let done: Bool; let recovery: String; let trace: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(id: id, type: type, value: value, action: action, done: true, recovery: Self.recovery, trace: trace))
        }
    }

    /// What Falcon says of one indicator by its ID.
    enum Lookup {
        case present(Indicator)
        /// Falcon said plainly it holds none: an answer with an empty list and no errors, a 404 saying it found none, or
        /// the indicator marked deleted.
        case absent
        /// Anything else, which shows neither: errors, other indicators, or an answer that could not be read.
        case inconclusive(String)
    }

    static func indicator(id: String, _ service: ServiceClient) async throws -> Lookup {
        let answer = try await read(iocReadNeed) { () -> (data: Data, response: HTTPURLResponse) in
            let answer = try await raw(service, ["iocs", "entities", "indicators", "v1"], repeated: ["ids": [id]])
            if answer.response.statusCode != 404 { try check(answer) }
            return answer
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<Indicator>.self, from: answer.data) else {
            return .inconclusive("Falcon's answer for indicator \(id) could not be read")
        }
        let named = (envelope.resources ?? []).filter { $0.id == id }
        let others = (envelope.resources ?? []).filter { $0.id != id }.map(\.id)
        // A 404 is absence only when every error it carries has code 404 and names this very indicator in its own id
        // field. Wording is never read: a message may name a longer ID, echo the request's address, or say "not found"
        // of something else under another code.
        if answer.response.statusCode == 404 {
            let errors = envelope.errors ?? []
            let names = !errors.isEmpty && errors.allSatisfy { $0.code == 404 && $0.id == id }
            guard named.isEmpty, others.isEmpty, names else {
                return .inconclusive("Falcon answered 404 for indicator \(id) without saying that indicator was not found\(envelope.problems.map { " (it said: \($0))" } ?? "")")
            }
            return .absent
        }
        // Any error at all, with a message or without, makes the rest of the answer no proof either way.
        if let problems = envelope.problems { return .inconclusive("Falcon's answer for indicator \(id) carried errors: \(problems)") }
        if !others.isEmpty { return .inconclusive("Falcon answered for indicator \(others.prefix(3).joined(separator: ", ")), not \(id)") }
        guard envelope.resources != nil else { return .inconclusive("Falcon's answer for indicator \(id) gave no list") }
        switch named.count {
        case 0: return .absent
        case 1: return named[0].deleted == true ? .absent : .present(named[0])
        default: return .inconclusive("Falcon's answer names indicator \(id) \(named.count) times")
        }
    }

    struct UnblockIOC: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String; let comment: String }
        static let name = "unblock-ioc"
        static let recovery = "Recovery: block-ioc again restores it. Removing it lets the hash run, or the domain or address go unremarked, on every host at once."
        static let summary = "Remove one custom indicator, by its ID, that Pion's own record says block-ioc made through this connection and that Falcon still holds as made; any other is left in place, whatever its source or description says. Held, as it lifts a block. \(recovery)"
        static let input = JSONSchema.object([
            "id": .string("The indicator's ID, as block-ioc gave it."),
            "comment": CrowdStrike.commentField,
        ], required: ["id", "comment"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard let id = CrowdStrike.indicatorID(input.id) else { throw ServiceError.input("Nothing was changed: give the indicator's ID exactly as block-ioc gave it.") }
            let comment = try CrowdStrike.comment(input.comment)
            guard let record = try CrowdStrike.recorded(id, service) else {
                throw ServiceError.input("Nothing was changed: Pion has no record of making indicator \(id) through this connection, so it leaves it in place, whatever its source or description says. Remove it in the Falcon console if it should go.")
            }
            let held: Indicator
            switch try await CrowdStrike.indicator(id: id, service) {
            case .absent:
                try? CrowdStrike.changeRecords(service) { $0.removeAll { $0.id == id } }
                throw ServiceError.input("Nothing was changed: Falcon says it holds no indicator \(id) (\(record.type) \(record.value)), so there is nothing to remove; Pion drops its record of it.")
            case .inconclusive(let why):
                throw ServiceError.input("Nothing was changed: whether Falcon still holds indicator \(id) as Pion made it could not be told (\(why)), so it is left in place, and Pion keeps its record.")
            case .present(let indicator): held = indicator
            }
            let changed = record.made.differences(IndicatorSnapshot(held))
            guard changed.isEmpty else {
                throw ServiceError.input("Nothing was changed: indicator \(id) is not, or cannot be shown to be, as Pion made it: \(changed.joined(separator: "; ")). Someone may have changed it, so Pion leaves it in place; remove it in the Falcon console if it should go.")
            }
            // By ID alone: Falcon's delete prefers a filter over IDs, which could match more than the one approved. What it
            // answers is read loosely, as only reading the indicator again says whether it went.
            let answer: Envelope<CellValue> = try await CrowdStrike.read(CrowdStrike.iocWriteNeed) {
                try CrowdStrike.decode(try await CrowdStrike.exchange(service, ["iocs", "entities", "indicators", "v1"], query: ["comment": comment],
                                                                      repeated: ["ids": [id]], method: "DELETE").data)
            }
            let trace = answer.meta?.trace_id
            await CrowdStrike.pause(CrowdStrike.pauses.first ?? 0)
            let after: Lookup
            do { after = try await CrowdStrike.indicator(id: id, service) } catch { after = .inconclusive("reading it again failed: \(error.localizedDescription)") }
            switch after {
            case .absent: break
            case .present(let still):
                throw ServiceError.input("Falcon still holds \(still.line) after the request to remove it, so it is not reported removed and Pion keeps its record.\(answer.problems.map { " Falcon said: \($0)." } ?? "")\(CrowdStrike.traced(trace))\n\(Self.recovery)")
            case .inconclusive(let why):
                throw ServiceError.input("Falcon took the request to remove indicator \(id), but whether it is gone is unverified (\(why)), so it is not reported removed and Pion keeps its record. Read it with action-status.\(answer.problems.map { " Falcon said: \($0)." } ?? "")\(CrowdStrike.traced(trace))\n\(Self.recovery)")
            }
            var lines = ["Removed custom indicator \(id), \(record.type) \(record.value), which Pion made through this connection: Falcon no longer holds it."]
            do { try CrowdStrike.changeRecords(service) { $0.removeAll { $0.id == id } } }
            catch { lines.append("Pion could not drop its record of it (\(error.localizedDescription)); that changes nothing in Falcon.") }
            lines.append(Self.recovery)
            struct Kept: Encodable { let removed: String; let done: Bool; let recovery: String; let trace: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(removed: id, done: true, recovery: Self.recovery, trace: trace))
        }
    }
}

// MARK: - Real Time Response

extension CrowdStrike {
    /// A Real Time Response session Pion opened on one host.
    struct RTRSession: Sendable { let id: String; let host: String }

    /// What one command printed, once Falcon says it is complete.
    struct Output: Sendable { let stdout: String; let stderr: String; let request: String }

    /// Opens a session on an online host, never queued for one offline.
    static func openSession(_ target: Target, _ service: ServiceClient) async throws -> RTRSession {
        guard target.online == "online" else {
            throw ServiceError.input("Nothing was changed: Real Time Response needs \(target.host.named)'s sensor online, and it is \(target.online ?? "of unknown state"). Pion does not queue commands for an offline host; ask again once it is online, or contain it meanwhile.")
        }
        struct Body: Encodable { let device_id: String; let origin: String; let queue_offline: Bool }
        struct Opened: Decodable { let session_id: String?; let device_id: String?; let offline_queued: Bool? }
        let answer = try await read(rtrReadNeed) {
            try await post(service, ["real-time-response", "entities", "sessions", "v1"], body: Body(device_id: target.host.id, origin: iocSource, queue_offline: false), as: Opened.self)
        }
        guard let opened = (answer.resources ?? []).first, let id = opened.session_id, (try? plainID(id, "the session")) != nil,
              opened.device_id.map({ deviceID($0) == target.host.id }) ?? true else {
            throw ServiceError.input("Nothing was changed: Falcon did not open a Real Time Response session on \(target.host.named) that Pion could read\(answer.problems.map { " (it said: \($0))" } ?? "").\(traced(answer.meta?.trace_id))")
        }
        let session = RTRSession(id: id, host: target.host.id)
        if opened.offline_queued == true {
            await closeSession(session, service)
            throw ServiceError.input("Nothing was changed: Falcon queued the session for when \(target.host.named) comes online, which Pion does not do; it closed the session.")
        }
        return session
    }

    /// Closes a session, saying so when Falcon would not; it then ends by itself after ten minutes idle.
    @discardableResult
    static func closeSession(_ session: RTRSession, _ service: ServiceClient) async -> String? {
        do {
            _ = try await exchange(service, ["real-time-response", "entities", "sessions", "v1"], query: ["session_id": session.id], method: "DELETE")
            return nil
        } catch {
            return "Closing the Real Time Response session \(session.id) failed (\(error.localizedDescription)); Falcon ends it after ten minutes idle."
        }
    }

    /// Runs one fixed command in Pion's session and reads it until Falcon says it is complete: read-only commands
    /// through Real Time Response's command endpoint, kill and rm through its active-responder one.
    static func run(_ base: String, _ command: String, activeResponder: Bool, in session: RTRSession, _ service: ServiceClient) async throws -> Output {
        let endpoint = activeResponder ? "active-responder-command" : "command"
        let need = activeResponder ? rtrWriteNeed : rtrReadNeed
        struct Body: Encodable { let base_command: String; let command_string: String; let session_id: String; let device_id: String; let persist: Bool }
        struct Queued: Decodable { let cloud_request_id: String?; let session_id: String?; let queued_command_offline: Bool? }
        let queued = try await read(need) {
            try await post(service, ["real-time-response", "entities", endpoint, "v1"],
                           body: Body(base_command: base, command_string: command, session_id: session.id, device_id: session.host, persist: false), as: Queued.self)
        }
        guard let request = (queued.resources ?? []).first?.cloud_request_id, (try? plainID(request, "the request")) != nil,
              (queued.resources ?? []).first?.session_id.map({ $0 == session.id }) ?? true else {
            throw ServiceError.input("Falcon did not take \(base) in Pion's session in a way Pion could read\(queued.problems.map { " (it said: \($0))" } ?? "").\(traced(queued.meta?.trace_id))")
        }
        struct Status: Decodable { let complete: Bool?; let stdout: String?; let stderr: String?; let base_command: String?; let session_id: String? }
        for pause in pauses {
            await CrowdStrike.pause(pause)
            let status = try await read(need) {
                try await get(service, ["real-time-response", "entities", endpoint, "v1"], query: ["cloud_request_id": request, "sequence_id": "0"], as: Status.self)
            }
            if let problems = status.problems {
                throw ServiceError.input("Falcon's answer for request \(request) carried errors (\(problems)), so what \(base) did is not known.")
            }
            guard let result = (status.resources ?? []).first else { continue }
            if let said = result.base_command, said.lowercased() != base { throw ServiceError.input("Falcon answered request \(request) for \(said), not \(base), so nothing it said is taken.") }
            if let said = result.session_id, said != session.id { throw ServiceError.input("Falcon answered request \(request) for another session, so nothing it said is taken.") }
            if result.complete == true { return Output(stdout: result.stdout ?? "", stderr: result.stderr ?? "", request: request) }
        }
        throw ServiceError.input("\(base) did not complete within \(Int(pauses.reduce(0, +))) seconds (request \(request)), so what it did is not known.")
    }

    /// The lines of `ps` that name a PID, as one of their whitespace-separated words.
    static func processLines(_ output: String, pid: Int) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { line in line.split(whereSeparator: \.isWhitespace).contains { $0 == String(pid) } }
    }

    /// Whether a line names a process: one of its words is the name, or a path ending in it.
    static func names(_ line: String, _ process: String) -> Bool {
        let name = process.lowercased()
        return line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }.contains { $0 == name || $0.hasSuffix("/" + name) || $0.hasSuffix("\\" + name) }
    }

    /// A process's name as `ps` shows it: no spaces or separators, nothing a command could read as more.
    static func processName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...255).contains(value.count),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+@()").contains) else {
            throw ServiceError.input("Nothing was changed: give the process's name as ps shows it, such as evil.exe, without a path or spaces.")
        }
        return value
    }

    struct RTRKillProcess: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String; let pid: Int; let process: String }
        static let name = "rtr-kill-process"
        static let recovery = "Recovery: none: a killed process's memory and unsaved work are gone for good, so record what it was first; it can only be started again, and a service may restart itself."
        static let summary = "End one process on a host, by its PID and name, through Real Time Response's kill, only when ps lists that PID as that process; then list the processes again and say whether the process with that PID and name is still listed, which is what ps shows, not proof that the kill ended it. The host's sensor must be online. \(recovery)"
        static let input = JSONSchema.object([
            "host": CrowdStrike.hostField,
            "pid": .integer("The process's ID, as ps or an alert gives it.", minimum: 1, maximum: 4_294_967_295),
            "process": .string("The process's name as ps shows it, such as evil.exe."),
        ], required: ["host", "pid", "process"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard (5...4_294_967_295).contains(input.pid) else { throw ServiceError.input("Nothing was changed: give a PID above 4; Pion never ends the system's own processes.") }
            let process = try CrowdStrike.processName(input.process)
            let target = try await CrowdStrike.target(input.host, on: service)
            let session = try await CrowdStrike.openSession(target, service)
            do {
                let result = try await kill(input.pid, process, target, session, service)
                let closing = await CrowdStrike.closeSession(session, service)
                return closing.map { result.adding("\n" + $0) } ?? result
            } catch {
                guard let closing = await CrowdStrike.closeSession(session, service) else { throw error }
                throw ServiceError.input(error.localizedDescription + "\n" + closing)
            }
        }

        private func kill(_ pid: Int, _ process: String, _ target: Target, _ session: RTRSession, _ service: ServiceClient) async throws -> ServiceResult {
            let before = try await CrowdStrike.run("ps", "ps", activeResponder: false, in: session, service)
            guard before.stderr.isEmpty, !before.stdout.isEmpty else {
                throw ServiceError.input("Nothing was changed: ps on \(target.host.named) gave no list of processes\(before.stderr.isEmpty ? "" : " (it said: \(before.stderr.prefix(300)))"), so which process has PID \(pid) is not known.")
            }
            let listed = CrowdStrike.processLines(before.stdout, pid: pid)
            guard !listed.isEmpty else { throw ServiceError.input("Nothing was changed: no process with PID \(pid) is running on \(target.host.named), as ps listed them at \(CrowdStrike.iso(Date())).") }
            guard listed.count == 1 else { throw ServiceError.input("Nothing was changed: ps on \(target.host.named) lists PID \(pid) on \(listed.count) lines, so which is the process is not clear:\n\(listed.prefix(5).joined(separator: "\n"))") }
            guard CrowdStrike.names(listed[0], process) else {
                throw ServiceError.input("Nothing was changed: PID \(pid) on \(target.host.named) is not \(process), as approved; ps shows: \(listed[0].prefix(300))")
            }
            let killed = try await CrowdStrike.run("kill", "kill \(pid)", activeResponder: true, in: session, service)
            guard killed.stderr.isEmpty else {
                throw ServiceError.input("Real Time Response's kill of PID \(pid) (\(process)) on \(target.host.named) failed: \(killed.stderr.prefix(300)). Request \(killed.request).")
            }
            var after: Output?, unread: String?
            do { after = try await CrowdStrike.run("ps", "ps", activeResponder: false, in: session, service) } catch { unread = error.localizedDescription }
            guard let after, after.stderr.isEmpty, !after.stdout.isEmpty else {
                throw ServiceError.input("Real Time Response took kill \(pid) on \(target.host.named) (request \(killed.request)), but listing the processes again failed\(unread.map { " (\($0))" } ?? ""), so whether \(process) is still running is unverified. It is not reported done.\n\(Self.recovery)")
            }
            let remaining = CrowdStrike.processLines(after.stdout, pid: pid)
            if remaining.contains(where: { CrowdStrike.names($0, process) }) {
                throw ServiceError.input("Real Time Response took kill \(pid) on \(target.host.named) (request \(killed.request)), but ps afterwards still lists \(process) with that PID, so it is not done: \(remaining[0].prefix(300))")
            }
            let lines = ["Real Time Response accepted kill \(pid) for \(process) on \(target.host.named) (request \(killed.request)). Listed again afterwards, the process with that PID and name is no longer listed\(remaining.isEmpty ? "" : "; another process now has that PID"). That is what ps showed, not proof that this request ended it.",
                         killed.stdout.isEmpty ? nil : "kill said: \(killed.stdout.prefix(300))",
                         Self.recovery, "The session Pion opened, \(session.id), is closed after this."].compactMap { $0 }
            struct Kept: Encodable { let host: String; let pid: Int; let process: String; let noLongerListed: Bool; let request: String; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(host: target.host.id, pid: pid, process: process, noLongerListed: true, request: killed.request, recovery: Self.recovery))
        }
    }
}

// MARK: - Alerts

extension CrowdStrike {
    /// Sets alerts' status after reading every one of them, then reads them again and says done only for those Falcon
    /// then gives with the status asked for.
    static func setStatus(_ given: [String], to status: String, comment: String?, recovery: String, on service: ServiceClient) async throws -> ServiceResult {
        let ids = try ServiceInput.list(given, limit: 50) { value in
            guard let id = compositeID(value) else { throw ServiceError.input("Nothing was changed: give each alert's composite ID exactly as alerts lists it.") }
            return id
        }
        guard Set(ids).count == ids.count else { throw ServiceError.input("Nothing was changed: give each alert once.") }
        let (found, missing) = try await alertDetails(ids, service)
        guard missing.isEmpty else { throw ServiceError.input("Nothing was changed: Falcon did not return \(missing.joined(separator: ", ")), so not every alert could be read first.") }
        let already = found.filter { $0.status?.lowercased() == status }
        guard already.isEmpty else {
            throw ServiceError.input("Nothing was changed: \(already.map(\.composite_id).joined(separator: ", ")) \(already.count == 1 ? "is" : "are") already \(status); give only alerts to change.")
        }
        struct Parameter: Encodable { let name: String; let value: String }
        struct Body: Encodable { let composite_ids: [String]; let action_parameters: [Parameter] }
        let parameters = [Parameter(name: "update_status", value: status)] + (comment.map { [Parameter(name: "append_comment", value: $0)] } ?? [])
        let answer: Envelope<CellValue> = try await read(alertsWriteNeed) {
            try decode(try await exchange(service, ["alerts", "entities", "alerts", "v3"], method: "PATCH",
                                          body: try JSONEncoder().encode(Body(composite_ids: ids, action_parameters: parameters))).data)
        }
        let trace = answer.meta?.trace_id
        await pause(pauses.first ?? 0)
        let after: [Alert]
        do { after = try await alertDetails(ids, service).found } catch {
            throw ServiceError.input("Falcon took the request to set \(plural(ids.count, "alert")) \(status), but reading them again failed (\(error.localizedDescription)), so it could not be verified.\(traced(trace))\n\(recovery)")
        }
        let done = after.filter { $0.status?.lowercased() == status }.map(\.composite_id)
        let notDone = ids.filter { !done.contains($0) }
        guard notDone.isEmpty else {
            throw ServiceError.input("Falcon took the request to set \(plural(ids.count, "alert")) \(status), but \(notDone.joined(separator: ", ")) \(notDone.count == 1 ? "is" : "are") not \(status) when read again, so \(notDone.count == 1 ? "it is" : "they are") not reported done\(done.isEmpty ? "" : "; \(done.joined(separator: ", ")) \(done.count == 1 ? "is" : "are")").\(answer.problems.map { " Falcon said: \($0)." } ?? "")\(traced(trace))\n\(recovery)")
        }
        let lines = ["Set \(plural(done.count, "alert")) \(status), as Falcon now gives \(done.count == 1 ? "it" : "them"): \(done.joined(separator: ", ")).", recovery]
        struct Kept: Encodable { let alerts: [String]; let status: String; let done: Bool; let recovery: String; let trace: String? }
        return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(alerts: done, status: status, done: true, recovery: recovery, trace: trace))
    }

    struct CloseAlert: ServiceOperation {
        struct Input: Decodable, Sendable { let ids: [String]; let comment: String }
        static let name = "close-alert"
        static let recovery = "Recovery: update-alert-status reopened puts each back in the open queue. Until then closing hides it from the open alerts analysts and the alert watch look at, so close only what the champion judged handled or false."
        static let summary = "Close alerts, with a comment Falcon records, which hides them from the open queue. \(recovery)"
        static let input = JSONSchema.object([
            "ids": .array(.string("An alert's composite ID."), "The alerts' composite IDs, as alerts lists them, at most 50."),
            "comment": CrowdStrike.commentField,
        ], required: ["ids", "comment"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await CrowdStrike.setStatus(input.ids, to: "closed", comment: try CrowdStrike.comment(input.comment), recovery: Self.recovery, on: service)
        }
    }

    struct UpdateAlertStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let ids: [String]; let status: String; let comment: String? }
        static let name = "update-alert-status"
        static let summary = "Set alerts in progress or reopen them, with an optional comment Falcon records. It hides nothing, so it is not held; close-alert closes them."
        static let input = JSONSchema.object([
            "ids": .array(.string("An alert's composite ID."), "The alerts' composite IDs, as alerts lists them, at most 50."),
            "status": .string("The status to set.", oneOf: ["in_progress", "reopened"]),
            "comment": .string("Why, recorded with the alerts."),
        ], required: ["ids", "status"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let status = try ServiceInput.oneOf(input.status, ["in_progress", "reopened"], "status")
            let comment = try input.comment.map { try CrowdStrike.comment($0).replacingOccurrences(of: " after the champion's approval", with: "") }
            return try await CrowdStrike.setStatus(input.ids, to: status, comment: comment, recovery: "Recovery: update-alert-status again sets another status; close-alert closes them.", on: service)
        }
    }
}

// MARK: - Access

extension CrowdStrike {
    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let summary = "Tries what the actions read first, hosts, alerts and custom indicators, and whether a read shows the API client holds Real Time Response's write scope, which kill needs, and not its admin scope, which Containment must not have; says what to add for what does not work. It sends only reads, so the other write scopes are not verified."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let cloud = try CrowdStrike.cloud(service)
            var lines = ["· Falcon cloud \(cloud.title), \(cloud.host), whose console is \(cloud.console)."]
            let reads: [(Need, [String], [String: String?])] = [
                (CrowdStrike.hostsNeed, ["devices", "queries", "devices", "v1"], ["limit": "1"]),
                (CrowdStrike.alertsNeed, ["alerts", "queries", "alerts", "v2"], ["limit": "1"]),
                (CrowdStrike.iocReadNeed, ["iocs", "queries", "indicators", "v1"], ["limit": "1"]),
            ]
            for (need, path, query) in reads {
                do {
                    _ = try await CrowdStrike.get(service, path, query: query, as: CellValue.self).items()
                    lines.append("✓ \(need.title) (\(need.scope.plain))")
                } catch { lines.append("✗ \(need.title): " + (CrowdStrike.fix(for: error, need) ?? error.localizedDescription)) }
            }
            lines.append("· Real time response: Read is tried only by opening a session, which Pion does only for an action; a refused session says it is missing.")
            for probe in CrowdStrike.writeReads where CrowdStrike.containmentScopes.contains(probe.scope) {
                switch await CrowdStrike.holds(probe, service) {
                case .yes: lines.append("✓ \(probe.scope.plain)")
                case .no: lines.append("✗ \(probe.scope.plain): the API client lacks it, so rtr-kill-process is refused. Add it in Support and resources › API clients and keys.")
                case .rejected: lines.append("✗ \(probe.scope.plain): Falcon did not accept the API client's ID and secret.")
                case .unknown(let why): lines.append("? \(probe.scope.plain) could not be told (\(why)).")
                }
            }
            lines += await CrowdStrike.unwanted(CrowdStrike.writeReads.filter { !CrowdStrike.containmentScopes.contains($0.scope) }, tool: "Containment", service)
            lines.append(CrowdStrike.notVerified(CrowdStrike.unverifiableWrites) + " An action refused for want of one says which; Containment needs Hosts, Alerts and IOC Management's, and must not hold Host groups'.")
            lines.append("· Real Time Response's kill runs only on hosts whose response policy allows Real Time Response; a host whose policy does not refuses it, and the result says so.")
            lines.append("· Pion Falcon Containment's client should hold only \(CrowdStrike.containmentScopes.map(\.plain).joined(separator: ", ")): check it in Support and resources › API clients and keys.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
