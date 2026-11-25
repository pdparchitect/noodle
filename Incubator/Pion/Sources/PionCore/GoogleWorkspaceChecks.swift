import Foundation
import NoodleToolConnections

/// The checks an Assessment of Google Workspace runs, in the order its checklist shows them. Each reads only through
/// Google Workspace Detection's read-only operations for audit.
public enum GoogleWorkspaceChecks {
    static let source = "Google Workspace"

    public static let all: [AssessmentCheck] = [
        twoStepEnrolment, twoStepEnforcement, adminTwoStep, superAdminCount, inactiveAccounts, recoveryOutside,
        staleDevices, compromisedDevices, riskyOAuthApps, domainWideDelegation, unverifiedDomains,
        externalSharing, twoStepOrgEnforcement,
    ]

    /// Every account, as many as users lists at once; an answer that holds that many may have had more.
    static let allUsers = CheckRead("users", ["limit": .number(10000)], items: "users")
    static let domains = CheckRead("domains", items: "domains")
    /// Every phone and tablet, approved ones first, as many as all-devices lists; its counts cover them all.
    static let allDevices = CheckRead("all-devices", ["limit": .number(5000)], items: "mobiledevices")
    /// Apps granted access and given domain-wide delegation, as the token and admin logs have them.
    static let oauthApps = CheckRead("oauth-apps")

    /// What a check built from the Reports logs says of them: they hold grants, not the access apps hold now.
    static let logWindow = "This is built from the grants in Google's logs, which keep about 180 days, not from the access apps hold now: one granted before then isn't seen."

    // MARK: Accounts

    /// An account as users lists it, with what the checks read.
    struct Account: Decodable {
        let id: String?, primaryEmail: String?, isAdmin: Bool?, isDelegatedAdmin: Bool?, isEnrolledIn2Sv: Bool?, isEnforcedIn2Sv: Bool?
        let suspended: Bool?, archived: Bool?, isGuestUser: Bool?, lastLoginTime: String?, creationTime: String?, recoveryEmail: String?
        let aliases: [String]?

        var name: String { primaryEmail ?? id ?? "an account without an address" }
    }

    /// The accounts that can sign in as the organisation set them up, and a note of those counted aside.
    struct Accounts {
        let active: [Account]
        /// Such as " Not counted: 1 suspended, 1 guest accounts.", or empty when none are.
        let notCounted: String
    }

    /// Suspended and archived accounts can't sign in, so they leave nothing open; guest accounts sign in with their own
    /// Google account, whose settings the organisation doesn't set. Each is counted aside, so the numbers add up to the
    /// Admin console's.
    static func activeAccounts(_ inputs: CheckInputs) throws -> Accounts {
        struct Listed: Decodable { let users: [Account]? }
        let all = try inputs.decode(Listed.self, from: allUsers).users ?? []
        let suspended = all.filter { $0.suspended == true }.count
        let archived = all.filter { $0.suspended != true && $0.archived == true }.count
        let guests = all.filter { $0.suspended != true && $0.archived != true && $0.isGuestUser == true }.count
        let active = all.filter { $0.suspended != true && $0.archived != true && $0.isGuestUser != true }
        let aside = [(suspended, "suspended"), (archived, "archived"), (guests, "guest")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let notCounted = aside.isEmpty ? "" : " Not counted: \(aside.joined(separator: ", ")) account\(suspended + archived + guests == 1 ? "" : "s")."
        return Accounts(active: active, notCounted: notCounted)
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }

    private static func requiresTwoStep(_ policy: AssessmentPolicy) throws -> Bool {
        try policy.required(policy.twoStepVerification, "whether 2-step verification is required") == .required
    }

    static let twoStepEnrolment = AssessmentCheck(
        id: "gws.2sv-enrolment", title: "Active accounts enrolled in 2-step verification", severity: .high,
        rationale: "Without 2-step verification, a password alone opens the account, and passwords are phished, guessed and reused often enough that one is never enough.",
        fix: "Ask each account listed to turn on 2-step verification, then enforce it in the Admin console under Security › Authentication › 2-step verification, with a short enrolment period for new accounts.",
        source: source, policyKeys: ["two-step-verification"],
        reads: { policy in
            try requiresTwoStep(policy) ? [allUsers] : []
        },
        evaluate: { inputs, policy in
            guard try requiresTwoStep(policy) else { return .pass("The policy makes 2-step verification optional.") }
            let accounts = try activeAccounts(inputs), active = accounts.active
            let unenrolled = active.filter { $0.isEnrolledIn2Sv != true }.map(\.name)
            guard !unenrolled.isEmpty else {
                return .pass("All \(active.count) active account\(active.count == 1 ? " is" : "s are") enrolled in 2-step verification." + accounts.notCounted)
            }
            return .fail("\(unenrolled.count) of \(active.count) active accounts \(unenrolled.count == 1 ? "isn't" : "aren't") enrolled in 2-step verification, which the policy requires." + accounts.notCounted,
                         offenders: unenrolled)
        })

    static let twoStepEnforcement = AssessmentCheck(
        id: "gws.2sv-enforcement", title: "2-step verification enforced for active accounts", severity: .high,
        rationale: "Until 2-step verification is enforced, it is each person's choice: anyone can turn it off again, and a new account can go without it, so an account the policy covers can still open with a password alone.",
        fix: "In the Admin console under Security › Authentication › 2-step verification, turn on Enforcement for the organisational units and groups the accounts listed are in.",
        source: source, policyKeys: ["two-step-verification"],
        reads: { policy in
            try requiresTwoStep(policy) ? [allUsers] : []
        },
        evaluate: { inputs, policy in
            guard try requiresTwoStep(policy) else { return .pass("The policy makes 2-step verification optional.") }
            let accounts = try activeAccounts(inputs), active = accounts.active
            let unenforced = active.filter { $0.isEnforcedIn2Sv == false }.map(\.name)
            guard !unenforced.isEmpty else {
                return .pass("2-step verification is enforced for all \(plural(active.count, "active account", "active accounts"))." + accounts.notCounted)
            }
            return .fail("2-step verification isn't enforced for \(unenforced.count) of \(active.count) active accounts, which the policy requires." + accounts.notCounted,
                         offenders: unenforced)
        })

    static let adminTwoStep = AssessmentCheck(
        id: "gws.admin-2sv", title: "Admins enrolled in 2-step verification", severity: .critical,
        rationale: "An admin's password alone opens the whole organisation: whoever has it can read anyone's mail and files, add accounts and turn off every other safeguard.",
        fix: "Have each admin listed turn on 2-step verification now, preferably with a security key, or take their admin role away in the Admin console under Account › Admin roles until they do.",
        source: source,
        reads: { _ in [allUsers] },
        evaluate: { inputs, _ in
            let admins = try activeAccounts(inputs).active.filter { $0.isAdmin == true || $0.isDelegatedAdmin == true }
            let unenrolled = admins.filter { $0.isEnrolledIn2Sv != true }.map(\.name)
            guard !unenrolled.isEmpty else {
                return .pass(admins.isEmpty ? "No active account is an admin."
                             : "All \(admins.count) active admin\(admins.count == 1 ? " is" : "s are") enrolled in 2-step verification.")
            }
            return .fail("\(unenrolled.count) of \(admins.count) active admins \(unenrolled.count == 1 ? "isn't" : "aren't") enrolled in 2-step verification.",
                         offenders: unenrolled)
        })

    static let superAdminCount = AssessmentCheck(
        id: "gws.super-admin-count", title: "No more super admins than the policy allows", severity: .medium,
        rationale: "Each super admin can do anything in the organisation, and no other admin can stop them; every one more is another password and device that, taken, hands over everything.",
        fix: "In the Admin console under Account › Admin roles › Super Admin, remove the role from those who don't need it, giving them a narrower role for their work instead.",
        source: source, policyKeys: ["max-super-admins"],
        reads: { policy in
            _ = try policy.required(policy.maxSuperAdmins, "how many super admins there may be")
            return [allUsers]
        },
        evaluate: { inputs, policy in
            let most = try policy.required(policy.maxSuperAdmins, "how many super admins there may be")
            let admins = try activeAccounts(inputs).active.filter { $0.isAdmin == true }.map(\.name)
            let said = "\(plural(admins.count, "active account is a super admin", "active accounts are super admins")); the policy allows at most \(most)."
            return admins.count > most ? .fail(said, offenders: admins) : .pass(said)
        })

    static let inactiveAccounts = AssessmentCheck(
        id: "gws.inactive-accounts", title: "No active accounts left unused", severity: .medium,
        rationale: "An account nobody uses still opens with its password, and nobody notices when someone else signs in to it: one left behind by someone who left is a common way in.",
        fix: "In the Admin console under Directory › Users, suspend or delete each account listed, after moving anything its owner kept that the organisation needs.",
        source: source, policyKeys: ["inactive-account-days"],
        reads: { policy in
            _ = try policy.required(policy.inactiveAccountDays, "how many days without signing in make an account inactive")
            return [allUsers]
        },
        evaluate: { inputs, policy in
            let days = try policy.required(policy.inactiveAccountDays, "how many days without signing in make an account inactive")
            let accounts = try activeAccounts(inputs), active = accounts.active
            let cutoff = inputs.now.addingTimeInterval(-Double(days) * 86400)
            // Google gives a time in 1970 for an account that never signed in.
            let time = { (value: String?) in ServiceAlert.time(value).flatMap { $0.timeIntervalSince1970 > 86400 ? $0 : nil } }
            var never = 0
            let inactive = active.filter { account in
                if let last = time(account.lastLoginTime) { return last < cutoff }
                guard let created = time(account.creationTime), created < cutoff else { return false }
                never += 1
                return true
            }.map(\.name)
            guard !inactive.isEmpty else {
                return .pass("All \(plural(active.count, "active account has", "active accounts have")) signed in within \(days) days, or were added since." + accounts.notCounted)
            }
            let neverSaid = never > 0 ? " (\(never) never signed in)" : ""
            return .fail("\(inactive.count) of \(active.count) active accounts \(inactive.count == 1 ? "hasn't" : "haven't") signed in for \(days) days or more\(neverSaid)." + accounts.notCounted,
                         offenders: inactive)
        })

    static let recoveryOutside = AssessmentCheck(
        id: "gws.recovery-outside", title: "Recovery emails stay within the organisation", severity: .medium,
        rationale: "Whoever holds an account's recovery email can reset its password; one outside the organisation's domains is an address it doesn't control, and pointing recovery away is a common step in taking an account over.",
        fix: "Ask each account listed to change its recovery email to one the organisation holds, or clear it in the Admin console under Directory › Users › the user › Security › Recovery information; if users needn't recover their own accounts, turn that off under Security › Authentication › Account recovery.",
        source: source,
        reads: { _ in [allUsers, domains] },
        evaluate: { inputs, _ in
            struct Domain: Decodable { let name: String, verified: Bool? }
            struct Listed: Decodable { let domains: [Domain]? }
            // Only verified domains and aliases are the organisation's, as one not verified isn't proven to be.
            let organisation = Set((try inputs.decode(Listed.self, from: domains).domains ?? []).filter { $0.verified == true }.map { $0.name.lowercased() })
            let accounts = try activeAccounts(inputs), active = accounts.active
            let outside = active.filter { account in
                guard let recovery = account.recoveryEmail, !recovery.isEmpty else { return false }
                let own = Set(([account.primaryEmail] + (account.aliases ?? []).map { $0 }).compactMap { $0?.split(separator: "@").last?.lowercased() })
                return GoogleWorkspace.isOutside(recovery, domains: organisation.union(own), fallback: [])
            }.map(\.name)
            guard !outside.isEmpty else {
                return .pass("No active account's recovery email is outside the organisation's domains." + accounts.notCounted)
            }
            return .fail("\(outside.count) of \(active.count) active accounts \(outside.count == 1 ? "has a recovery email" : "have recovery emails") outside the organisation's domains." + accounts.notCounted,
                         offenders: outside)
        })

    // MARK: Devices

    /// A device by its model, owners and resource ID, which tells it from another of the same model.
    static func named(_ device: GoogleWorkspace.MobileDevice) -> String {
        let owners = (device.email ?? []).joined(separator: ", ")
        return "\(device.model ?? "A device") of \(owners.isEmpty ? "no owner listed" : owners) (\(device.resourceId ?? device.deviceId ?? "no resource ID"))"
    }

    /// all-devices' answer: the devices listed, and its counts of every one that matched.
    struct Devices: Decodable {
        let mobiledevices: [GoogleWorkspace.MobileDevice]?
        let matched: Int, neverSynced: Int?, compromised: Int?
        var listed: [GoogleWorkspace.MobileDevice] { mobiledevices ?? [] }
    }

    static func staleRead(_ policy: AssessmentPolicy) throws -> CheckRead {
        let days = try policy.required(policy.staleDeviceDays, "how many days without syncing make a device stale")
        return CheckRead("all-devices", ["status": .text("APPROVED"), "inactiveDays": .number(days), "limit": .number(5000)], items: "mobiledevices")
    }

    static let staleDevices = AssessmentCheck(
        id: "gws.stale-devices", title: "No approved phones or tablets left unsynced", severity: .medium,
        rationale: "Google keeps a phone or tablet approved however long it goes without syncing, so one sold, lost or replaced long ago can still reach the accounts it synced, and nobody is using it to notice.",
        fix: "In the Admin console under Devices › Mobile & endpoints › Mobile devices, remove or block each device listed, wiping the account from any that may be in someone else's hands.",
        source: source, policyKeys: ["stale-device-days"],
        reads: { policy in [try staleRead(policy)] },
        evaluate: { inputs, policy in
            let days = try policy.required(policy.staleDeviceDays, "how many days without syncing make a device stale")
            let devices = try inputs.decode(Devices.self, from: try staleRead(policy))
            guard devices.matched > 0 else { return .pass("No approved phone or tablet has gone \(days) days or more without syncing.") }
            let never = (devices.neverSynced ?? 0) > 0 ? " (\(devices.neverSynced ?? 0) never synced)" : ""
            let shown = devices.listed.count < devices.matched ? " The first \(devices.listed.count) are listed." : ""
            return .fail("\(plural(devices.matched, "approved phone or tablet hasn't", "approved phones and tablets haven't")) synced for \(days) days or more\(never), and can still reach the accounts on them." + shown,
                         offenders: devices.listed.map(named))
        })

    static let compromisedDevices = AssessmentCheck(
        id: "gws.compromised-devices", title: "No approved phones or tablets Google finds compromised", severity: .high,
        rationale: "A phone or tablet Google finds compromised, such as rooted or jailbroken, no longer keeps its apps apart, so whatever runs on it may read the organisation's mail and files it syncs.",
        fix: "In the Admin console under Devices › Mobile & endpoints › Mobile devices, block each device listed and wipe the account from it, then ask its owner what happened to it.",
        source: source,
        reads: { _ in [allDevices] },
        evaluate: { inputs, _ in
            let devices = try inputs.decode(Devices.self, from: allDevices)
            let approved = devices.listed.filter { $0.status?.uppercased() == "APPROVED" }
            let compromised = approved.filter(GoogleWorkspace.isCompromised)
            // Approved devices are listed first, so when every one listed is approved and more matched, some may not be.
            let cut = devices.listed.count < devices.matched && approved.count == devices.listed.count
            guard compromised.isEmpty else {
                let shown = cut ? " This is based on the first \(approved.count) approved devices listed; there are more." : ""
                return .fail("Google finds \(plural(compromised.count, "approved phone or tablet", "approved phones and tablets")) compromised, which can still sync the organisation's mail and files." + shown,
                             offenders: compromised.map(named))
            }
            guard !cut || devices.compromised == 0 else {
                // Those Google counts are all past the list, as none listed is compromised.
                throw AssessmentCheckError.couldNotRun("There are more phones and tablets than the \(devices.listed.count) this check reads at once, and Google finds \(devices.compromised ?? 0) of the others compromised, so whether \(devices.compromised == 1 ? "it is" : "any is") approved can't be told here; filter the Admin console's Devices › Mobile & endpoints › Mobile devices by compromised status to see.")
            }
            return .pass("Google finds none of the \(plural(approved.count, "approved phone or tablet", "approved phones and tablets")) compromised.")
        })

    // MARK: Apps

    private static func approvedApps(_ policy: AssessmentPolicy) throws -> Set<String> {
        Set(try policy.required(policy.approvedApps, "which apps are approved").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    static let riskyOAuthApps = AssessmentCheck(
        id: "gws.risky-oauth-apps", title: "No unapproved apps that read mail or administer", severity: .high,
        rationale: "An app someone lets into their account keeps its access after they forget it, and one that reads mail or administers the domain reads or changes everything it reaches without signing in again; a password reset doesn't take that access away.",
        fix: "Revoke each app listed from the accounts that granted it, with Google Workspace Containment or in the Admin console under Security › Access and data control › API controls › Manage third-party app access, where you can block it; add those meant to stay to the policy's approved apps.",
        source: source, policyKeys: ["approved-apps"],
        reads: { policy in
            _ = try approvedApps(policy)
            return [oauthApps]
        },
        evaluate: { inputs, policy in
            struct App: Decodable { let clientId: String, name: String, scopes: [String], grantedBy: [String], revokedBy: [String] }
            struct Listed: Decodable { let apps: [App]? }
            let approved = try approvedApps(policy)
            let apps = try inputs.decode(Listed.self, from: oauthApps).apps ?? []
            // Still granted by someone: oauth-apps names as revoking it only those who did after they last granted
            // it, so one who granted it again after revoking still holds it.
            let held = apps.filter { app in
                (GoogleWorkspace.risk(app.scopes)?.rank ?? .max) <= 1 && !Set(app.grantedBy).subtracting(app.revokedBy).isEmpty
                    && !approved.contains(app.clientId.lowercased())
            }
            guard !held.isEmpty else {
                return .pass("No app that reads mail or administers the domain is still granted without being approved. " + logWindow)
            }
            return .fail("\(plural(held.count, "app that reads mail or administers the domain is", "apps that read mail or administer the domain are")) still granted by someone and not on the policy's approved apps. " + logWindow,
                         offenders: held.map { "\($0.name) (\($0.clientId))" })
        })

    static let domainWideDelegation = AssessmentCheck(
        id: "gws.domain-wide-delegation", title: "No unapproved domain-wide delegation", severity: .critical,
        rationale: "An app given domain-wide delegation acts as anyone in the domain without asking them, with whatever scopes it was given; nothing a user does, revoking or resetting a password, takes it away.",
        fix: "In the Admin console under Security › Access and data control › API controls › Domain-wide delegation, remove each client listed; add those meant to stay to the policy's approved apps. That page lists every app that holds it now, including any given it before Google's logs begin.",
        source: source, policyKeys: ["approved-apps"],
        reads: { policy in
            _ = try approvedApps(policy)
            return [oauthApps]
        },
        evaluate: { inputs, policy in
            struct Delegated: Decodable { let client: String, removed: String? }
            struct Listed: Decodable { let delegated: [Delegated]? }
            let approved = try approvedApps(policy)
            let window = "This is built from the delegations in Google's admin log, which keeps about 180 days, not from those apps hold now: one given before then isn't seen."
            // oauth-apps says a delegation was removed only by a removal after its latest grant.
            let held = (try inputs.decode(Listed.self, from: oauthApps).delegated ?? [])
                .filter { $0.removed == nil && !approved.contains($0.client.lowercased()) }.map(\.client)
            guard !held.isEmpty else { return .pass("No app was given domain-wide delegation without being approved and kept it. " + window) }
            return .fail("\(plural(held.count, "app was", "apps were")) given domain-wide delegation, not removed since and not on the policy's approved apps. " + window,
                         offenders: held)
        })

    // MARK: Domains

    static let unverifiedDomains = AssessmentCheck(
        id: "gws.unverified-domains", title: "Every domain is verified", severity: .medium,
        rationale: "Google hasn't confirmed the organisation owns a domain that was added but never verified, so its mail and accounts don't work as intended; one left that way is often a typo or a domain the organisation no longer holds, which someone else could register.",
        fix: "In the Admin console under Account › Domains › Manage domains, verify each domain listed or remove it.",
        source: source,
        reads: { _ in [domains] },
        evaluate: { inputs, _ in
            struct Domain: Decodable { let name: String, verified: Bool? }
            struct Listed: Decodable { let domains: [Domain]? }
            let listed = try inputs.decode(Listed.self, from: domains).domains ?? []
            let unverified = listed.filter { $0.verified != true }.map(\.name)
            guard !unverified.isEmpty else {
                return .pass("All \(listed.count) domain\(listed.count == 1 ? " is" : "s and aliases are") verified.")
            }
            return .fail("\(unverified.count) of \(listed.count) domains and aliases \(unverified.count == 1 ? "isn't" : "aren't") verified.",
                         offenders: unverified)
        })

    // MARK: Organisation settings

    /// One setting as policy-settings lists it, for the organisational unit or group it is set for, and whether an
    /// admin set it or Google did, as its default.
    struct Setting: Decodable {
        let settingType: String, appliesTo: String, orgUnit: String?, group: String?, policyType: String?, value: GoogleCloud.JSON?
        var unit: String? { orgUnit.map(GoogleWorkspace.PolicySettings.bare) }
        var isGoogles: Bool { policyType?.uppercased() == "SYSTEM" }
    }

    /// Every setting Google lists, as the checks of the organisation's settings share one read; those they ask about
    /// are listed first, so the limit leaves them in.
    static let organisationSettings = CheckRead("policy-settings", ["limit": .number(2000)], items: "settings")

    /// The organisational unit that is the whole organisation: the one Google's own defaults are listed for, as it
    /// sets them only there. Nil when it listed none, or more than one.
    static func wholeOrganisation(_ all: [Setting]) -> String? {
        let units = Set(all.filter { $0.isGoogles && $0.group == nil }.compactMap(\.unit))
        return units.count == 1 ? units.first : nil
    }

    /// One setting judged for the whole organisation and for each organisational unit or group set apart from it:
    /// those that break the policy, by name, and what the summary adds. Where it isn't set for the whole
    /// organisation, Google's default applies there, `googleDefault`, which breaks the policy for every check of a
    /// setting. `breaks` says whether one place's value does, nil when Google's value doesn't say.
    static func judge(_ type: String, _ inputs: CheckInputs, named: String, page: String, googleDefault: String,
                      breaks: (Setting) -> Bool?) throws -> (offenders: [String], places: Int, note: String) {
        struct Listed: Decodable { let settings: [Setting]? }
        let all = try inputs.decode(Listed.self, from: organisationSettings).settings ?? []
        guard let root = wholeOrganisation(all) else {
            throw AssessmentCheckError.couldNotRun("Google didn't say which organisational unit is the whole organisation, so whether \(named) is set for everyone can't be told here; check it in the Admin console under \(page).")
        }
        let found = all.filter { $0.settingType == type }
        let isWhole = { (setting: Setting) in setting.group == nil && setting.unit == root }
        // An admin's value for the whole organisation stands over Google's default.
        let whole = found.filter(isWhole).sorted { !$0.isGoogles && $1.isGoogles }.first
        let others = found.filter { !isWhole($0) }
        var offenders: [String] = [], note = "", unknown = 0
        if let whole {
            switch breaks(whole) {
            case true?: offenders.append(whole.isGoogles ? "the whole organisation (Google's default)" : "the whole organisation")
            case nil: unknown += 1
            case false?: break
            }
        } else {
            offenders.append("the whole organisation (Google's default)")
            note = " \(named.prefix(1).uppercased() + named.dropFirst()) isn't set for the whole organisation, so Google's default applies: \(googleDefault). Set it at the top level in the Admin console under \(page)."
        }
        for other in others {
            switch breaks(other) {
            case true?: offenders.append(other.appliesTo)
            case nil: unknown += 1
            case false?: break
            }
        }
        if offenders.isEmpty, unknown > 0 {
            throw AssessmentCheckError.couldNotRun("Google listed \(named) without saying what it is in \(plural(unknown, "place", "places")); check it in the Admin console under \(page).")
        }
        return (offenders, 1 + others.count, note)
    }

    /// The whole organisation and the organisational units and groups set apart from it, counted.
    static func places(_ count: Int) -> String {
        count == 1 ? "the whole organisation" : "the whole organisation and the \(plural(count - 1, "organisational unit or group", "organisational units and groups")) set apart from it"
    }

    /// Where `failing` of `count` places break the policy, such as "in 2 of 3 places: the whole organisation and …".
    static func failing(_ failing: Int, of count: Int) -> String {
        count == 1 ? "for the whole organisation" : "in \(failing) of \(count) places: \(places(count))"
    }

    /// Google lets only a super admin read the organisation's settings, which the setup keeps this tool's admin from
    /// being, so such a refusal is said as what the check needs rather than as an error.
    static func settingsUnread(_ page: String) -> @Sendable (String) -> String {
        { reason in
            reason.contains("only a super admin")
                ? "This needs a super admin to read the organisation's settings, and the setup keeps Google Workspace Detection's admin from being one; check it in the Admin console under \(page) instead."
                : reason
        }
    }

    static let sharingType = "drive_and_docs.external_sharing"
    static let sharingPage = "Apps › Google Workspace › Drive and Docs › Sharing settings"

    private static func sharing(_ policy: AssessmentPolicy) throws -> AssessmentPolicy.ExternalSharing {
        try policy.required(policy.externalSharing, "whether files may be shared outside the organisation")
    }

    static let externalSharing = AssessmentCheck(
        id: "gws.external-sharing", title: "Drive sharing outside the organisation as the policy allows", severity: .medium,
        rationale: "Where files may be shared outside the organisation, one mistaken share, or one made on purpose by someone leaving, sends them where the organisation can no longer see or take them back.",
        fix: "In the Admin console under \(sharingPage), set sharing outside the organisation as the policy says for the whole organisation, at the top level, and for each organisational unit and group listed: off, or only with allowlisted domains where the policy allows trusted domains.",
        source: source, policyKeys: ["external-sharing"],
        unread: settingsUnread(sharingPage),
        reads: { policy in
            try sharing(policy) == .allowed ? [] : [organisationSettings]
        },
        evaluate: { inputs, policy in
            let allowed = try sharing(policy)
            guard allowed != .allowed else { return .pass("The policy allows sharing outside the organisation.") }
            let trusted = allowed == .trustedDomainsOnly
            let judged = try judge(sharingType, inputs, named: "Drive sharing outside the organisation", page: sharingPage,
                                   googleDefault: "files may be shared outside the organisation") { setting in
                guard let mode = setting.value.flatMap({ GoogleWorkspace.PolicySettings.text($0, "externalSharingMode")?.uppercased() }) else { return nil }
                guard trusted else { return mode != "DISALLOWED" }
                return mode == "ALLOWED" ? true : ["ALLOWLISTED_DOMAINS", "DISALLOWED"].contains(mode) ? false : nil
            }
            guard !judged.offenders.isEmpty else {
                return .pass((trusted ? "Drive files may be shared outside the organisation only with allowlisted domains, if at all, for "
                                      : "Drive files may not be shared outside the organisation, for ") + places(judged.places) + ".")
            }
            return .fail("Drive files may be shared\(trusted ? " with any domain" : "") outside the organisation \(failing(judged.offenders.count, of: judged.places)), which the policy doesn't allow."
                         + judged.note, offenders: judged.offenders)
        })

    static let enforcementType = "security.two_step_verification_enforcement"
    static let enforcementPage = "Security › Authentication › 2-step verification"

    static let twoStepOrgEnforcement = AssessmentCheck(
        id: "gws.2sv-org-enforcement", title: "2-step verification enforced across the organisation", severity: .high,
        rationale: "Enforcement in the organisation's settings is what keeps 2-step verification on: without it, anyone can turn it off and new accounts start without it.",
        fix: "In the Admin console under \(enforcementPage), turn on Enforcement from today for the whole organisation, at the top level, and for each organisational unit and group listed.",
        source: source, policyKeys: ["two-step-verification"],
        unread: settingsUnread(enforcementPage),
        reads: { policy in
            try requiresTwoStep(policy) ? [organisationSettings] : []
        },
        evaluate: { inputs, policy in
            guard try requiresTwoStep(policy) else { return .pass("The policy makes 2-step verification optional.") }
            // Enforced from a date that has come; with no date, or one still to come, it is not.
            let judged = try judge(enforcementType, inputs, named: "2-step verification enforcement", page: enforcementPage,
                                   googleDefault: "2-step verification isn't enforced") { setting in
                guard let from = setting.value.flatMap({ GoogleWorkspace.PolicySettings.text($0, "enforcedFrom") }),
                      let date = ServiceAlert.time(from) else { return true }
                return date > inputs.now
            }
            guard !judged.offenders.isEmpty else {
                return .pass("2-step verification is enforced for \(places(judged.places)).")
            }
            return .fail("2-step verification isn't enforced \(failing(judged.offenders.count, of: judged.places)), which the policy requires." + judged.note,
                         offenders: judged.offenders)
        })
}
