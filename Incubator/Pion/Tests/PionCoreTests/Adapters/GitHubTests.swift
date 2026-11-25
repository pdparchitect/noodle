import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class GitHubTests: XCTestCase {
    static let values = ["org": "kestrel-labs", "clientID": "Iv23liKestrel"]
    private let github = try! GitHub.preset.makeConnection(name: "GitHub Detection — Kestrel", values: GitHubTests.values)

    /// The signed-in person, an owner unless told otherwise.
    static func signIn(_ service: FakeService, role: String = "admin") {
        service.answers["/user"] = (200, #"{"login":"pion-owner","id":1}"#)
        service.answers["/orgs/kestrel-labs/memberships/pion-owner"] = (200, #"{"state":"active","role":"\#(role)","user":{"login":"pion-owner","id":1}}"#)
    }

    func testBothToolsReachTheAPIAndSignInWithACodeThroughTheirOwnGitHubApps() throws {
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        let containment = try GitHub.containment.makeConnection(name: "GitHub Containment — Kestrel", values: Self.values)
        XCTAssertEqual(GitHub.preset.name, "GitHub Detection")
        XCTAssertEqual(GitHub.preset.id, "07d106a4-0e2c-47b1-a743-3c71161e56e4", "Detection keeps its ID")
        XCTAssertEqual(GitHub.containment.name, "GitHub Containment")
        XCTAssertNotEqual(GitHub.containment.id, GitHub.preset.id)
        XCTAssertNotNil(UUID(uuidString: GitHub.containment.id))
        for (connection, preset, adapter) in [(github, GitHub.preset, "github"), (containment, GitHub.containment, "github-containment")] {
            // Repository paths and /credentials/revoke sit outside /orgs, so the connection reaches the API's root.
            XCTAssertEqual(connection.endpoint.absoluteString, "https://api.github.com")
            XCTAssertEqual(connection.adapter, adapter)
            XCTAssertNotNil(PionAdapters.all[adapter])
            XCTAssertNil(connection.tokenHeader, "No token to paste")
            XCTAssertTrue(ToolConnectionService.signsInWithCode(connection))
            guard case .connection(let configuration) = preset.configuration, let oauth = configuration.oauth else { return XCTFail(preset.name) }
            XCTAssertEqual(oauth.deviceAuthorizationEndpoint?.absoluteString, "https://github.com/login/device/code")
            XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://github.com/login/oauth/access_token")
            XCTAssertEqual(oauth.authorizationEndpoint.absoluteString, "https://github.com/login/oauth/authorize")
            XCTAssertEqual(oauth.scopes, [], "A GitHub App's permissions come from its registration, not scopes")
            XCTAssertFalse(oauth.usesResourceIndicator)
            XCTAssertTrue(oauth.clients.isEmpty, "Each organisation registers its own App")
            XCTAssertEqual(configuration.oauthClientField, "clientID")
            XCTAssertEqual(configuration.fields.map(\.key), ["org", "clientID"])
        }
        XCTAssertThrowsError(try GitHub.preset.makeConnection(name: "Bad", values: ["org": "a/b", "clientID": "Iv23liKestrel"]))
    }

    func testSetupRegistersAPrivateAppWithDeviceFlowAndOnlyThePermissionsEachToolTakes() {
        for (steps, name) in [(GitHub.setup, "Pion Detection"), (GitHub.containmentSetup, "Pion Containment")] {
            let text = steps.joined(separator: "\n")
            for expected in ["New GitHub App", name, "Enable Device Flow", "Expire user authorization tokens", "Webhook › Active", "Only on this account",
                             "Client ID", "no client secret", "Install App", "organisation owner", "SAML"] {
                XCTAssertTrue(text.contains(expected), "\(name): \(expected)")
            }
        }
        XCTAssertTrue(GitHub.detectionPermissions.allSatisfy { !$0.write }, "Detection only reads")
        XCTAssertEqual(Set(GitHub.detectionPermissions.map(\.key)),
                       ["administration", "security_events", "vulnerability_alerts", "metadata", "secret_scanning_alerts", "organization_administration",
                        "members", "organization_personal_access_token_requests", "organization_personal_access_tokens", "organization_self_hosted_runners",
                        "organization_hooks"])
        XCTAssertEqual(Set(GitHub.containmentPermissions.filter(\.write).map(\.key)),
                       ["actions", "administration", "organization_administration", "organization_user_blocking", "members",
                        "organization_personal_access_tokens", "organization_hooks"])
        XCTAssertTrue(GitHub.setup.joined().contains("Self-hosted runners") && GitHub.setup.joined().contains("Read-only"))
        XCTAssertTrue(GitHub.containmentSetup.joined().contains("Blocking users (Read and write)"))
    }

    func testTheAuditLogSearchesNewestFirst() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/audit-log"] = (200, #"[{"@timestamp":1763110800000,"action":"repo.destroy","actor":"mallory","actor_ip":"203.0.113.77","repo":"kestrel-labs/payroll","actor_location":{"country_code":"NG"}}]"#)
        let log = try await callTool(GitHub.adapter, "audit-log", #"{"phrase":"action:repo.destroy","limit":30}"#, on: service, in: github)
        XCTAssertFalse(log.isError, log.text)
        XCTAssertTrue(log.text.contains("repo.destroy by mallory"), log.text)
        XCTAssertTrue(log.text.contains("2025-11-14T09:00:00Z"), log.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["phrase"], "action:repo.destroy")
        XCTAssertEqual(sent["order"], "desc")
        XCTAssertEqual(sent["include"], "all")
        XCTAssertEqual(sent["per_page"], "30")
        XCTAssertEqual(service.requests.first?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")

        // Without Enterprise Cloud there is no audit log API, which the refusal says.
        let free = FakeService()
        let refused = try await callTool(GitHub.adapter, "audit-log", "{}", on: free, in: github)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Enterprise Cloud"), refused.text)
    }

    private static let secret = #"{"number":7,"state":"open","secret_type_display_name":"AWS Access Key ID","created_at":"2026-11-19T09:14:00Z","validity":"active","repository":{"full_name":"kestrel-labs/payroll"},"html_url":"https://github.com/kestrel-labs/payroll/security/secret-scanning/7"}"#
    private static let code = #"{"number":3,"state":"open","created_at":"2026-11-19T09:11:00Z","rule":{"security_severity_level":"high","description":"SQL query built from user-controlled sources"},"repository":{"full_name":"kestrel-labs/portal"},"html_url":"https://github.com/kestrel-labs/portal/security/code-scanning/3"}"#
    private static let dependency = #"{"number":12,"state":"open","created_at":"2026-11-18T22:00:00Z","security_advisory":{"severity":"critical","summary":"Remote code execution in log4j"},"dependency":{"package":{"name":"org.apache.logging.log4j:log4j-core"}},"repository":{"full_name":"kestrel-labs/payroll"},"html_url":"https://github.com/kestrel-labs/payroll/security/dependabot/12"}"#

    func testMembersCollaboratorsAndSecurityAlerts() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/members"] = (200, #"[{"login":"avery","site_admin":false}]"#)
        service.answers["/orgs/kestrel-labs/outside_collaborators"] = (200, #"[{"login":"contractor-1"}]"#)
        service.answers["/orgs/kestrel-labs/secret-scanning/alerts"] = (200, "[\(Self.secret)]")
        service.answers["/orgs/kestrel-labs/code-scanning/alerts"] = (200, "[\(Self.code)]")
        service.answers["/orgs/kestrel-labs/dependabot/alerts"] = (200, "[\(Self.dependency)]")
        let people = try await callTool(GitHub.adapter, "people", "{}", on: service, in: github)
        XCTAssertTrue(people.text.contains("avery"), people.text)
        XCTAssertTrue(people.text.contains("contractor-1"), people.text)

        let alerts = try await callTool(GitHub.adapter, "security-alerts", "{}", on: service, in: github)
        let lines = alerts.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, alerts.text)
        XCTAssertTrue(lines[0].contains("AWS Access Key ID") && lines[0].contains("active") && lines[0].contains("kestrel-labs/payroll"), lines[0])
        XCTAssertTrue(lines[1].contains("high") && lines[1].contains("SQL query"), lines[1])
        XCTAssertTrue(lines[2].contains("critical") && lines[2].contains("log4j-core"), lines[2])
        XCTAssertTrue(service.requests.suffix(3).allSatisfy { queryItems($0)["state"] == "open" })

        let recent = try await callTool(GitHub.adapter, "security-alerts", #"{"kind":"secret","since":"2026-11-19T09:12:00Z"}"#, on: service, in: github)
        XCTAssertEqual(recent.text.split(separator: "\n").count, 1, recent.text)
        XCTAssertEqual(service.requests.last?.url?.path, "/orgs/kestrel-labs/secret-scanning/alerts")

        // An organisation without code scanning still has its other alerts read, and says what code scanning needs.
        service.answers["/orgs/kestrel-labs/code-scanning/alerts"] = (403, #"{"message":"Resource not accessible by integration"}"#)
        let partial = try await callTool(GitHub.adapter, "security-alerts", "{}", on: service, in: github)
        XCTAssertFalse(partial.isError, partial.text)
        XCTAssertTrue(partial.text.contains("AWS Access Key ID") && partial.text.contains("log4j-core"), partial.text)
        XCTAssertTrue(partial.text.contains("Code scanning could not be read") && partial.text.contains("Code scanning alerts: Read-only"), partial.text)
    }

    func testItsTriggerFindsNewSecretsAndHighAndCriticalCodeAndDependencyAlerts() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/secret-scanning/alerts"] = (200, "[\(Self.secret)]")
        service.answers["/orgs/kestrel-labs/code-scanning/alerts"] = (200, "[\(Self.code)]")
        service.answers["/orgs/kestrel-labs/dependabot/alerts"] = (200, "[\(Self.dependency)]")
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let alerts = try await GitHub.adapter.alerts(since: since, connection: github, access: service)
        XCTAssertEqual(alerts.map(\.id), ["https://github.com/kestrel-labs/payroll/security/secret-scanning/7",
                                          "https://github.com/kestrel-labs/portal/security/code-scanning/3"], "The Dependabot alert is older")
        let asked = service.requests.map { ($0.url?.path ?? "", queryItems($0)) }
        XCTAssertEqual(asked.first { $0.0.hasSuffix("/dependabot/alerts") }?.1["severity"], "critical,high")
        XCTAssertEqual(Set(asked.filter { $0.0.hasSuffix("/code-scanning/alerts") }.compactMap { $0.1["severity"] }), ["critical", "high"])
        XCTAssertNil(asked.first { $0.0.hasSuffix("/secret-scanning/alerts") }?.1["severity"], "Every leaked secret counts")
        XCTAssertEqual(GitHub.adapter.watchedTool, "security-alerts")

        let down = FakeService()
        do { _ = try await GitHub.adapter.alerts(since: since, connection: github, access: down); XCTFail("No feed answered") } catch {}
    }

    func testPeopleSaysWhoTheOwnersAre() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/members"] = (200, #"[{"login":"avery"},{"login":"mallory"}]"#)
        service.answers["/orgs/kestrel-labs/members?page=1&per_page=100&role=admin"] = (200, #"[{"login":"mallory"}]"#)
        service.answers["/orgs/kestrel-labs/outside_collaborators"] = (200, "[]")
        let people = try await callTool(GitHub.adapter, "people", "{}", on: service, in: github)
        XCTAssertFalse(people.isError, people.text)
        XCTAssertTrue(people.text.contains("1 owner: mallory"), people.text)
        XCTAssertEqual(people.structured?["owners"] as? [String], ["mallory"])
    }

    func testTeamsListTheirMembersAndParents() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/teams"] = (200, #"[{"slug":"platform","name":"Platform","privacy":"closed","parent":null},{"slug":"payments","name":"Payments","privacy":"secret","parent":{"slug":"platform"}}]"#)
        service.answers["/orgs/kestrel-labs/teams/platform/members"] = (200, #"[{"login":"avery"}]"#)
        service.answers["/orgs/kestrel-labs/teams/payments/members"] = (200, #"[{"login":"mallory"},{"login":"jo"}]"#)
        let teams = try await callTool(GitHub.adapter, "teams", "{}", on: service, in: github)
        XCTAssertFalse(teams.isError, teams.text)
        XCTAssertTrue(teams.text.contains("Platform (1): avery"), teams.text)
        XCTAssertTrue(teams.text.contains("Payments, within Platform, secret (2): mallory, jo"), teams.text)
    }

    func testOrgSettingsFlagsWeakSettingsAndSaysWhatAnOwnerAloneSees() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs"] = (200, #"{"login":"kestrel-labs","name":"Kestrel Labs","two_factor_requirement_enabled":false,"default_repository_permission":"write","members_can_fork_private_repositories":true,"web_commit_signoff_required":false,"deploy_keys_enabled_for_repositories":true,"members_can_create_repositories":true,"members_can_create_public_repositories":false,"members_can_create_private_repositories":true,"members_can_create_internal_repositories":false,"members_can_change_repo_visibility":false,"members_can_delete_repositories":false,"members_can_invite_outside_collaborators":true,"members_can_create_public_pages":false,"plan":{"name":"team"}}"#)
        service.answers["/orgs/kestrel-labs/code-security/configurations"] = (200, #"[{"id":17,"name":"GitHub recommended","target_type":"global","secret_scanning":"enabled","secret_scanning_push_protection":"disabled","dependabot_alerts":"enabled","code_scanning_default_setup":"enabled","enforcement":"enforced"}]"#)
        service.answers["/orgs/kestrel-labs/code-security/configurations/defaults"] = (200, #"[{"default_for_new_repos":"private_and_internal","configuration":{"id":17,"name":"GitHub recommended"}}]"#)
        let settings = try await callTool(GitHub.adapter, "org-settings", "{}", on: service, in: github)
        XCTAssertFalse(settings.isError, settings.text)
        XCTAssertTrue(settings.text.contains("⚠ Two-factor authentication required: false"), settings.text)
        XCTAssertTrue(settings.text.contains("⚠ Base repository permission for members: write"), settings.text)
        XCTAssertTrue(settings.text.contains("⚠ Members can fork private repositories: true"), settings.text)
        XCTAssertTrue(settings.text.contains("⚠ GitHub recommended (global): secret scanning enabled, push protection disabled"), settings.text)
        XCTAssertTrue(settings.text.contains("Applied to new repositories: GitHub recommended for private_and_internal"), settings.text)
        XCTAssertFalse(settings.text.contains("Hidden"), settings.text)

        // A member sees only the public fields: the result says which were hidden, and why.
        service.answers["/orgs/kestrel-labs"] = (200, #"{"login":"kestrel-labs","name":"Kestrel Labs"}"#)
        let hidden = try await callTool(GitHub.adapter, "org-settings", "{}", on: service, in: github)
        XCTAssertTrue(hidden.text.contains("Hidden: Two-factor authentication required") && hidden.text.contains("only to an organisation owner"), hidden.text)
    }

    func testMembersWithout2FAAreReadOnlyForAnOwner() async throws {
        let service = FakeService()
        Self.signIn(service)
        service.answers["/orgs/kestrel-labs/members?filter=2fa_disabled&page=1&per_page=100"] = (200, #"[{"login":"mallory"}]"#)
        service.answers["/orgs/kestrel-labs/members?filter=2fa_insecure&page=1&per_page=100"] = (200, #"[{"login":"jo"}]"#)
        service.answers["/orgs/kestrel-labs/outside_collaborators?filter=2fa_disabled&page=1&per_page=100"] = (200, "[]")
        service.answers["/orgs/kestrel-labs/outside_collaborators?filter=2fa_insecure&page=1&per_page=100"] = (200, "[]")
        let found = try await callTool(GitHub.adapter, "members-without-2fa", "{}", on: service, in: github)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("⚠ Members without two-factor authentication: 1: mallory"), found.text)
        XCTAssertTrue(found.text.contains("⚠ Members with an insecure two-factor method: 1: jo"), found.text)
        XCTAssertTrue(found.text.contains("· Outside collaborators without two-factor authentication: none"), found.text)

        // GitHub filters only for an owner, so a member's read is refused rather than passed off as a filtered list.
        let member = FakeService()
        Self.signIn(member, role: "member")
        let refused = try await callTool(GitHub.adapter, "members-without-2fa", "{}", on: member, in: github)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("only for an owner"), refused.text)
        XCTAssertFalse(member.requests.contains { queryItems($0)["filter"] != nil })
    }

    func testAppInstallationsComeRiskiestFirstAndSayOnlyAnOwnerCanSuspendThem() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/installations"] = (200, #"{"total_count":2,"installations":[{"id":1,"app_slug":"lint-bot","repository_selection":"selected","permissions":{"metadata":"read","checks":"write"}},{"id":2,"app_slug":"deploy-anything","repository_selection":"all","permissions":{"contents":"write","administration":"write","metadata":"read"},"suspended_at":null}]}"#)
        let installations = try await callTool(GitHub.adapter, "app-installations", "{}", on: service, in: github)
        XCTAssertFalse(installations.isError, installations.text)
        let lines = installations.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("deploy-anything") && lines[0].contains("writes administration, contents") && lines[0].contains("all repositories"), lines[0])
        XCTAssertTrue(lines[1].contains("lint-bot"), lines[1])
        XCTAssertTrue(installations.text.contains("Settings › GitHub Apps") && installations.text.contains("Suspend"), installations.text)
    }

    func testWebhooksShowTheirHostAndFlagWeakDelivery() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/hooks"] = (200, #"[{"id":11,"name":"web","active":true,"events":["push"],"config":{"url":"https://ci.kestrel.example/hook?token=s3cret","content_type":"json","insecure_ssl":"0","secret":"********"}},{"id":12,"name":"web","active":true,"events":["*"],"config":{"url":"http://203.0.113.77/collect","content_type":"json","insecure_ssl":"1"}}]"#)
        let hooks = try await callTool(GitHub.adapter, "webhooks", "{}", on: service, in: github)
        XCTAssertFalse(hooks.isError, hooks.text)
        XCTAssertTrue(hooks.text.contains("⚠ Hook 12 to 203.0.113.77") && hooks.text.contains("TLS certificates not verified") && hooks.text.contains("plain HTTP")
                      && hooks.text.contains("every event") && hooks.text.contains("no secret"), hooks.text)
        XCTAssertTrue(hooks.text.contains("· Hook 11 to ci.kestrel.example"), hooks.text)
        XCTAssertFalse(hooks.text.contains("s3cret"), "Only the host is shown")
    }

    static let repos = #"[{"name":"payroll","full_name":"kestrel-labs/payroll","private":true,"visibility":"private","archived":false,"default_branch":"main","security_and_analysis":{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}},{"name":"site","full_name":"kestrel-labs/site","private":false,"visibility":"public","archived":false,"default_branch":"main","security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}},{"name":"old","full_name":"kestrel-labs/old","private":true,"archived":true,"default_branch":"master"}]"#

    func testRepoSecurityLeadsWithPrivateRepositoriesWithoutSecretScanningAndReadsDefaultBranchRules() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/repos"] = (200, Self.repos)
        service.answers["/repos/kestrel-labs/payroll/rules/branches/main"] = (200, "[]")
        service.answers["/repos/kestrel-labs/site/rules/branches/main"] = (200, #"[{"type":"pull_request","ruleset_id":4},{"type":"non_fast_forward","ruleset_id":4}]"#)
        let result = try await callTool(GitHub.adapter, "repo-security", #"{"rules":1}"#, on: service, in: github)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("3 repositories read, 2 not archived"), result.text)
        XCTAssertTrue(result.text.contains("payroll (private): secret scanning disabled, push protection disabled"), result.text)
        XCTAssertFalse(result.text.contains("old (private)"), "Archived repositories are left out")
        XCTAssertTrue(result.text.contains("Default branches with no ruleset rules: payroll (main)"), result.text)
        XCTAssertTrue(result.text.contains("Rules were read for the 1 most recently pushed repositories of 2"), result.text)
        XCTAssertEqual(queryItems(service.requests.first)["sort"], "pushed")
        XCTAssertFalse(service.requests.contains { $0.url?.path == "/repos/kestrel-labs/site/rules/branches/main" }, "Capped at one")
    }

    func testDeployKeysFlagWriteKeysAndStayWithinTheOrganisation() async throws {
        let service = FakeService()
        service.answers["/repos/kestrel-labs/payroll/keys"] = (200, #"[{"id":5,"key":"ssh-ed25519 AAAA","title":"ci","read_only":true,"created_at":"2026-01-01T00:00:00Z"},{"id":6,"key":"ssh-ed25519 BBBB","title":"mystery","read_only":false,"created_at":"2026-11-20T00:00:00Z","added_by":"mallory"}]"#)
        let keys = try await callTool(GitHub.adapter, "deploy-keys", #"{"repo":"kestrel-labs/payroll"}"#, on: service, in: github)
        XCTAssertFalse(keys.isError, keys.text)
        let lines = keys.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("⚠ write payroll: mystery [key 6]") && lines[0].contains("by mallory"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("· read-only payroll: ci [key 5]"), lines[1])

        // A sweep reads the most recently pushed repositories, up to the limit, and says so.
        service.answers["/orgs/kestrel-labs/repos"] = (200, Self.repos)
        let sweep = try await callTool(GitHub.adapter, "deploy-keys", #"{"repos":1}"#, on: service, in: github)
        XCTAssertTrue(sweep.text.contains("Read the 1 most recently pushed repositories of 2"), sweep.text)

        // Any other owner's repository is refused before anything is sent.
        let elsewhere = FakeService()
        let refused = try await callTool(GitHub.adapter, "deploy-keys", #"{"repo":"evil-corp/payroll"}"#, on: elsewhere, in: github)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("belongs to evil-corp, not kestrel-labs"), refused.text)
        XCTAssertTrue(elsewhere.requests.isEmpty)
        let climbing = try await callTool(GitHub.adapter, "deploy-keys", #"{"repo":".."}"#, on: elsewhere, in: github)
        XCTAssertTrue(climbing.isError)
        XCTAssertTrue(elsewhere.requests.isEmpty)
    }

    func testFineGrainedTokensAndRequestsComeRiskiestFirst() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/personal-access-tokens"] = (200, #"[{"id":21,"owner":{"login":"avery"},"repository_selection":"subset","permissions":{"repository":{"metadata":"read"}},"token_name":"reader","token_expires_at":"2027-01-01T00:00:00Z"},{"id":22,"owner":{"login":"mallory"},"repository_selection":"all","permissions":{"repository":{"contents":"write"}},"token_name":"deploy","token_expires_at":null}]"#)
        service.answers["/orgs/kestrel-labs/personal-access-token-requests"] = (200, #"[{"id":31,"owner":{"login":"jo"},"repository_selection":"all","permissions":{"organization":{"members":"write"}},"token_name":"admin-ish","reason":"automation"}]"#)
        let tokens = try await callTool(GitHub.adapter, "fine-grained-tokens", "{}", on: service, in: github)
        XCTAssertFalse(tokens.isError, tokens.text)
        XCTAssertTrue(tokens.text.contains("⚠ deploy of mallory [22]") && tokens.text.contains("writes contents; never expires; all repositories"), tokens.text)
        XCTAssertLessThan(tokens.text.range(of: "deploy of mallory")!.lowerBound, tokens.text.range(of: "reader of avery")!.lowerBound)
        XCTAssertTrue(tokens.text.contains("1 request waiting") && tokens.text.contains("reason: automation"), tokens.text)
    }

    func testActionsSettingsFlagOpenPoliciesWriteTokensAndRunners() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/actions/permissions"] = (200, #"{"enabled_repositories":"all","allowed_actions":"all"}"#)
        service.answers["/orgs/kestrel-labs/actions/permissions/workflow"] = (200, #"{"default_workflow_permissions":"write","can_approve_pull_request_reviews":true}"#)
        service.answers["/orgs/kestrel-labs/actions/runners"] = (200, #"{"total_count":1,"runners":[{"id":3,"name":"build-01","os":"linux","status":"online","busy":true,"labels":[{"name":"self-hosted"}]}]}"#)
        let actions = try await callTool(GitHub.adapter, "actions-settings", "{}", on: service, in: github)
        XCTAssertFalse(actions.isError, actions.text)
        XCTAssertTrue(actions.text.contains("⚠ Actions run in all repositories, allowing all actions"), actions.text)
        XCTAssertTrue(actions.text.contains("⚠ The GITHUB_TOKEN gets write permissions"), actions.text)
        XCTAssertTrue(actions.text.contains("⚠ Workflows may approve pull requests"), actions.text)
        XCTAssertTrue(actions.text.contains("build-01 [3]: linux, online, busy"), actions.text)
    }

    func testCredentialAuthorizationsSayTheyNeedEnterpriseCloudWithSAML() async throws {
        let service = FakeService()
        let missing = try await callTool(GitHub.adapter, "credential-authorizations", "{}", on: service, in: github)
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("Enterprise Cloud with SAML single sign-on"), missing.text)
        service.answers["/orgs/kestrel-labs/credential-authorizations"] = (200, #"[{"login":"mallory","credential_id":161,"credential_type":"personal access token","token_last_eight":"12345678","credential_authorized_at":"2026-11-01T00:00:00Z","scopes":["repo"]}]"#)
        let found = try await callTool(GitHub.adapter, "credential-authorizations", #"{"login":"mallory"}"#, on: service, in: github)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("personal access token of mallory [161] ending 12345678"), found.text)
        XCTAssertEqual(queryItems(service.requests.last)["login"], "mallory")
    }

    func testCheckAccessNamesTheRoleAndThePermissionEachFailingPartNeeds() async throws {
        let service = FakeService()
        Self.signIn(service, role: "member")
        service.answers["/user/installations"] = (200, #"{"total_count":1,"installations":[{"id":9,"app_slug":"pion-detection","account":{"login":"kestrel-labs"},"repository_selection":"all","permissions":{"members":"read","metadata":"read","contents":"write"}}]}"#)
        service.answers["/orgs/kestrel-labs/members"] = (200, "[]")
        service.answers["/orgs/kestrel-labs/hooks"] = (403, #"{"message":"Resource not accessible by integration"}"#)
        service.answers["/orgs/kestrel-labs/installations"] = (403, #"{"message":"You must be an organization owner"}"#)
        let check = try await callTool(GitHub.adapter, "check-access", "{}", on: service, in: github)
        XCTAssertFalse(check.isError, check.text)
        XCTAssertTrue(check.text.contains("a member of the organisation, not an owner"), check.text)
        XCTAssertTrue(check.text.contains("The App pion-detection is installed on the organisation for all repositories"), check.text)
        XCTAssertTrue(check.text.contains("✗ The installation lacks:") && check.text.contains("Organization permissions › Webhooks: Read-only"), check.text)
        XCTAssertTrue(check.text.contains("⚠ The installation holds more than this tool uses: contents write"), check.text)
        XCTAssertTrue(check.text.contains("✓ Members and outside collaborators"), check.text)
        XCTAssertTrue(check.text.contains("✗ Organisation webhooks: the GitHub App lacks Organization permissions › Webhooks: Read-only"), check.text)
        XCTAssertTrue(check.text.contains("✗ GitHub App installations: the signed-in person may not do this: it needs an organisation owner"), check.text)
        XCTAssertTrue(check.text.contains("✗ The audit log: the audit log API needs GitHub Enterprise Cloud"), check.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "check-access only reads")
    }
}
