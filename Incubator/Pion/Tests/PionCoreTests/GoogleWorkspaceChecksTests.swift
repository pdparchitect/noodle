import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// Google Workspace's checks, each run on the real adapter against canned answers from Google.
final class GoogleWorkspaceChecksTests: XCTestCase {
    private let workspace = try! GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])

    private static let users = "/admin/directory/v1/users"
    private static let domains = "/admin/directory/v1/customer/my_customer/domains"
    private static let devices = "/admin/directory/v1/customer/my_customer/devices/mobile"
    private static let token = "/admin/reports/v1/activity/users/all/applications/token"
    private static let admin = "/admin/reports/v1/activity/users/all/applications/admin"
    private static let policies = "/v1/policies"
    private static let notAuthorized = #"{"error":{"code":403,"message":"Not Authorized to access this resource/api","errors":[{"reason":"forbidden"}]}}"#
    private static let scopeMissing = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#

    private func run(_ checks: [AssessmentCheck], policy: AssessmentPolicy = .defaults, on service: FakeService,
                     now: Date = Date()) async -> [String: CheckResult] {
        let workspace = workspace
        let run = await AssessmentRunner.run(checks, policy: policy, detection: { tool, arguments in
            try await GoogleWorkspace.adapter.run(tool, arguments: arguments, connection: workspace, access: service)
        }, containment: nil, now: now)
        XCTAssertEqual(run.results.map(\.checkID), checks.map(\.id))
        return Dictionary(run.results.map { ($0.checkID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func requests(_ service: FakeService, to path: String) -> Int {
        service.requests.filter { $0.url?.path == path }.count
    }

    /// A time `days` ago, as Google gives it.
    private static func ago(_ days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86400 - 3600)).replacingOccurrences(of: "Z", with: ".000Z")
    }

    // MARK: Accounts

    private static let accountChecks = [GoogleWorkspaceChecks.twoStepEnrolment, GoogleWorkspaceChecks.twoStepEnforcement, GoogleWorkspaceChecks.adminTwoStep,
                                        GoogleWorkspaceChecks.superAdminCount, GoogleWorkspaceChecks.inactiveAccounts, GoogleWorkspaceChecks.recoveryOutside]

    private static let someDomains = #"{"domains":[{"domainName":"kestrel.example","isPrimary":true,"verified":true,"domainAliases":[{"domainAliasName":"kestrel-old.example","verified":true}]}]}"#

    private static func account(_ email: String, admin: Bool = false, delegated: Bool = false, enrolled: Bool = true, enforced: Bool = true,
                                lastLogin: String = ago(1), created: String = ago(500), recovery: String? = nil, extra: String = "") -> String {
        #"{"primaryEmail":"\#(email)","isAdmin":\#(admin),"isDelegatedAdmin":\#(delegated),"isEnrolledIn2Sv":\#(enrolled),"isEnforcedIn2Sv":\#(enforced),"lastLoginTime":"\#(lastLogin)","creationTime":"\#(created)""#
            + (recovery.map { #","recoveryEmail":"\#($0)""# } ?? "") + extra + "}"
    }

    private static func listed(_ accounts: [String]) -> String { #"{"users":["# + accounts.joined(separator: ",") + "]}" }

    /// Six checks of the accounts, from one read of them.
    func testAccountChecksFailByNameFromOneRead() async throws {
        let service = FakeService()
        service.answers[Self.domains] = (200, Self.someDomains)
        service.answers[Self.users] = (200, Self.listed([
            Self.account("ivana@kestrel.example", admin: true, recovery: "ivana@kestrel-old.example"),
            Self.account("boss@kestrel.example", admin: true),
            Self.account("nick@kestrel.example", delegated: true, enrolled: false, enforced: false, lastLogin: Self.ago(200), recovery: "nick@gmail.example"),
            Self.account("amy@kestrel.example", enrolled: false, enforced: false, lastLogin: "1970-01-01T00:00:00.000Z", created: Self.ago(400)),
            Self.account("new@kestrel.example", lastLogin: "1970-01-01T00:00:00.000Z", created: Self.ago(5)),
            Self.account("gone@kestrel.example", admin: true, enrolled: false, extra: #","suspended":true"#),
            Self.account("visitor@kestrel.example", enrolled: false, enforced: false, lastLogin: Self.ago(300), recovery: "v@elsewhere.example", extra: #","isGuestUser":true"#),
        ]))
        var policy = AssessmentPolicy.defaults
        policy.maxSuperAdmins = 1
        let results = await run(Self.accountChecks, policy: policy, on: service)
        XCTAssertEqual(requests(service, to: Self.users), 1, "the checks share one read of the accounts")
        let notCounted = " Not counted: 1 suspended, 1 guest accounts."

        let enrolment = try XCTUnwrap(results["gws.2sv-enrolment"])
        XCTAssertEqual(enrolment.offenders, ["amy@kestrel.example", "nick@kestrel.example"])
        let enforcement = try XCTUnwrap(results["gws.2sv-enforcement"])
        XCTAssertEqual(enforcement.status, .fail, enforcement.reason ?? "")
        XCTAssertEqual(enforcement.severity, .high)
        XCTAssertEqual(enforcement.offenders, ["amy@kestrel.example", "nick@kestrel.example"])
        XCTAssertEqual(enforcement.summary, "2-step verification isn't enforced for 2 of 5 active accounts, which the policy requires." + notCounted)

        let admins = try XCTUnwrap(results["gws.admin-2sv"])
        XCTAssertEqual(admins.severity, .critical)
        XCTAssertEqual(admins.offenders, ["nick@kestrel.example"], "a delegated admin counts; a suspended one doesn't")
        XCTAssertEqual(admins.summary, "1 of 3 active admins isn't enrolled in 2-step verification.")

        let supers = try XCTUnwrap(results["gws.super-admin-count"])
        XCTAssertEqual(supers.status, .fail)
        XCTAssertEqual(supers.offenders, ["boss@kestrel.example", "ivana@kestrel.example"])
        XCTAssertEqual(supers.summary, "2 active accounts are super admins; the policy allows at most 1.")

        let inactive = try XCTUnwrap(results["gws.inactive-accounts"])
        XCTAssertEqual(inactive.offenders, ["amy@kestrel.example", "nick@kestrel.example"], "an account added since isn't inactive")
        XCTAssertEqual(inactive.summary, "2 of 5 active accounts haven't signed in for 90 days or more (1 never signed in)." + notCounted)

        let recovery = try XCTUnwrap(results["gws.recovery-outside"])
        XCTAssertEqual(recovery.offenders, ["nick@kestrel.example"], "a verified alias is the organisation's")
        XCTAssertEqual(recovery.summary, "1 of 5 active accounts has a recovery email outside the organisation's domains." + notCounted)
    }

    func testAccountChecksPassWhenEveryAccountIsAsThePolicySays() async throws {
        let service = FakeService()
        service.answers[Self.domains] = (200, Self.someDomains)
        service.answers[Self.users] = (200, Self.listed([
            Self.account("ivana@kestrel.example", admin: true, recovery: "ivana@kestrel-old.example"),
            Self.account("nick@kestrel.example", delegated: true),
            Self.account("new@kestrel.example", lastLogin: "1970-01-01T00:00:00.000Z", created: Self.ago(5)),
        ]))
        let results = await run(Self.accountChecks, on: service)
        XCTAssertEqual(Self.accountChecks.map { results[$0.id]?.status }, Array(repeating: .pass, count: 6), results.values.compactMap(\.reason).joined(separator: "\n"))
        XCTAssertEqual(results["gws.2sv-enforcement"]?.summary, "2-step verification is enforced for all 3 active accounts.")
        XCTAssertEqual(results["gws.admin-2sv"]?.summary, "All 2 active admins are enrolled in 2-step verification.")
        XCTAssertEqual(results["gws.super-admin-count"]?.summary, "1 active account is a super admin; the policy allows at most 3.")
    }

    /// A missing answer stops only the checks that need it, and a refusal says what to add to the admin's role.
    func testAccountChecksSayWhyTheyCouldNotRun() async throws {
        let service = FakeService()
        service.answers[Self.domains] = (200, Self.someDomains)
        service.answers[Self.users] = (200, Self.listed([Self.account("ivana@kestrel.example", admin: true)]))
        let unanswered = await run(Self.accountChecks, policy: AssessmentPolicy(), on: service)
        XCTAssertEqual(unanswered["gws.2sv-enforcement"]?.reason, "The policy doesn't say whether 2-step verification is required; answer it in the questionnaire.")
        XCTAssertEqual(unanswered["gws.super-admin-count"]?.reason, "The policy doesn't say how many super admins there may be; answer it in the questionnaire.")
        XCTAssertEqual(unanswered["gws.inactive-accounts"]?.reason,
                       "The policy doesn't say how many days without signing in make an account inactive; answer it in the questionnaire.")
        XCTAssertEqual(unanswered["gws.admin-2sv"]?.status, .pass, "a check that needs no answer still runs")
        XCTAssertEqual(unanswered["gws.recovery-outside"]?.status, .pass)

        service.answers[Self.users] = (403, Self.notAuthorized)
        let refused = await run(Self.accountChecks, on: service)
        for check in Self.accountChecks {
            XCTAssertEqual(refused[check.id]?.status, .couldNotRun, check.id)
            XCTAssertTrue(refused[check.id]?.reason?.contains("Users › Read") == true, refused[check.id]?.reason ?? check.id)
        }
        service.answers[Self.users] = (200, Self.listed([Self.account("ivana@kestrel.example", admin: true)]))
        service.answers[Self.domains] = (403, Self.scopeMissing)
        let noDomains = await run([GoogleWorkspaceChecks.recoveryOutside], on: service)
        XCTAssertTrue(noDomains["gws.recovery-outside"]?.reason?.contains("admin.directory.domain.readonly") == true, noDomains["gws.recovery-outside"]?.reason ?? "")
    }

    /// How long since someone signed in is counted from the run's time, not the clock's.
    func testInactiveAccountsGoByTheRunsTime() async throws {
        let service = FakeService()
        service.answers[Self.users] = (200, Self.listed([Self.account("ivana@kestrel.example", lastLogin: "2026-01-01T09:00:00.000Z", created: "2025-01-01T09:00:00.000Z")]))
        let day = { (text: String) in ISO8601DateFormatter().date(from: text)! }
        let soon = await run([GoogleWorkspaceChecks.inactiveAccounts], on: service, now: day("2026-03-01T00:00:00Z"))
        XCTAssertEqual(soon["gws.inactive-accounts"]?.status, .pass)
        let later = await run([GoogleWorkspaceChecks.inactiveAccounts], on: service, now: day("2026-06-01T00:00:00Z"))
        XCTAssertEqual(later["gws.inactive-accounts"]?.offenders, ["ivana@kestrel.example"])
    }

    // MARK: Devices

    private static func device(_ id: String, _ owner: String, model: String, status: String = "APPROVED", lastSync: String, compromised: String? = nil) -> String {
        #"{"resourceId":"\#(id)","email":["\#(owner)"],"model":"\#(model)","status":"\#(status)","lastSync":"\#(lastSync)""#
            + (compromised.map { #","deviceCompromisedStatus":"\#($0)""# } ?? "") + "}"
    }

    private static func mobile(_ devices: [String]) -> String { #"{"mobiledevices":["# + devices.joined(separator: ",") + "]}" }

    func testDeviceChecksFailOnStaleAndCompromisedApprovedDevices() async throws {
        let service = FakeService()
        service.answers[Self.devices] = (200, Self.mobile([
            Self.device("d-old", "a.sold@kestrel.example", model: "iPhone 12", lastSync: Self.ago(400)),
            Self.device("d-never", "c@kestrel.example", model: "Galaxy S23", lastSync: "1970-01-01T00:00:00.000Z"),
            Self.device("d-bad", "b@kestrel.example", model: "Pixel 8", lastSync: Self.ago(1), compromised: "Compromise detected"),
            Self.device("d-blocked", "m@kestrel.example", model: "iPad", status: "BLOCKED", lastSync: Self.ago(200), compromised: "Compromise detected"),
            Self.device("d-fresh", "ivana@kestrel.example", model: "iPhone 15", lastSync: Self.ago(2), compromised: "No compromise detected"),
        ]))
        let checks = [GoogleWorkspaceChecks.staleDevices, GoogleWorkspaceChecks.compromisedDevices]
        let results = await run(checks, on: service)
        let stale = try XCTUnwrap(results["gws.stale-devices"])
        XCTAssertEqual(stale.status, .fail, stale.reason ?? "")
        XCTAssertEqual(stale.offenders, ["Galaxy S23 of c@kestrel.example (d-never)", "iPhone 12 of a.sold@kestrel.example (d-old)"])
        XCTAssertEqual(stale.summary, "2 approved phones and tablets haven't synced for 90 days or more (1 never synced), and can still reach the accounts on them.")
        XCTAssertEqual(stale.reads.first?.described, #"all-devices {"inactiveDays":90,"limit":5000,"status":"APPROVED"}"#)
        let compromised = try XCTUnwrap(results["gws.compromised-devices"])
        XCTAssertEqual(compromised.offenders, ["Pixel 8 of b@kestrel.example (d-bad)"], "a blocked device can't sync")
        XCTAssertEqual(compromised.severity, .high)

        service.answers[Self.devices] = (200, Self.mobile([Self.device("d-fresh", "ivana@kestrel.example", model: "iPhone 15", lastSync: Self.ago(2))]))
        var policy = AssessmentPolicy.defaults
        policy.staleDeviceDays = 30
        let passed = await run(checks, policy: policy, on: service)
        XCTAssertEqual(passed["gws.stale-devices"]?.summary, "No approved phone or tablet has gone 30 days or more without syncing.")
        XCTAssertEqual(passed["gws.compromised-devices"]?.summary, "Google finds none of the 1 approved phone or tablet compromised.")

        service.answers[Self.devices] = (403, Self.notAuthorized)
        let refused = await run(checks, on: service)
        XCTAssertTrue(refused.values.allSatisfy { $0.status == .couldNotRun && $0.reason?.contains("read access to devices") == true },
                      refused.values.compactMap(\.reason).joined(separator: "\n"))
        let unanswered = await run(checks, policy: AssessmentPolicy(), on: service)
        XCTAssertEqual(unanswered["gws.stale-devices"]?.reason, "The policy doesn't say how many days without syncing make a device stale; answer it in the questionnaire.")
    }

    /// Approved devices are listed first, at most 5000: one compromised past them is said as what the check can't see.
    func testCompromisedDevicesPastTheListAreALimitNotAPass() async throws {
        let service = FakeService()
        let clean = (0..<5000).map { Self.device("d-\($0)", "u\($0)@kestrel.example", model: "iPhone", lastSync: Self.ago(400)) }
        service.answers[Self.devices] = (200, Self.mobile(clean + [Self.device("d-last", "b@kestrel.example", model: "Pixel 8", lastSync: Self.ago(1), compromised: "Compromise detected")]))
        let result = await run([GoogleWorkspaceChecks.compromisedDevices], on: service)["gws.compromised-devices"]
        XCTAssertEqual(result?.status, .couldNotRun)
        XCTAssertEqual(result?.reason, "There are more phones and tablets than the 5000 this check reads at once, and Google finds 1 of the others compromised, so whether it is approved can't be told here; "
                       + "filter the Admin console's Devices › Mobile & endpoints › Mobile devices by compromised status to see.")
    }

    // MARK: Apps

    private static func grant(_ time: String, _ user: String, _ name: String, _ client: String, _ scope: String, event: String = "authorize") -> String {
        #"{"id":{"time":"\#(time)","uniqueQualifier":"\#(client)-\#(user)-\#(event)-\#(time)"},"actor":{"email":"\#(user)"},"events":[{"name":"\#(event)","parameters":[{"name":"app_name","value":"\#(name)"},{"name":"client_id","value":"\#(client)"},{"name":"scope","multiValue":["\#(scope)"]}]}]}"#
    }

    private static func delegation(_ time: String, _ client: String, event: String = "AUTHORIZE_API_CLIENT_ACCESS") -> String {
        #"{"id":{"time":"\#(time)","uniqueQualifier":"\#(client)-\#(event)-\#(time)"},"actor":{"email":"pdp@kestrel.example"},"events":[{"name":"\#(event)","parameters":[{"name":"API_CLIENT_NAME","value":"\#(client)"},{"name":"API_SCOPES","value":"https://mail.google.com/"}]}]}"#
    }

    private static func items(_ items: [String]) -> String { #"{"items":["# + items.joined(separator: ",") + "]}" }

    /// The grants and delegations come from the logs, in the order oauth-apps reads them: grants, revocations,
    /// delegations, then their removals.
    private func answerApps(_ service: FakeService) {
        service.sequences[Self.token] = [
            (200, Self.items([
                Self.grant("2026-11-10T09:00:00.000Z", "nick@kestrel.example", "Mail Helper", "222", "https://mail.google.com/"),
                Self.grant("2026-11-10T09:00:00.000Z", "pdp@kestrel.example", "Reclaim.ai", "111", "https://www.googleapis.com/auth/calendar"),
                Self.grant("2026-11-10T09:00:00.000Z", "pdp@kestrel.example", "Admin Tool", "333", "https://www.googleapis.com/auth/admin.directory.user"),
                Self.grant("2026-11-10T09:00:00.000Z", "ivana@kestrel.example", "Approved Mailer", "444", "https://www.googleapis.com/auth/gmail.send"),
                // Granted, revoked, then granted again: still held.
                Self.grant("2026-11-01T09:00:00.000Z", "ivana@kestrel.example", "Mail Again", "777", "https://www.googleapis.com/auth/gmail.readonly"),
                Self.grant("2026-11-03T09:00:00.000Z", "ivana@kestrel.example", "Mail Again", "777", "https://www.googleapis.com/auth/gmail.readonly"),
            ])),
            (200, Self.items([Self.grant("2026-11-12T09:00:00.000Z", "pdp@kestrel.example", "Admin Tool", "333", "", event: "revoke"),
                              Self.grant("2026-11-02T09:00:00.000Z", "ivana@kestrel.example", "Mail Again", "777", "", event: "revoke")])),
        ]
        service.sequences[Self.admin] = [
            (200, Self.items([Self.delegation("2026-11-01T09:00:00.000Z", "555"), Self.delegation("2026-11-01T09:00:00.000Z", "666"),
                              Self.delegation("2026-11-01T09:00:00.000Z", "444"),
                              // Delegated, removed, then delegated again: still held.
                              Self.delegation("2026-10-01T09:00:00.000Z", "888"), Self.delegation("2026-10-03T09:00:00.000Z", "888")])),
            (200, Self.items([Self.delegation("2026-11-02T09:00:00.000Z", "666", event: "REMOVE_API_CLIENT_ACCESS"),
                              Self.delegation("2026-10-02T09:00:00.000Z", "888", event: "REMOVE_API_CLIENT_ACCESS")])),
        ]
    }

    func testAppChecksFailOnUnapprovedRiskyGrantsAndDelegationsFromOneRead() async throws {
        let service = FakeService()
        answerApps(service)
        var policy = AssessmentPolicy.defaults
        policy.approvedApps = ["444"]
        let checks = [GoogleWorkspaceChecks.riskyOAuthApps, GoogleWorkspaceChecks.domainWideDelegation]
        let results = await run(checks, policy: policy, on: service)
        XCTAssertEqual(service.requests.count, 4, "both checks share one oauth-apps read")
        let risky = try XCTUnwrap(results["gws.risky-oauth-apps"])
        XCTAssertEqual(risky.status, .fail, risky.reason ?? "")
        XCTAssertEqual(risky.offenders, ["Mail Again (777)", "Mail Helper (222)"],
                       "calendar access isn't high risk, a revoked app isn't held unless granted again, and an approved one passes")
        XCTAssertTrue(risky.summary?.contains("about 180 days, not from the access apps hold now") == true, risky.summary ?? "")
        let delegation = try XCTUnwrap(results["gws.domain-wide-delegation"])
        XCTAssertEqual(delegation.severity, .critical)
        XCTAssertEqual(delegation.offenders, ["555", "888"], "a removed delegation and an approved one pass; one given again after removal doesn't")
        XCTAssertTrue(delegation.summary?.hasPrefix("2 apps were given domain-wide delegation, not removed since and not on the policy's approved apps.") == true
                      && delegation.summary?.contains("about 180 days") == true, delegation.summary ?? "")

        answerApps(service)
        policy.approvedApps = ["222", "555", "444", "777", "888"]
        let passed = await run(checks, policy: policy, on: service)
        XCTAssertEqual(passed["gws.risky-oauth-apps"]?.status, .pass)
        XCTAssertTrue(passed["gws.risky-oauth-apps"]?.summary?.contains("180 days") == true)
        XCTAssertEqual(passed["gws.domain-wide-delegation"]?.status, .pass)

        let unanswered = await run(checks, policy: AssessmentPolicy(), on: service)
        XCTAssertEqual(unanswered["gws.risky-oauth-apps"]?.reason, "The policy doesn't say which apps are approved; answer it in the questionnaire.")

        service.answers[Self.token] = (403, Self.scopeMissing)
        let refused = await run(checks, policy: policy, on: service)
        XCTAssertTrue(refused.values.allSatisfy { $0.reason?.contains("admin.reports.audit.readonly") == true }, refused.values.compactMap(\.reason).joined(separator: "\n"))
    }

    // MARK: Organisation settings

    private static func setting(_ type: String, _ scope: String, _ value: String, by kind: String = "ADMIN") -> String {
        #"{"name":"policies/\#(UUID().uuidString)","type":"\#(kind)","policyQuery":{\#(scope)},"setting":{"type":"settings/\#(type)","value":\#(value)}}"#
    }

    private static func settings(_ settings: [String]) -> String { #"{"policies":["# + settings.joined(separator: ",") + "]}" }

    /// Google's own default for another setting, which says root1 is the whole organisation.
    private static let rootDefault = setting("security.less_secure_apps", #""orgUnit":"orgUnits/root1""#, #"{"allowLessSecureApps":false}"#, by: "SYSTEM")
    private static let root = #""orgUnit":"orgUnits/root1""#

    private static let settingChecks = [GoogleWorkspaceChecks.externalSharing, GoogleWorkspaceChecks.twoStepOrgEnforcement]

    private func sharing(_ policy: AssessmentPolicy.ExternalSharing, _ settings: [String], on service: FakeService) async -> CheckResult? {
        service.answers[Self.policies] = (200, Self.settings(settings))
        var asked = AssessmentPolicy.defaults
        asked.externalSharing = policy
        return await run([GoogleWorkspaceChecks.externalSharing], policy: asked, on: service)["gws.external-sharing"]
    }

    /// Not set for the whole organisation, Google's default applies there, which breaks the policy.
    func testSettingChecksFailWhereTheOrganisationIsSetAgainstThePolicyOrLeftAtGooglesDefault() async throws {
        let service = FakeService()
        service.answers[Self.policies] = (200, Self.settings([
            Self.rootDefault,
            Self.setting("drive_and_docs.external_sharing", #""orgUnit":"orgUnits/eng""#, #"{"externalSharingMode":"ALLOWED"}"#),
            Self.setting("security.two_step_verification_enforcement", Self.root, #"{"enforcedFrom":"2025-01-01T00:00:00Z"}"#),
            Self.setting("security.two_step_verification_enforcement", #""orgUnit":"orgUnits/eng","group":"groups/contractors""#, #"{"enforcedFrom":"2099-01-01T00:00:00Z"}"#),
            Self.setting("security.two_step_verification_enforcement_factor", Self.root, #"{"allowedSignInFactorSet":"ALL"}"#),
        ]))
        let results = await run(Self.settingChecks, on: service)
        XCTAssertEqual(requests(service, to: Self.policies), 1, "the checks share one read of the settings")
        let sharing = try XCTUnwrap(results["gws.external-sharing"])
        XCTAssertEqual(sharing.status, .fail, sharing.reason ?? "")
        XCTAssertEqual(sharing.offenders, ["org unit orgUnits/eng", "the whole organisation (Google's default)"])
        XCTAssertEqual(sharing.summary, "Drive files may be shared outside the organisation in 2 of 2 places: the whole organisation and the 1 organisational unit or group set apart from it, which the policy doesn't allow. "
                       + "Drive sharing outside the organisation isn't set for the whole organisation, so Google's default applies: files may be shared outside the organisation. "
                       + "Set it at the top level in the Admin console under Apps › Google Workspace › Drive and Docs › Sharing settings.")
        let enforcement = try XCTUnwrap(results["gws.2sv-org-enforcement"])
        XCTAssertEqual(enforcement.status, .fail, enforcement.reason ?? "")
        XCTAssertEqual(enforcement.offenders, ["group groups/contractors"], "another setting whose type starts the same isn't counted")
        XCTAssertEqual(enforcement.summary,
                       "2-step verification isn't enforced in 1 of 2 places: the whole organisation and the 1 organisational unit or group set apart from it, which the policy requires.")

        // Nothing set for the whole organisation: enforcement is off by Google's default.
        service.answers[Self.policies] = (200, Self.settings([Self.rootDefault,
            Self.setting("security.two_step_verification_enforcement", #""orgUnit":"orgUnits/eng""#, #"{"enforcedFrom":"2025-01-01T00:00:00Z"}"#)]))
        let unset = await run([GoogleWorkspaceChecks.twoStepOrgEnforcement], on: service)["gws.2sv-org-enforcement"]
        XCTAssertEqual(unset?.offenders, ["the whole organisation (Google's default)"])
        XCTAssertTrue(unset?.summary?.contains("isn't set for the whole organisation, so Google's default applies: 2-step verification isn't enforced.") == true, unset?.summary ?? "")
    }

    /// Not allowed fails sharing with allowlisted domains; trusted domains only fails only sharing with any domain.
    func testExternalSharingHoldsEachPolicyAnswer() async throws {
        let service = FakeService()
        let allowlisted = [Self.rootDefault, Self.setting("drive_and_docs.external_sharing", Self.root, #"{"externalSharingMode":"ALLOWLISTED_DOMAINS"}"#)]
        let trusted = await sharing(.trustedDomainsOnly, allowlisted, on: service)
        XCTAssertEqual(trusted?.status, .pass, trusted?.reason ?? "")
        XCTAssertEqual(trusted?.summary, "Drive files may be shared outside the organisation only with allowlisted domains, if at all, for the whole organisation.")
        let strict = await sharing(.notAllowed, allowlisted, on: service)
        XCTAssertEqual(strict?.offenders, ["the whole organisation"])
        XCTAssertEqual(strict?.summary, "Drive files may be shared outside the organisation for the whole organisation, which the policy doesn't allow.")

        // An admin's value for the whole organisation stands over Google's default for it.
        let overridden = await sharing(.notAllowed, [Self.setting("drive_and_docs.external_sharing", Self.root, #"{"externalSharingMode":"ALLOWED"}"#, by: "SYSTEM"),
                                                     Self.setting("drive_and_docs.external_sharing", Self.root, #"{"externalSharingMode":"DISALLOWED"}"#)], on: service)
        XCTAssertEqual(overridden?.status, .pass, overridden?.reason ?? "")
        XCTAssertEqual(overridden?.summary, "Drive files may not be shared outside the organisation, for the whole organisation.")
        let byDefault = await sharing(.trustedDomainsOnly, [Self.setting("drive_and_docs.external_sharing", Self.root, #"{"externalSharingMode":"ALLOWED"}"#, by: "SYSTEM")], on: service)
        XCTAssertEqual(byDefault?.offenders, ["the whole organisation (Google's default)"])
        let unit = await sharing(.trustedDomainsOnly, allowlisted + [Self.setting("drive_and_docs.external_sharing", #""orgUnit":"orgUnits/eng""#, #"{"externalSharingMode":"ALLOWED"}"#)], on: service)
        XCTAssertEqual(unit?.offenders, ["org unit orgUnits/eng"])
        XCTAssertEqual(unit?.summary, "Drive files may be shared with any domain outside the organisation in 1 of 2 places: the whole organisation and the 1 organisational unit or group set apart from it, which the policy doesn't allow.")

        var relaxed = AssessmentPolicy.defaults
        relaxed.externalSharing = .allowed
        relaxed.twoStepVerification = .optional
        let asked = service.requests.count
        let allowed = await run(Self.settingChecks, policy: relaxed, on: service)
        XCTAssertEqual(allowed.values.map(\.status), [.pass, .pass])
        XCTAssertEqual(service.requests.count, asked, "nothing to read when the policy allows it")
        XCTAssertEqual(AssessmentPolicy(markdown: "---\nexternal-sharing: trusted-domains-only\n---\n").externalSharing, .trustedDomainsOnly)
    }

    /// Enforcement from a date is judged at the run's time, not the clock's.
    func testTwoStepEnforcementGoesByTheRunsTime() async throws {
        let service = FakeService()
        service.answers[Self.policies] = (200, Self.settings([Self.rootDefault,
            Self.setting("security.two_step_verification_enforcement", Self.root, #"{"enforcedFrom":"2026-12-01T00:00:00Z"}"#)]))
        let day = { (text: String) in ISO8601DateFormatter().date(from: text)! }
        let before = await run([GoogleWorkspaceChecks.twoStepOrgEnforcement], on: service, now: day("2026-11-25T00:00:00Z"))
        XCTAssertEqual(before["gws.2sv-org-enforcement"]?.offenders, ["the whole organisation"])
        let after = await run([GoogleWorkspaceChecks.twoStepOrgEnforcement], on: service, now: day("2026-12-02T00:00:00Z"))
        XCTAssertEqual(after["gws.2sv-org-enforcement"]?.summary, "2-step verification is enforced for the whole organisation.")
    }

    /// Google lets only a super admin read the settings, which is said as what the check needs, not as an error.
    func testSettingChecksSayTheyNeedASuperAdminOrTheWholeOrganisation() async throws {
        let service = FakeService()
        service.answers[Self.policies] = (403, Self.notAuthorized)
        let refused = await run(Self.settingChecks, on: service)
        XCTAssertEqual(refused["gws.external-sharing"]?.reason,
                       "This needs a super admin to read the organisation's settings, and the setup keeps Google Workspace Detection's admin from being one; check it in the Admin console under Apps › Google Workspace › Drive and Docs › Sharing settings instead.")
        XCTAssertTrue(refused["gws.2sv-org-enforcement"]?.reason?.hasPrefix("This needs a super admin to read the organisation's settings") == true
                      && refused["gws.2sv-org-enforcement"]?.reason?.contains("Security › Authentication › 2-step verification") == true,
                      refused["gws.2sv-org-enforcement"]?.reason ?? "")

        service.answers[Self.policies] = (403, Self.scopeMissing)
        let scope = await run(Self.settingChecks, on: service)
        XCTAssertTrue(scope.values.allSatisfy { $0.reason?.contains("cloud-identity.policies.readonly") == true }, scope.values.compactMap(\.reason).joined(separator: "\n"))

        // Without Google's defaults, which organisational unit is the whole organisation isn't known.
        for answer in ["{}", Self.settings([Self.setting("drive_and_docs.external_sharing", Self.root, #"{"externalSharingMode":"DISALLOWED"}"#)])] {
            service.answers[Self.policies] = (200, answer)
            let unknown = await run(Self.settingChecks, on: service)
            XCTAssertEqual(unknown["gws.external-sharing"]?.status, .couldNotRun)
            XCTAssertEqual(unknown["gws.external-sharing"]?.reason,
                           "Google didn't say which organisational unit is the whole organisation, so whether Drive sharing outside the organisation is set for everyone can't be told here; check it in the Admin console under Apps › Google Workspace › Drive and Docs › Sharing settings.")
        }

        let unanswered = await run(Self.settingChecks, policy: AssessmentPolicy(), on: service)
        XCTAssertEqual(unanswered["gws.external-sharing"]?.reason,
                       "The policy doesn't say whether files may be shared outside the organisation; answer it in the questionnaire.")
    }

    // MARK: The checklist

    /// Every check runs on one read of each thing it shares with others, in the checklist's order.
    func testTheWholeChecklistReadsEachThingOnce() async throws {
        let service = FakeService()
        service.answers[Self.domains] = (200, Self.someDomains)
        service.answers[Self.users] = (200, Self.listed([Self.account("ivana@kestrel.example", admin: true)]))
        service.answers[Self.devices] = (200, Self.mobile([]))
        answerApps(service)
        service.answers[Self.policies] = (200, Self.settings([
            Self.rootDefault,
            Self.setting("drive_and_docs.external_sharing", Self.root, #"{"externalSharingMode":"DISALLOWED"}"#),
            Self.setting("security.two_step_verification_enforcement", Self.root, #"{"enforcedFrom":"2025-01-01T00:00:00Z"}"#),
        ]))
        var policy = AssessmentPolicy.defaults
        policy.approvedApps = ["222", "555", "444", "777", "888"]
        let results = await run(GoogleWorkspaceChecks.all, policy: policy, on: service)
        XCTAssertEqual(GoogleWorkspaceChecks.all.map { results[$0.id]?.status }, Array(repeating: .pass, count: GoogleWorkspaceChecks.all.count),
                       results.values.compactMap(\.reason).joined(separator: "\n"))
        XCTAssertEqual(requests(service, to: Self.users), 1)
        XCTAssertEqual(requests(service, to: Self.token), 2, "grants and revocations, once")
        XCTAssertEqual(requests(service, to: Self.devices), 2, "stale and every device are two reads")
        XCTAssertEqual(requests(service, to: Self.policies), 1)
        XCTAssertEqual(GoogleWorkspaceChecks.all.map(\.id), [
            "gws.2sv-enrolment", "gws.2sv-enforcement", "gws.admin-2sv", "gws.super-admin-count", "gws.inactive-accounts", "gws.recovery-outside",
            "gws.stale-devices", "gws.compromised-devices", "gws.risky-oauth-apps", "gws.domain-wide-delegation", "gws.unverified-domains",
            "gws.external-sharing", "gws.2sv-org-enforcement",
        ])
    }
}
