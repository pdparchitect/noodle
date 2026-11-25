import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Defender XDR Containment: responding on one tenant's devices through the Defender for Endpoint API, signed
/// in through an app registration of its own as an admin of its own with only the Defender roles its actions take, kept
/// apart from Detection's so the detection sign-in stays read-only. Every action that changes a device, or uses it to gather or
/// scan, waits for the champion's approval, and each says how it is recovered.
///
/// Defender for Endpoint takes a request as a machine action, which the device carries out when it next checks in, so
/// an accepted request is not a done one: each action reports the machine action's ID and the status it reached after a
/// short wait, Pending included, and action-status reads it again. The API takes no condition on an action, so what
/// Pion read before acting may have changed by the time it acts; each result says when it read the device.
extension Defender {
    public static let containment = ToolDefinition(
        id: "0165d689-b9c0-4773-b78d-15d36863e301", name: "Microsoft Defender XDR Containment",
        summary: "Isolate a device or release it, restrict which apps run on it or lift that, stop and quarantine a file, run an antivirus scan and collect an investigation package, through Defender for Endpoint.",
        defaultInstructions: """
        Use Microsoft Defender XDR Containment to respond on a device Defender for Endpoint manages. Find the device with \
        Microsoft Defender XDR Detection first, by devices, device or an alert's evidence, which give its 40-character Defender \
        for Endpoint ID, then read it here with device: whether it is onboarded and active, its pending machine actions, \
        and the last observed isolation and app-restriction actions, which are what Defender last recorded, not the \
        device's state verified; when device says they could not be confirmed, say so in the approval reason. Record it \
        as evidence before acting. \
        isolate-device cuts the device off the network but keeps it connected to Defender (Full, or Selective, which also \
        keeps Outlook, Teams and Skype for Business); isolation can take minutes to apply, and it lasts until \
        release-isolation is asked for, explicitly. restrict-app-execution lets only Microsoft-signed apps run until \
        remove-app-restriction. stop-and-quarantine-file stops a file's processes, by its SHA1, and quarantines it on the \
        device. run-av-scan runs a Microsoft Defender Antivirus scan, and collect-investigation-package gathers forensic \
        data, both changing nothing on the device but using its resources. All seven are held for the champion's \
        approval: give the exact device, and in --approval-reason why, the expected effect and how to undo it, with the \
        Investigation as --approval-conversation; give the same reason as the comment, which Defender records with the \
        action. Pion refuses a device ID that is malformed, a device it cannot find, one that is not onboarded or not \
        active, an action of the same kind or its opposite already pending, and pending actions it could not all read. \
        Defender takes each request as a machine action, which \
        the device carries out when it next checks in: each result gives the machine action's ID and its status, and \
        Pending is not done, so poll with action-status until it is Succeeded, Failed, TimeOut or Cancelled; an answer \
        Pion could not verify as the action asked for, on that device, is never reported done. \
        machine-actions lists the actions taken on devices, by anyone, with who asked and why. Run check-access when \
        something is refused, and tell the champion exactly what it says to add.
        """,
        iconName: "defender",
        configuration: .connection(.init(endpointTemplate: "https://api.security.microsoft.com", fields: Entra.fields,
                                         oauth: Entra.oauth(scopes: containmentScopes), oauthClientField: "clientID", oauthPathField: "tenant",
                                         oauthPathExcludes: Entra.generic, adapter: "defender-containment")),
        setup: containmentSetup)

    /// The Defender for Endpoint API's resource, which its tokens must be for, whatever host the requests go to.
    static let endpointResource = "https://api.securitycenter.microsoft.com"
    /// The delegated permissions its operations take, each the narrowest the API has: reading devices and their machine
    /// actions, which the API allows only with Machine.ReadWrite, then one for each kind of action. No live response.
    static let containmentPermissions = ["Machine.ReadWrite", "Machine.Isolate", "Machine.RestrictExecution", "Machine.StopAndQuarantine", "Machine.Scan",
                                         "Machine.CollectForensics"]
    static let containmentScopes = containmentPermissions.map { endpointResource + "/" + $0 }
    static let endpointAPI = "Microsoft Defender for Endpoint"

    static let containmentSetup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it Pion Defender Containment, kept for this tool alone, and keep **Single tenant**. Under **Redirect URI**, choose **Public client/native (mobile & desktop)** and give \(Entra.redirects). Add no client secret or certificate: Pion keeps none and signs in with PKCE.",
        "Under **API permissions**, choose **Add a permission › APIs my organization uses**, search for **WindowsDefenderATP**, choose **Delegated permissions** and add exactly \(containmentPermissions.map { "`\($0)`" }.joined(separator: ", ")); remove Microsoft Graph's `User.Read`, which a new app is given. Choose **Grant admin consent**. Pion asks for these, as `\(endpointResource)/…`, and `offline_access`, and refuses a sign-in that lacks any. `Machine.ReadWrite` is the only permission that reads one device and its machine actions; it could also change a device's tags, which Pion never does.",
        "Under **Enterprise applications**, open the app: in **Properties**, set **Assignment required?** to **Yes**, and under **Users and groups** assign only the admin who will sign in.",
        "Microsoft allows an action only when both the app's permissions and the signed-in admin's Defender role allow it, for that device's group. Keep an admin for Pion Defender Containment alone, such as pion-defender-containment@contoso.com, apart from Pion Defender Detection's.",
        "In the [Microsoft Defender portal](https://security.microsoft.com), under **System › Permissions**, give that admin a role with only: in Microsoft Defender XDR's unified roles, **Security data basics (read)**, **Response (manage)** and, for collect-investigation-package, **Alerts (manage)**; or in Defender for Endpoint's roles, **View data**, **Active remediation actions** and **Alerts investigation**. Assign it only the device groups agents may act on. Never make the admin a Global or Security Administrator.",
        "Actions need Microsoft Defender for Endpoint Plan 2, or Microsoft 365 E5. Give the **Directory (tenant) ID** and the app's **Application (client) ID**. Choose **Add & Connect** and sign in as that admin. Then ask an agent to run check-access.",
    ]

    public static let containmentAdapter = OperationAdapter(operations: operations, job: .containment, simultaneousRequests: 2)

    // MARK: What it needs

    static let devicesNeed = Need(title: "Devices", scope: "Machine.ReadWrite", role: "View data, or Security data basics (read), over the device's group",
                                  licence: "Microsoft Defender for Endpoint", api: endpointAPI)
    static let actionsNeed = Need(title: "Machine actions", scope: "Machine.ReadWrite", role: "View data, or Security data basics (read)",
                                  licence: "Microsoft Defender for Endpoint", api: endpointAPI)

    /// How long to wait between reads of a machine action just asked for, before saying where it stands.
    @TaskLocal static var pauses: [Double] = [2, 3, 5]

    // MARK: The actions

    enum Act: String, CaseIterable, Sendable {
        case isolate = "Isolate", release = "Unisolate", restrict = "RestrictCodeExecution", unrestrict = "UnrestrictCodeExecution"
        case quarantine = "StopAndQuarantineFile", scan = "RunAntiVirusScan", collect = "CollectInvestigationPackage"

        /// The path the API takes it at, below the device.
        var endpoint: String {
            switch self {
            case .isolate: "isolate"
            case .release: "unisolate"
            case .restrict: "restrictCodeExecution"
            case .unrestrict: "unrestrictCodeExecution"
            case .quarantine: "StopAndQuarantineFile"
            case .scan: "runAntiVirusScan"
            case .collect: "collectInvestigationPackage"
            }
        }

        var described: String {
            switch self {
            case .isolate: "isolate"
            case .release: "release from isolation"
            case .restrict: "restrict app execution on"
            case .unrestrict: "remove the app restriction from"
            case .quarantine: "stop and quarantine a file on"
            case .scan: "run an antivirus scan on"
            case .collect: "collect an investigation package from"
            }
        }

        var need: Need {
            let permission: String = switch self {
            case .isolate, .release: "Machine.Isolate"
            case .restrict, .unrestrict: "Machine.RestrictExecution"
            case .quarantine: "Machine.StopAndQuarantine"
            case .scan: "Machine.Scan"
            case .collect: "Machine.CollectForensics"
            }
            let role = self == .collect ? "Alerts investigation, or Alerts (manage) in Defender's unified roles," : "Active remediation actions, or Response (manage) in Defender's unified roles,"
            return Need(title: "The \(rawValue) action", scope: permission, role: "\(role) over the device's group", licence: "Microsoft Defender for Endpoint Plan 2", api: Defender.endpointAPI)
        }

        /// The action that undoes it, which must not be pending while it is asked for.
        var opposite: Act? {
            switch self {
            case .isolate: .release
            case .release: .isolate
            case .restrict: .unrestrict
            case .unrestrict: .restrict
            default: nil
            }
        }
    }

    static let pendingStatuses: Set<String> = ["pending", "inprogress"]
    static let finalStatuses: Set<String> = ["succeeded", "failed", "timeout", "cancelled"]

    // MARK: What it reads

    struct Machine: Decodable, Sendable {
        enum Keys: String, CodingKey {
            case id, computerDnsName, healthStatus, onboardingStatus, onboardingstatus, osPlatform, lastSeen, lastIpAddress, lastExternalIpAddress
            case riskScore, exposureLevel, rbacGroupName, machineTags, aadDeviceId
        }
        let id: String, name: String?, health: String?, onboarding: String?, platform: String?, lastSeen: String?, ip: String?, externalIP: String?
        let risk: String?, exposure: String?, group: String?, tags: [String]?, entraDevice: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            id = try container.decode(String.self, forKey: .id)
            func text(_ key: Keys) -> String? { ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
            name = text(.computerDnsName); health = text(.healthStatus); onboarding = text(.onboardingStatus) ?? text(.onboardingstatus)
            platform = text(.osPlatform); lastSeen = text(.lastSeen); ip = text(.lastIpAddress); externalIP = text(.lastExternalIpAddress)
            risk = text(.riskScore); exposure = text(.exposureLevel); group = text(.rbacGroupName); entraDevice = text(.aadDeviceId)
            tags = (try? container.decodeIfPresent([String].self, forKey: .machineTags)) ?? nil
        }

        var named: String { "\(name ?? "an unnamed device") [\(id)]" }
        var line: String {
            "\(named): \(platform ?? "platform unknown"), onboarding \(onboarding ?? "unknown"), health \(health ?? "unknown"), risk \(risk ?? "unknown"), exposure \(exposure ?? "unknown")\(group.map { ", device group \($0)" } ?? ""), last seen \(lastSeen ?? "unknown")\(ip.map { " at \($0)" } ?? "")\(externalIP.map { " (\($0) outside)" } ?? "")."
        }
    }

    struct MachineAction: Decodable, Sendable {
        enum Keys: String, CodingKey {
            case id, type, scope, requestor, requestorComment, status, machineId, computerDnsName, creationDateTimeUtc, lastUpdateDateTimeUtc, lastUpdateTimeUtc
            case relatedFileInfo, cancellationRequestor
        }
        struct File: Decodable { let fileIdentifier: String?; let fileIdentifierType: String? }
        let id: String, type: String?, scope: String?, requestor: String?, comment: String?, status: String?, machineId: String?, device: String?
        let created: String?, updated: String?, file: String?, cancelledBy: String?
        /// The file it names, as Defender gives it: its identifier and that identifier's kind, such as Sha1.
        let fileIdentifier: String?, fileIdentifierType: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            id = try container.decode(String.self, forKey: .id)
            func text(_ key: Keys) -> String? { ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
            type = text(.type); scope = text(.scope); requestor = text(.requestor); comment = text(.requestorComment); status = text(.status)
            machineId = text(.machineId)?.lowercased(); device = text(.computerDnsName); created = text(.creationDateTimeUtc)
            updated = text(.lastUpdateDateTimeUtc) ?? text(.lastUpdateTimeUtc); cancelledBy = text(.cancellationRequestor)
            let file = (try? container.decodeIfPresent(File.self, forKey: .relatedFileInfo)) ?? nil
            self.file = file?.fileIdentifier.map { "\(file?.fileIdentifierType ?? "file") \($0)" }
            fileIdentifier = file?.fileIdentifier; fileIdentifierType = file?.fileIdentifierType
        }

        var isPending: Bool { Defender.pendingStatuses.contains(status?.lowercased() ?? "") }
        func matches(_ act: Act) -> Bool { type?.lowercased() == act.rawValue.lowercased() }
        var date: Date { ServiceAlert.time(created) ?? .distantPast }
        var line: String {
            "\(created ?? "?") \(type ?? "unknown type")\(scope.map { " (\($0))" } ?? "") of \(device ?? machineId ?? "?"): \(status ?? "status unknown"), requested by \(requestor ?? "unknown")\(file.map { ", \($0)" } ?? "")\(comment.map { ": \"\(String($0.prefix(200)))\"" } ?? "") [\(id)]"
        }

        /// Where it stands, said plainly: Pending and InProgress are not done.
        var standing: String {
            switch status?.lowercased() {
            case "succeeded": "Succeeded: done"
            case "pending": "Pending: the device has not carried it out yet, so it is not done"
            case "inprogress": "InProgress: under way, not done yet"
            case "failed": "Failed: not done"
            case "timeout": "TimeOut: the device never confirmed it, so it is not done"
            case "cancelled": "Cancelled\(cancelledBy.map { " by \($0)" } ?? ""): not done"
            case let other?: "\(other): not known to be done"
            case nil: "no status given: not known to be done"
            }
        }
    }

    static func machineActionID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Entra.isGUID(value) ? value.lowercased() : nil
    }

    /// A device's machine actions that match `filter` besides its own ID, every page or the read fails, and checked
    /// here too, so a filter the API ignored never lets another device's action through. A listing can still come back
    /// unfinished, at its page limit or at a next page Pion will not follow: callers check `complete`.
    static func actions(of device: String, _ filter: String?, _ service: ServiceClient, matching: @escaping (MachineAction) -> Bool = { _ in true }) async throws -> Listing<MachineAction> {
        try await read(actionsNeed) {
            try await list(service, ["api", "machineactions"], query: ["$filter": "machineId eq '\(device)'" + (filter.map { " and \($0)" } ?? ""), "$top": "200"],
                           as: MachineAction.self, api: endpointAPI, pages: 5, partial: false) { $0.machineId == device && matching($0) }
        }
    }

    /// Why an unfinished listing stopped, in a few words.
    static func unfinished(_ listing: Listing<MachineAction>) -> String {
        listing.stopped ?? "there were more than the \(listing.pages) pages Pion reads at once"
    }

    /// The last isolation or app-restriction action a device's succeeded machine actions record, which is what was last
    /// observed, not the device's state verified: Defender for Endpoint's device record does not say whether a device
    /// is isolated or its apps restricted. Known only when every succeeded action was read, and one of the pair is
    /// plainly the latest; the API promises no order, so Pion orders them itself, and nothing on record, a history read
    /// in part, or two at one moment leave it unknown, with why.
    struct LastObserved: Sendable {
        let action: MachineAction?
        let unknown: String?
    }

    struct State: Sendable {
        let isolation: LastObserved
        let restriction: LastObserved
        /// Whether the last observed action isolated it, or nil when that is not known.
        var isolated: Bool? { isolation.unknown == nil ? isolation.action?.matches(.isolate) : nil }
        var restricted: Bool? { restriction.unknown == nil ? restriction.action?.matches(.restrict) : nil }

        var said: [String] {
            func line(_ observed: LastObserved, _ what: String) -> String {
                guard let action = observed.action, observed.unknown == nil else {
                    return "Whether \(what) could not be confirmed: \(observed.unknown ?? "no action on record says so")."
                }
                return "Last observed: \(action.type ?? "?")\(action.scope.map { " (\($0))" } ?? "") succeeded at \(action.updated ?? action.created ?? "?") [\(action.id)]. Defender for Endpoint's device record does not say whether \(what), so this is the last action on record, not its state verified."
            }
            return [line(isolation, "it is isolated"), line(restriction, "its apps are restricted")]
        }

        /// What an action's result says when the state it changes could not be confirmed beforehand.
        func note(for act: Act) -> String? {
            let observed: LastObserved
            switch act {
            case .isolate, .release: observed = isolation
            case .restrict, .unrestrict: observed = restriction
            default: return nil
            }
            guard let why = observed.unknown else { return nil }
            return "Whether the device was \(act == .isolate || act == .release ? "isolated" : "restricted to Microsoft-signed apps") before this could not be confirmed: \(why)."
        }
    }

    static func state(of device: String, _ service: ServiceClient) async throws -> State {
        let succeeded = try await actions(of: device, "status eq 'Succeeded'", service) { $0.status?.lowercased() == "succeeded" }
        func last(_ acts: [Act], _ what: String) -> LastObserved {
            guard succeeded.complete else {
                return LastObserved(action: nil, unknown: "not every one of its succeeded machine actions could be read (\(unfinished(succeeded))), so which came last is not known")
            }
            let pair = succeeded.value.filter { action in acts.contains { action.matches($0) } }
            guard !pair.isEmpty else {
                return LastObserved(action: nil, unknown: "no machine action on record \(what), and Defender keeps only so much history, so that is not proof either way")
            }
            guard pair.allSatisfy({ ServiceAlert.time($0.created) != nil }) else {
                return LastObserved(action: nil, unknown: "a machine action on record gives no time it was asked for, so which came last is not known")
            }
            let ordered = pair.sorted { $0.date > $1.date }
            if ordered.count > 1, ordered[0].date == ordered[1].date, ordered[0].type?.lowercased() != ordered[1].type?.lowercased() {
                return LastObserved(action: nil, unknown: "two of its machine actions were asked for at the same moment, so which came last is not known")
            }
            return LastObserved(action: ordered[0], unknown: nil)
        }
        return State(isolation: last([.isolate, .release], "isolated or released it"), restriction: last([.restrict, .unrestrict], "restricted its apps or lifted that"))
    }

    /// The device an action is for, as read just before it.
    struct Target {
        let machine: Machine, state: State, readAt: String
    }

    /// Reads the device and refuses what an action must not go ahead on: a malformed ID, a device not found or another
    /// than asked, one not onboarded or not active, pending actions that could not all be read, an action of the same
    /// kind or its opposite pending, and isolating a device whose last observed action isolated it or releasing one
    /// whose last observed action released it. A state that could not be confirmed blocks nothing; the result says so.
    static func target(_ value: String, for act: Act, on service: ServiceClient) async throws -> Target {
        guard let id = deviceID(value) else {
            throw ServiceError.input("Nothing was changed: give the device's 40-character Defender for Endpoint ID, as Microsoft Defender XDR Detection's devices, device or alert gives it.")
        }
        let machine: Machine
        do { machine = try await read(devicesNeed) { try await get(service, ["api", "machines", id], api: endpointAPI, as: Machine.self) } }
        catch ServiceError.notFound {
            throw ServiceError.input("Nothing was changed: Defender for Endpoint has no device \(id) the containment admin can see. It may not exist, have been merged into another, or be outside the device groups their role covers.")
        }
        guard machine.id.lowercased() == id else {
            throw ServiceError.input("Nothing was changed: Defender for Endpoint answered for device \(machine.id), not \(id).")
        }
        guard machine.onboarding?.lowercased() == "onboarded" else {
            throw ServiceError.input("Nothing was changed: \(machine.named) is not onboarded to Defender for Endpoint (onboarding \(machine.onboarding ?? "not given")), so it takes no actions. Contain it another way, such as through Microsoft Defender XDR's contain device, the network or its owner.")
        }
        guard machine.health?.lowercased() == "active" else {
            throw ServiceError.input("Nothing was changed: \(machine.named) is not active (health \(machine.health ?? "not given"), last seen \(machine.lastSeen ?? "unknown")), so it would not carry the action out until it checks in, and the action may time out. Ask again once it is active, or contain it another way meanwhile.")
        }
        let pending = try await actions(of: id, "(status eq 'Pending' or status eq 'InProgress')", service) { $0.isPending }
        if let same = pending.value.first(where: { $0.matches(act) }) {
            throw ServiceError.input("Nothing was changed: a \(act.rawValue) of \(machine.named) is already \(same.status ?? "pending"): machine action \(same.id), requested by \(same.requestor ?? "unknown") at \(same.created ?? "?"). Poll it with action-status.")
        }
        if let opposite = act.opposite, let racing = pending.value.first(where: { $0.matches(opposite) }) {
            throw ServiceError.input("Nothing was changed: a \(opposite.rawValue) of \(machine.named) is \(racing.status ?? "pending") (machine action \(racing.id), requested by \(racing.requestor ?? "unknown")), and the two would race. Wait for it with action-status.")
        }
        // Only a whole read shows no conflicting action is pending.
        guard pending.complete else {
            throw ServiceError.input("Nothing was changed: not every pending machine action of \(machine.named) could be read (\(unfinished(pending))), so whether a \(act.rawValue)\(act.opposite.map { " or \($0.rawValue)" } ?? "") is already pending is not known. Ask again, or read its action center in the Microsoft Defender portal.")
        }
        let state = try await state(of: id, service)
        switch act {
        case .isolate where state.isolated == true:
            throw ServiceError.input("Nothing was changed: the last observed isolation action on \(machine.named) isolated it (\(state.isolation.action!.id)), so it is isolated unless something not on record changed that. release-isolation releases it.")
        case .release where state.isolated == false:
            throw ServiceError.input("Nothing was changed: the last observed isolation action on \(machine.named) released it (\(state.isolation.action!.id)), so there is nothing to release unless something not on record isolated it.")
        case .restrict where state.restricted == true:
            throw ServiceError.input("Nothing was changed: the last observed app-restriction action on \(machine.named) restricted its apps (\(state.restriction.action!.id)).")
        case .unrestrict where state.restricted == false:
            throw ServiceError.input("Nothing was changed: the last observed app-restriction action on \(machine.named) lifted the restriction (\(state.restriction.action!.id)), so there is nothing to remove.")
        default: break
        }
        return Target(machine: machine, state: state, readAt: Entra.iso(Date()))
    }

    /// The comment Defender records with an action: why, as the approval gave it, marked as Pion's, on one line.
    static func comment(_ value: String) throws -> String {
        let words = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (3...800).contains(words.count) else {
            throw ServiceError.input("Nothing was changed: give a comment of up to 800 characters saying why, as the approval request does; Defender for Endpoint requires one and records it with the action.")
        }
        return "Requested through Pion after the champion's approval: " + words
    }

    /// Why an answer is not shown to be the action asked for. `missing` is Defender leaving out what would show it, such
    /// as the device or the file, which a later read may give; anything else is Defender naming something else.
    struct Unverified { let reason: String; let missing: Bool }

    /// Why `action` is not shown to be the one asked for: the same ID, naming the target device and the action's type,
    /// with the scope asked for, such as Full or Quick, whenever Defender gives one, and for a file, the very SHA1 asked
    /// for, which only an explicit, equal SHA1 shows; nil when it is.
    static func unverified(_ action: MachineAction, id actionID: String, act: Act, device: String, scope: String?, sha1: String?) -> Unverified? {
        guard action.id.lowercased() == actionID else { return Unverified(reason: "Defender answered for machine action \(action.id)", missing: false) }
        guard let machine = action.machineId else { return Unverified(reason: "Defender's answer named no device", missing: true) }
        guard machine == device else { return Unverified(reason: "Defender's answer names device \(machine)", missing: false) }
        guard let type = action.type else { return Unverified(reason: "Defender's answer named no type of action", missing: true) }
        guard action.matches(act) else { return Unverified(reason: "Defender's answer is a \(type)", missing: false) }
        if let scope, let given = action.scope, given.lowercased() != scope.lowercased() {
            return Unverified(reason: "Defender's answer is \(given), not the \(scope) asked for", missing: false)
        }
        if let sha1 {
            let given = action.fileIdentifier?.trimmingCharacters(in: .whitespaces).lowercased()
            let kind = action.fileIdentifierType?.lowercased()
            guard let given, given.count == 40, given.allSatisfy(\.isHexDigit), kind == nil || kind == "sha1" else {
                return Unverified(reason: "Defender did not say which file; the outcome for \(sha1) could not be verified", missing: true)
            }
            guard given == sha1 else { return Unverified(reason: "Defender's answer names file \(given), not \(sha1)", missing: false) }
        }
        return nil
    }

    /// Asks for `act` on the target device and reads the machine action it became until it is done or the pauses run
    /// out, then says where it stands. Nothing is said done until Defender's answer names the same machine action, the
    /// target device, the action's type and the scope asked for, when it gives one: an answer that does not, or names
    /// no device, keeps the action's ID and says the outcome could not be verified. One failed, timed out or cancelled
    /// is a failure, and one still pending says so and how to follow it.
    static func act(_ act: Act, _ target: Target, body: [String: Any], scope: String? = nil, sha1: String? = nil, recovery: String, note: String? = nil,
                    on service: ServiceClient) async throws -> ServiceResult {
        let id = target.machine.id.lowercased()
        let data = try await read(act.need) {
            try await exchange(service, ["api", "machines", id, act.endpoint], method: "POST",
                               body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), api: endpointAPI).data
        }
        guard var action = try? JSONDecoder().decode(MachineAction.self, from: data), let actionID = machineActionID(action.id) else {
            throw ServiceError.input("Defender for Endpoint answered the request to \(act.described) \(target.machine.named) with something that could not be read, so whether it took it is not known. Run device to see its pending actions before asking again.")
        }
        var problem = unverified(action, id: actionID, act: act, device: id, scope: scope, sha1: sha1)
        var waited = 0.0, unread: String?
        // Read again while it is not done, and while what Defender said does not yet show it is the action asked for,
        // unless it plainly names another device, type or scope.
        for pause in pauses where problem.map(\.missing) ?? !finalStatuses.contains(action.status?.lowercased() ?? "") {
            try? await Task.sleep(nanoseconds: UInt64(max(0, pause) * 1_000_000_000))
            waited += pause
            do {
                let again = try await get(service, ["api", "machineactions", actionID], api: endpointAPI, as: MachineAction.self)
                problem = unverified(again, id: actionID, act: act, device: id, scope: scope, sha1: sha1)
                unread = nil
                if again.id.lowercased() == actionID { action = again } else { break }
            } catch {
                unread = error.localizedDescription
            }
        }
        if let problem {
            throw ServiceError.input("Defender for Endpoint took the request to \(act.described) \(target.machine.named) as machine action \(actionID), but whether it is the \(act.rawValue)\(scope.map { " (\($0))" } ?? "") of \(id) asked for could not be verified: \(problem.reason)\(unread.map { "; reading it again failed (\($0))" } ?? ""). It is not reported done. Read it with action-status \(actionID) and the device with device before going on.\n\(recovery)")
        }
        let status = action.status?.lowercased() ?? ""
        var lines = ["Asked Defender for Endpoint to \(act.described) \(target.machine.named): it took the request as machine action \(actionID), a \(action.type ?? act.rawValue)\(action.scope.map { " (\($0))" } ?? "") of that device requested by \(action.requestor ?? "the signed-in admin"). After \(Int(waited)) seconds it is \(action.standing)."]
        if let unread { lines.append("Its status could not be read again (\(unread)), so it may have moved on.") }
        if !finalStatuses.contains(status) { lines.append("Pending is not Succeeded: poll it with action-status \(actionID) until it is Succeeded, Failed, TimeOut or Cancelled.") }
        if let before = target.state.note(for: act) { lines.append(before) }
        if let note { lines.append(note) }
        lines.append(recovery)
        lines.append("\(target.machine.named) was read at \(target.readAt). Defender for Endpoint takes no condition on an action, so another admin may have acted on it between that read and this request.")
        if ["failed", "timeout", "cancelled"].contains(status) { throw ServiceError.input(lines.joined(separator: "\n")) }
        struct Kept: Encodable { let device: String; let name: String?; let action: String; let type: String; let status: String?; let done: Bool; let recovery: String; let readAt: String }
        return try ServiceResult(text: lines.joined(separator: "\n"),
                                 structured: Kept(device: id, name: target.machine.name, action: actionID, type: act.rawValue, status: action.status,
                                                  done: status == "succeeded", recovery: recovery, readAt: target.readAt))
    }

    static let deviceField = JSONSchema.string("The device's 40-character Defender for Endpoint ID, as Microsoft Defender XDR Detection's devices, device or alert gives it.")
    static let commentField = JSONSchema.string("Why, for Defender for Endpoint's record of the action: the reason given in the approval request, with the Investigation.")

    struct ActInput: Decodable, Sendable { let device: String; let comment: String }
    static let actSchema = JSONSchema.object(["device": deviceField, "comment": commentField], required: ["device", "comment"])
}

// MARK: - Reading

extension Defender {
    struct ContainmentDevice: ServiceOperation {
        struct Input: Decodable, Sendable { let device: String }
        static let name = "device"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "A device's state before acting: whether it is onboarded and active, its risk, exposure and device group, its pending machine actions, saying when not all could be read, and the last observed isolation and app-restriction actions, or that they could not be confirmed. It changes nothing."
        static let input = JSONSchema.object(["device": Defender.deviceField], required: ["device"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard let id = Defender.deviceID(input.device) else { throw ServiceError.input("Give the device's 40-character Defender for Endpoint ID.") }
            let machine: Machine
            do { machine = try await Defender.read(Defender.devicesNeed) { try await Defender.get(service, ["api", "machines", id], api: Defender.endpointAPI, as: Machine.self) } }
            catch ServiceError.notFound { throw ServiceError.input("Defender for Endpoint has no device \(id) the containment admin can see: it may not exist, have been merged into another, or be outside the device groups their role covers.") }
            guard machine.id.lowercased() == id else { throw ServiceError.input("Defender for Endpoint answered for device \(machine.id), not \(id), so nothing it said is shown.") }
            var lines = [machine.line]
            if let tags = machine.tags, !tags.isEmpty { lines.append("Tags: \(tags.joined(separator: ", ")).") }
            let actionable = machine.onboarding?.lowercased() == "onboarded" && machine.health?.lowercased() == "active"
            lines.append(actionable ? "Onboarded and active: it can take actions." : "Not onboarded and active, so Pion refuses to act on it.")
            var gaps: [String] = []
            var pending: [MachineAction] = []
            var pendingComplete = false
            do {
                let listing = try await Defender.actions(of: id, "(status eq 'Pending' or status eq 'InProgress')", service) { $0.isPending }
                pending = listing.value.sorted { $0.date > $1.date }
                pendingComplete = listing.complete
                if listing.complete {
                    lines.append(pending.isEmpty ? "No machine action of it is pending." : "Pending machine actions:\n" + pending.map(\.line).joined(separator: "\n"))
                } else {
                    lines.append((pending.isEmpty ? "No pending machine action in what was read" : "Pending machine actions, in what was read:\n" + pending.map(\.line).joined(separator: "\n"))
                                 + "\nNot every pending machine action could be read (\(Defender.unfinished(listing))), so others may be pending, and Pion refuses to act on it until they can all be read.")
                }
            } catch { gaps.append("its pending machine actions (\(error.localizedDescription))") }
            var state: State?
            do {
                state = try await Defender.state(of: id, service)
                lines += state!.said
            } catch { gaps.append("whether it is isolated or its apps restricted (\(error.localizedDescription))") }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")); check-access says what the admin or app lacks.") }
            lines.append("Read at \(Entra.iso(Date())).")
            struct Kept: Encodable {
                let device: String; let name: String?; let onboarding: String?; let health: String?; let actionable: Bool; let pending: [String]; let pendingComplete: Bool
                /// What the last observed action did, not the device's state verified; nil when not known.
                let lastObservedIsolated: Bool?; let lastObservedRestricted: Bool?; let couldNotRead: [String]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(device: id, name: machine.name, onboarding: machine.onboarding, health: machine.health, actionable: actionable,
                                                      pending: pending.map(\.id), pendingComplete: pendingComplete, lastObservedIsolated: state?.isolated,
                                                      lastObservedRestricted: state?.restricted, couldNotRead: gaps))
        }
    }

    struct MachineActions: ServiceOperation {
        struct Input: Decodable, Sendable { let device: String?, type: String?, status: String?, since: String?, limit: Int? }
        static let name = "machine-actions"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Machine actions taken on devices, by anyone, newest first, by device, type, status and time, with who asked, why and where each stands, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "device": Defender.deviceField,
            "type": .string("The kind of action.", oneOf: Act.allCases.map(\.rawValue) + ["LiveResponse", "Offboard"]),
            "status": .string("Where it stands.", oneOf: ["Pending", "InProgress", "Succeeded", "Failed", "TimeOut", "Cancelled"]),
            "since": .string("The earliest time it was asked for, in ISO 8601. The last 7 days when left out, at most 180 days."),
            "limit": .integer("How many, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            var device: String?
            if let given = input.device {
                guard let id = Defender.deviceID(given) else { throw ServiceError.input("Give the device's 40-character Defender for Endpoint ID.") }
                device = id
                filter.append("machineId eq '\(id)'")
            }
            if let type = input.type { filter.append("type eq '\(try ServiceInput.oneOf(type, Act.allCases.map(\.rawValue) + ["LiveResponse", "Offboard"], "type"))'") }
            if let status = input.status { filter.append("status eq '\(try ServiceInput.oneOf(status, ["Pending", "InProgress", "Succeeded", "Failed", "TimeOut", "Cancelled"], "status"))'") }
            let (since, _) = try Defender.window(input.since, nil, days: 7)
            filter.append("creationDateTimeUtc ge \(Entra.iso(since))")
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500.") }
            let listing = try await Defender.read(Defender.actionsNeed) {
                try await Defender.list(service, ["api", "machineactions"], query: ["$filter": filter.joined(separator: " and "), "$top": String(min(limit + 1, 200))],
                                        as: MachineAction.self, api: Defender.endpointAPI, pages: 5, limit: limit + 1) { action in
                    device.map { action.machineId == $0 } ?? true
                }
            }
            let actions = listing.value.sorted { $0.date > $1.date }.prefix(limit)
            var text = actions.isEmpty ? "No machine actions asked for since \(Entra.iso(since)) match\(listing.complete ? "" : " in what was read")."
                : "\(Defender.plural(actions.count, "machine action")) since \(Entra.iso(since)), newest first:\n" + actions.prefix(40).map(\.line).joined(separator: "\n")
            if actions.count > 40 { text += "\n\(actions.count - 40) more in the structured result." }
            let more = listing.value.count > limit
            text += more ? "\nMore match than the \(limit) kept, which are the newest of those Defender listed first: narrow by device, type, status or time." : Defender.stopped(listing, "machine actions")
            struct Kept: Encodable { let id: String; let type: String?; let status: String?; let device: String?; let requestor: String?; let comment: String?; let created: String? }
            struct All: Encodable { let actions: [Kept]; let complete: Bool }
            return try ServiceResult(text: text, structured: All(actions: actions.map { Kept(id: $0.id, type: $0.type, status: $0.status, device: $0.machineId, requestor: $0.requestor, comment: $0.comment, created: $0.created) },
                                                                 complete: listing.complete && !more))
        }
    }

    struct ActionStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "action-status"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Where one machine action stands, by its ID: Pending and InProgress are not done; Succeeded is. It changes nothing."
        static let input = JSONSchema.object(["id": .string("The machine action's ID, a GUID, as an action or machine-actions gave it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard let id = Defender.machineActionID(input.id) else { throw ServiceError.input("Give the machine action's ID, a GUID such as 4f1c2e3d-0000-4000-8000-000000000001.") }
            let action: MachineAction
            do { action = try await Defender.read(Defender.actionsNeed) { try await Defender.get(service, ["api", "machineactions", id], api: Defender.endpointAPI, as: MachineAction.self) } }
            catch ServiceError.notFound { throw ServiceError.input("Defender for Endpoint has no machine action \(id) the containment admin can see.") }
            guard action.id.lowercased() == id else { throw ServiceError.input("Defender for Endpoint answered for machine action \(action.id), not \(id), so nothing it said is shown.") }
            let text = action.line + "\nIt is \(action.standing). Last updated \(action.updated ?? "unknown")."
            struct Kept: Encodable { let id: String; let type: String?; let status: String?; let done: Bool; let device: String?; let requestor: String?; let comment: String? }
            return try ServiceResult(text: text, structured: Kept(id: id, type: action.type, status: action.status, done: action.status?.lowercased() == "succeeded",
                                                                  device: action.machineId, requestor: action.requestor, comment: action.comment))
        }
    }

    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Tries what the actions read first, devices and machine actions, and says what works and, for what does not, what to change: the app's permissions, the admin's Defender role or what the tenant lacks; and what each action needs, which only asking for it tests. It changes nothing."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ Reading \(need.title.lowercased())" }
                catch { return "✗ Reading \(need.title.lowercased()): " + (Defender.fix(for: error, need) ?? error.localizedDescription) }
            }
            var lines: [String] = []
            do { lines.append("· Tenant \(try Entra.tenant(service)), signed in through the Defender for Endpoint API, \(Defender.endpointResource).") }
            catch { lines.append("✗ \(error.localizedDescription)") }
            lines.append(await check(Defender.devicesNeed) {
                _ = try await Defender.get(service, ["api", "machines"], query: ["$top": "1"], api: Defender.endpointAPI, as: Page<Entra.IgnoredItem>.self)
            })
            lines.append(await check(Defender.actionsNeed) {
                _ = try await Defender.get(service, ["api", "machineactions"], query: ["$top": "1"], api: Defender.endpointAPI, as: Page<Entra.IgnoredItem>.self)
            })
            lines.append("· The actions are not tried, as trying one takes it. Each needs its delegated permission, which Pion refused to sign in without, and a Defender role over the device's group: isolate-device, release-isolation, restrict-app-execution, remove-app-restriction, stop-and-quarantine-file and run-av-scan need Active remediation actions, or Response (manage) in Defender's unified roles; collect-investigation-package needs Alerts investigation, or Alerts (manage). A refused action says which.")
            lines.append("· Defender for Endpoint lists only the devices the admin's role covers, so a device outside its groups is not found, and cannot be acted on.")
            lines.append("· Permissions asked for at sign-in: \((Defender.containmentPermissions + ["offline_access"]).joined(separator: ", ")).")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}

// MARK: - Actions

extension Defender {
    static let isolationNote = "Isolation can take minutes to apply, once the device checks in, and it lasts until release-isolation is asked for: it never ends by itself."

    struct IsolateDevice: ServiceOperation {
        struct Input: Decodable, Sendable { let device: String; let comment: String; let isolationType: String? }
        static let name = "isolate-device"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: release-isolation restores the device's network access, and must be asked for explicitly; until then the device reaches only Defender for Endpoint (and, with Selective, Outlook, Teams and Skype for Business), so its user cannot work on it."
        static let summary = "Isolate a device from the network, Full or Selective, keeping it connected to Defender for Endpoint. It can take minutes to apply. \(recovery)"
        static let input = JSONSchema.object(["device": Defender.deviceField, "comment": Defender.commentField,
                                              "isolationType": .string("Full, the default, or Selective, which keeps Outlook, Teams and Skype for Business.", oneOf: ["Full", "Selective"])],
                                             required: ["device", "comment"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let kind = try ServiceInput.oneOf(input.isolationType ?? "Full", ["Full", "Selective"], "isolationType")
            let comment = try Defender.comment(input.comment)
            let target = try await Defender.target(input.device, for: .isolate, on: service)
            return try await Defender.act(.isolate, target, body: ["Comment": comment, "IsolationType": kind], scope: kind, recovery: Self.recovery,
                                          note: "\(kind) isolation. \(Defender.isolationNote)", on: service)
        }
    }

    struct ReleaseIsolation: ServiceOperation {
        typealias Input = ActInput
        static let name = "release-isolation"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: isolate-device again. Releasing restores the device's full network access, an attacker's still on it included, so release it only once the champion judges it clean."
        static let summary = "Release an isolated device, restoring its network access. Held like the rest, as it gives access back. It can take minutes to apply. \(recovery)"
        static let input = Defender.actSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: ActInput, on service: ServiceClient) async throws -> ServiceResult {
            let comment = try Defender.comment(input.comment)
            let target = try await Defender.target(input.device, for: .release, on: service)
            return try await Defender.act(.release, target, body: ["Comment": comment], recovery: Self.recovery,
                                          note: "Release, too, can take minutes to apply, once the device checks in.", on: service)
        }
    }

    struct RestrictAppExecution: ServiceOperation {
        typealias Input = ActInput
        static let name = "restrict-app-execution"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: remove-app-restriction lets every app run again. Until then only apps signed by Microsoft run on the device, which stops most of its user's work and any other app already running."
        static let summary = "Restrict a device to running only apps signed by Microsoft. \(recovery)"
        static let input = Defender.actSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: ActInput, on service: ServiceClient) async throws -> ServiceResult {
            let comment = try Defender.comment(input.comment)
            let target = try await Defender.target(input.device, for: .restrict, on: service)
            return try await Defender.act(.restrict, target, body: ["Comment": comment], recovery: Self.recovery, on: service)
        }
    }

    struct RemoveAppRestriction: ServiceOperation {
        typealias Input = ActInput
        static let name = "remove-app-restriction"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: restrict-app-execution again. Removing the restriction lets any app run again, an attacker's included."
        static let summary = "Lift a device's app restriction, letting any app run. Held like the rest, as it gives back what the restriction held off. \(recovery)"
        static let input = Defender.actSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: ActInput, on service: ServiceClient) async throws -> ServiceResult {
            let comment = try Defender.comment(input.comment)
            let target = try await Defender.target(input.device, for: .unrestrict, on: service)
            return try await Defender.act(.unrestrict, target, body: ["Comment": comment], recovery: Self.recovery, on: service)
        }
    }

    struct StopAndQuarantineFile: ServiceOperation {
        struct Input: Decodable, Sendable { let device: String; let comment: String; let sha1: String }
        static let name = "stop-and-quarantine-file"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: stopping the file's processes ends them and loses their in-memory state, which cannot be undone, so record what they were first; the quarantined file can be restored, from the file's page or the device's action center in the Microsoft Defender portal, or with MpCmdRun -Restore on the device."
        static let summary = "Stop every process of a file, by its SHA1, on one device, and quarantine the file there. \(recovery)"
        static let input = JSONSchema.object(["device": Defender.deviceField, "comment": Defender.commentField,
                                              "sha1": .string("The file's SHA1, 40 hexadecimal characters, as an alert's evidence or hunting gives it.")],
                                             required: ["device", "comment", "sha1"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let sha1 = input.sha1.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard sha1.count == 40, sha1.allSatisfy(\.isHexDigit) else { throw ServiceError.input("Nothing was changed: give the file's SHA1, 40 hexadecimal characters.") }
            let comment = try Defender.comment(input.comment)
            let target = try await Defender.target(input.device, for: .quarantine, on: service)
            return try await Defender.act(.quarantine, target, body: ["Comment": comment, "Sha1": sha1], sha1: sha1, recovery: Self.recovery,
                                          note: "The file with SHA1 \(sha1).", on: service)
        }
    }

    struct RunAVScan: ServiceOperation {
        struct Input: Decodable, Sendable { let device: String; let comment: String; let scanType: String? }
        static let name = "run-av-scan"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: nothing to undo: a scan changes nothing on the device's state itself, but uses its processor and disk while it runs, a Full scan for an hour or more; what it finds, Microsoft Defender Antivirus remediates as its policy says, which may quarantine files."
        static let summary = "Run a Microsoft Defender Antivirus scan, Quick or Full, on a device. \(recovery)"
        static let input = JSONSchema.object(["device": Defender.deviceField, "comment": Defender.commentField,
                                              "scanType": .string("Quick, the default, or Full.", oneOf: ["Quick", "Full"])], required: ["device", "comment"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let kind = try ServiceInput.oneOf(input.scanType ?? "Quick", ["Quick", "Full"], "scanType")
            let comment = try Defender.comment(input.comment)
            let target = try await Defender.target(input.device, for: .scan, on: service)
            return try await Defender.act(.scan, target, body: ["Comment": comment, "ScanType": kind], scope: kind, recovery: Self.recovery, note: "\(kind) scan.", on: service)
        }
    }

    struct CollectInvestigationPackage: ServiceOperation {
        typealias Input = ActInput
        static let name = "collect-investigation-package"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: nothing to undo: collecting changes nothing on the device's state, but uses its resources while the package is gathered and uploaded, and the package, with its processes, connections, users, logs and more, can be downloaded by anyone whose Defender role covers the device."
        static let summary = "Collect a forensic investigation package from a device, which the Defender portal then offers to download. \(recovery)"
        static let input = Defender.actSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: ActInput, on service: ServiceClient) async throws -> ServiceResult {
            let comment = try Defender.comment(input.comment)
            let target = try await Defender.target(input.device, for: .collect, on: service)
            return try await Defender.act(.collect, target, body: ["Comment": comment], recovery: Self.recovery,
                                          note: "Once it is Succeeded, download the package from the device's action center in the Microsoft Defender portal.", on: service)
        }
    }
}
