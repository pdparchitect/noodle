import Foundation
import NoodleCore
import NoodleToolConnections

/// Duo Containment: acting on one Duo account to contain an incident, with an Admin API application of its own that
/// holds only Grant resource - Read and Write, kept apart from Duo Detection's so the detection keys stay read-only.
/// Every change cuts off or restores someone's access or removes something, so each waits for the champion's approval
/// and says how it is undone.
///
/// Duo takes no condition on a change, so what Pion read before acting may have changed by the time it acts: each
/// result says when it read the user. Duo's Admin API cannot end a user's sessions in the applications Duo protects, so
/// no tool here claims to.
extension Duo {
    public static let containment = ToolDefinition(
        id: "eddc5469-1b96-4202-b241-aa0bee7b8237", name: "Duo Containment",
        summary: "Disable a Duo user or restore them, take a user out of bypass status, delete their bypass codes, remove a phone, hardware token or security key from them, and send enrollment or Duo Mobile activation.",
        defaultInstructions: """
        Use Duo Containment to contain an identity in one Duo account. Read the user first with user, which lists their \
        status, phones, hardware tokens and security keys with the IDs these tools take, groups and bypass codes \
        (counted, never shown): record it as evidence before acting. Give each user by their exact Duo username or user \
        ID (DU…). disable-user stops every Duo login for them, and enable-user restores it, for a user disabled or \
        locked out; clear-bypass takes a user out of bypass status, so Duo asks for their second factor again; \
        delete-bypass-codes deletes every bypass code they hold. remove-phone, remove-token and remove-security-key take \
        one device the attacker may hold away from the user. send-enrollment emails a user with no devices left a new \
        enrollment link, and send-activation texts a phone a new Duo Mobile activation link: send them only once the \
        user's mailbox or phone is known to be theirs, as whoever holds it enrolls. Duo cannot end sessions the \
        applications it protects already hold, and it cannot disable a user a directory sync manages: end those in the \
        application or the directory. A typical containment is disable-user, then delete-bypass-codes and removing the \
        devices the attacker added, then enable-user and send-enrollment once the user is safe. Every change is held for \
        the champion's approval: give the exact user, and in --approval-reason why, the expected effect and how to undo \
        it, with the Investigation as --approval-conversation. Each result says what changed, what did not and how to \
        recover it. Run check-access when something is refused, and tell the champion exactly which permission it says \
        to tick.
        """,
        iconName: "duo",
        configuration: .connection(.init(endpointTemplate: "https://{host}", fields: fields, tokenHeader: "Authorization",
                                         composedToken: keys, adapter: "duo-containment")),
        setup: containmentSetup)

    static let containmentSetup = applicationSteps("Pion Containment", permissions: "tick only **Grant resource - Read** and **Grant resource - Write**, which read users and their devices and change them. Keep it apart from Duo Detection's application, so Detection's keys stay read-only, and leave every other permission off.") + [keysStep]

    public static let containmentAdapter = OperationAdapter(operations: operations, job: .containment, simultaneousRequests: 2)

    // MARK: Who is acted on

    /// The user an action is for, as read just before it, named exactly.
    struct Target {
        let user: User, readAt: String
        var named: String { user.named }
    }

    static func target(_ value: String, on service: ServiceClient) async throws -> Target {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = try await resolve(value, on: service)
        guard user.user_id == value || user.username?.lowercased() == value.lowercased() else {
            throw ServiceError.input("Nothing was changed: \(value) is an alias of \(user.named). Give their username or user ID, so Pion acts only on the user meant.")
        }
        return Target(user: user, readAt: iso(Date()))
    }

    /// One step of an action, as its result reports it.
    struct Step: Codable { let action: String; let done: Bool; let detail: String }

    struct Outcome: Encodable { let user: String?; let username: String?; let readAt: String?; let steps: [Step]; let recovery: String }

    /// What an action came to: each step, done or not, how to recover, and when the user was read.
    static func outcome(_ target: Target, steps: [Step], recovery: String, note: String? = nil) throws -> ServiceResult {
        if !steps.contains(where: \.done), let failed = steps.first(where: { !$0.done }) {
            throw ServiceError.input("Nothing was changed. " + failed.detail)
        }
        var lines = steps.map { ($0.done ? "✓ " : "✗ ") + $0.detail }
        if let note { lines.append(note) }
        lines.append(recovery)
        lines.append("\(target.named) was read at \(target.readAt). Duo takes no condition on a change, so another administrator may have changed them between that read and this change.")
        return try ServiceResult(text: lines.joined(separator: "\n"),
                                 structured: Outcome(user: target.user.user_id, username: target.user.username, readAt: target.readAt, steps: steps, recovery: recovery))
    }

    /// Runs changes in turn, stopping at the first that fails, and says which were made, which failed and which were not tried.
    static func inTurn(_ changes: [(action: String, describe: String, run: () async throws -> Void)]) async -> [Step] {
        var steps: [Step] = [], failed = false
        for change in changes {
            if failed { steps.append(Step(action: change.action, done: false, detail: "Not tried, after the failure above: \(change.describe).")); continue }
            do {
                try await write { try await change.run() }
                steps.append(Step(action: change.action, done: true, detail: change.describe.prefix(1).uppercased() + change.describe.dropFirst() + "."))
            } catch {
                failed = true
                steps.append(Step(action: change.action, done: false, detail: "Failed to \(change.describe): \(error.localizedDescription)"))
            }
        }
        return steps
    }

    /// A change, with Duo's refusals said plainly: a permission to tick, or a user a directory or SCIM manages.
    static func write(_ body: () async throws -> Void) async throws {
        do { try await read(.write) { try await body() } } catch ServiceError.refused(let reason) where reason.hasPrefix("40010") || reason.hasPrefix("40015") {
            throw ServiceError.input("Duo refused it because a directory sync or SCIM manages this user (it said: \(reason)). Change them in the directory, or in the Admin Panel where Duo allows it.")
        }
    }

    /// Sets a user's status, as Duo's Modify User takes it.
    static func setStatus(_ status: String, of user: User, on service: ServiceClient) async throws {
        _ = try await exchange(service, ["admin", "v1", "users", user.user_id], method: "POST", body: ["status": status])
    }

    struct UserInput: Decodable, Sendable { let user: String }
    static let userField = JSONSchema.string("The user's exact Duo username or user ID (DU…).")
    static let userSchema = JSONSchema.object(["user": userField], required: ["user"])

    // MARK: Status

    struct DisableUser: ServiceOperation {
        typealias Input = UserInput
        static let name = "disable-user"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: enable-user sets them active again. Disabling does not end sessions the applications Duo protects already hold: end those in each application."
        static let summary = "Disable a user, so Duo denies every login of theirs, whatever their devices or bypass codes. Duo refuses it for a user a directory sync manages. \(recovery)"
        static let input = Duo.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Duo.target(input.user, on: service)
            guard target.user.status?.lowercased() != "disabled" else { throw ServiceError.input("Nothing was changed: \(target.named) is already disabled.") }
            let steps = await Duo.inTurn([("disable", "disable \(target.named), who was \(target.user.status ?? "of unknown status")", {
                try await Duo.setStatus("disabled", of: target.user, on: service)
            })])
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct EnableUser: ServiceOperation {
        typealias Input = UserInput
        static let name = "enable-user"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: disable-user again. Restoring access can let an attacker back in, so first remove the devices and bypass codes that are not the user's, as the champion decides."
        static let summary = "Set a disabled or locked-out user active again, so Duo asks for their second factor as usual. Held like the rest, as it gives access back. \(recovery)"
        static let input = Duo.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Duo.target(input.user, on: service)
            let status = target.user.status?.lowercased()
            guard status == "disabled" || status == "locked out" else {
                throw ServiceError.input("Nothing was changed: \(target.named) is \(target.user.status ?? "of unknown status"), not disabled or locked out.\(status == "bypass" ? " clear-bypass sets a user in bypass status active." : "")")
            }
            let steps = await Duo.inTurn([("enable", "set \(target.named), who was \(target.user.status ?? "?"), active", {
                try await Duo.setStatus("active", of: target.user, on: service)
            })])
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct ClearBypass: ServiceOperation {
        typealias Input = UserInput
        static let name = "clear-bypass"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: an administrator can set bypass status again in the Admin Panel. A user who is not enrolled may be unable to log in until they enroll, as the policy decides; a group in bypass status still overrides the user's own."
        static let summary = "Take a user out of bypass status, setting them active, so Duo asks for their second factor again. \(recovery)"
        static let input = Duo.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Duo.target(input.user, on: service)
            guard target.user.status?.lowercased() == "bypass" else {
                throw ServiceError.input("Nothing was changed: \(target.named) is \(target.user.status ?? "of unknown status"), not in bypass status.")
            }
            let steps = await Duo.inTurn([("clear-bypass", "take \(target.named) out of bypass status and set them active", {
                try await Duo.setStatus("active", of: target.user, on: service)
            })])
            let groups = (target.user.groups ?? []).filter { $0.status?.text?.lowercased() == "bypass" }.compactMap(\.name)
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery,
                                   note: groups.isEmpty ? nil : "Still bypassed through the group\(groups.count == 1 ? "" : "s") \(groups.joined(separator: ", ")): change the group in the Admin Panel.")
        }
    }

    // MARK: Bypass codes

    struct DeleteBypassCodes: ServiceOperation {
        typealias Input = UserInput
        static let name = "delete-bypass-codes"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: none for the codes; an administrator can make new ones for the user if they need them."
        static let summary = "Delete every bypass code a user holds, one by one, counting them but never showing them. \(recovery)"
        static let input = Duo.userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await Duo.target(input.user, on: service)
            let listing = try await Duo.read(.resources) {
                try await Duo.list(service, ["admin", "v1", "users", target.user.user_id, "bypass_codes"], limit: 100, pages: 2, as: BypassCode.self)
            }
            let ids = try listing.value.compactMap(\.bypass_code_id).map { try Duo.code($0) }
            guard !ids.isEmpty else { throw ServiceError.input("Nothing was changed: \(target.named) holds no bypass codes.") }
            let steps = await Duo.inTurn(ids.enumerated().map { index, id in
                ("delete-bypass-code", "delete bypass code \(index + 1) of \(ids.count) of \(target.named) [\(id)]", {
                    _ = try await Duo.exchange(service, ["admin", "v1", "bypass_codes", id], method: "DELETE")
                })
            })
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery,
                                   note: listing.complete ? nil : "More bypass codes may remain than were read; run it again.")
        }
    }

    /// A bypass code's ID, as Duo lists it: letters and digits only.
    static func code(_ value: String) throws -> String {
        guard (1...64).contains(value.count), value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").contains) else {
            throw ServiceError.unreadable
        }
        return value
    }

    // MARK: Devices

    struct RemovePhone: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let phone: String }
        static let name = "remove-phone"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: the user enrolls the phone again, or an administrator adds it back to them in the Admin Panel; Duo keeps the phone itself."
        static let summary = "Remove one phone from a user, by its ID from user, such as one an attacker enrolled, so it can no longer approve their logins. \(recovery)"
        static let input = JSONSchema.object(["user": Duo.userField, "phone": .string("The phone's ID (DP…), as user lists it.")], required: ["user", "phone"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let phone = try Duo.id(input.phone, prefix: "DP", "the phone")
            let target = try await Duo.target(input.user, on: service)
            guard let held = (target.user.phones ?? []).first(where: { $0.phone_id == phone }) else {
                throw ServiceError.input("Nothing was changed: \(target.named) has no phone \(phone). Read them with user for their phones' IDs.")
            }
            let steps = await Duo.inTurn([("remove-phone", "remove the phone \(held.sentence) from \(target.named)", {
                _ = try await Duo.exchange(service, ["admin", "v1", "users", target.user.user_id, "phones", phone], method: "DELETE")
            })])
            let left = (target.user.phones?.count ?? 1) - 1 + (target.user.tokens?.count ?? 0) + (target.user.webauthncredentials?.count ?? 0)
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery,
                                   note: left == 0 ? "\(target.named) has no devices left, so they must enroll again: send-enrollment, once their mailbox is known to be theirs." : nil)
        }
    }

    struct RemoveToken: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let token: String }
        static let name = "remove-token"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: an administrator gives the token back to the user in the Admin Panel; Duo keeps the token itself."
        static let summary = "Remove one hardware token from a user, by its ID from user, so its passcodes no longer log them in. \(recovery)"
        static let input = JSONSchema.object(["user": Duo.userField, "token": .string("The hardware token's ID (DH…), as user lists it.")], required: ["user", "token"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let token = try Duo.id(input.token, prefix: "DH", "the hardware token")
            let target = try await Duo.target(input.user, on: service)
            guard let held = (target.user.tokens ?? []).first(where: { $0.token_id == token }) else {
                throw ServiceError.input("Nothing was changed: \(target.named) has no hardware token \(token). Read them with user for their tokens' IDs.")
            }
            let steps = await Duo.inTurn([("remove-token", "remove the hardware token \(held.type ?? "?") \(held.serial ?? "") [\(token)] from \(target.named)", {
                _ = try await Duo.exchange(service, ["admin", "v1", "users", target.user.user_id, "tokens", token], method: "DELETE")
            })])
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct RemoveSecurityKey: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let key: String }
        static let name = "remove-security-key"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: none for the key's registration: the user registers the key, Touch ID or passkey again."
        static let summary = "Delete one of a user's security keys or platform authenticators (WebAuthn), by its key from user, so it can no longer log them in. \(recovery)"
        static let input = JSONSchema.object(["user": Duo.userField, "key": .string("The security key's webauthnkey (WA…), as user lists it.")], required: ["user", "key"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let key = try Duo.id(input.key, prefix: "WA", "the security key")
            let target = try await Duo.target(input.user, on: service)
            guard let held = (target.user.webauthncredentials ?? []).first(where: { $0.webauthnkey == key }) else {
                throw ServiceError.input("Nothing was changed: \(target.named) has no security key \(key). Read them with user for their keys.")
            }
            let steps = await Duo.inTurn([("remove-security-key", "delete the security key \(held.credential_name ?? held.label ?? "?") [\(key)] of \(target.named)", {
                _ = try await Duo.exchange(service, ["admin", "v1", "webauthncredentials", key], method: "DELETE")
            })])
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    // MARK: Enrollment

    struct SendEnrollment: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let validHours: Int? }
        static let name = "send-enrollment"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: the link works once and expires; whoever opens it first enrolls a device, so if that was not the user, remove the device and send another."
        static let summary = "Email a user who has no devices left a single-use enrollment link to their address in Duo, valid for validHours. Duo refuses it for a user still enrolled. \(recovery)"
        static let input = JSONSchema.object(["user": Duo.userField,
                                              "validHours": .integer("How many hours the link works. 24 when left out, at most 720.", minimum: 1, maximum: 720)],
                                             required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let hours = input.validHours ?? 24
            guard (1...720).contains(hours) else { throw ServiceError.input("Give validHours between 1 and 720.") }
            let target = try await Duo.target(input.user, on: service)
            guard let username = target.user.username, let email = target.user.email, !email.isEmpty else {
                throw ServiceError.input("Nothing was changed: \(target.named) has no email address in Duo to send it to.")
            }
            guard target.user.is_enrolled != true else {
                throw ServiceError.input("Nothing was changed: \(target.named) is still enrolled, and Duo sends enrollment only to a user with no devices. Remove their devices first if they must enroll again.")
            }
            let steps = await Duo.inTurn([("send-enrollment", "email \(target.named) at \(email) an enrollment link valid for \(hours) hours", {
                _ = try await Duo.exchange(service, ["admin", "v1", "users", "enroll"], method: "POST",
                                           body: ["username": username, "email": email, "valid_secs": String(hours * 3_600)])
            })])
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    struct SendActivation: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String; let phone: String }
        static let name = "send-activation"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: the link expires after a day; activating moves Duo Mobile to whichever device opens it, so if that was not the user, remove the phone and send another."
        static let summary = "Text one of a user's phones, by its ID from user, a new Duo Mobile activation link, so Duo Mobile can be reactivated on the phone the number belongs to; the old Duo Mobile on it stops approving once it is used. \(recovery)"
        static let input = JSONSchema.object(["user": Duo.userField, "phone": .string("The phone's ID (DP…), as user lists it.")], required: ["user", "phone"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let phone = try Duo.id(input.phone, prefix: "DP", "the phone")
            let target = try await Duo.target(input.user, on: service)
            guard let held = (target.user.phones ?? []).first(where: { $0.phone_id == phone }) else {
                throw ServiceError.input("Nothing was changed: \(target.named) has no phone \(phone). Read them with user for their phones' IDs.")
            }
            guard held.number?.isEmpty == false, held.type?.lowercased() != "landline" else {
                throw ServiceError.input("Nothing was changed: \(held.sentence) has no mobile number to text.")
            }
            let steps = await Duo.inTurn([("send-activation", "text \(held.number ?? "?") a Duo Mobile activation link for \(target.named)", {
                _ = try await Duo.exchange(service, ["admin", "v1", "phones", phone, "send_sms_activation"], method: "POST", body: ["valid_secs": "86400"])
            })])
            return try Duo.outcome(target, steps: steps, recovery: Self.recovery)
        }
    }

    // MARK: Access

    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Says whether this tool's Admin API application may read users and change them, by reading one user and sending Duo a change it can only refuse, to a user that does not exist, which changes nothing; and which permission to tick for what it may not."
        static let input = JSONSchema.object([:])

        /// A user ID no account has: Duo answers a change to it with 404 when the change is allowed, 403 when not.
        static let nobody = "DU000000000000000000"

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var lines: [String] = []
            lines.append(await Duo.check(.resources) { _ = try await Duo.exchange(service, ["admin", "v1", "users"], query: ["limit": "1"]) })
            lines.append(await Duo.check(.write) {
                do { _ = try await Duo.exchange(service, ["admin", "v1", "users", Self.nobody], method: "POST", body: [:]) }
                catch ServiceError.notFound, ServiceError.refused { return }
            })
            lines.append("· Duo cannot end the sessions applications already hold, or disable a user a directory sync manages; those are done in the application or the directory.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
