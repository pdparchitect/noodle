import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class GitHubContainmentTests: XCTestCase {
    private let gc = try! GitHub.containment.makeConnection(name: "GitHub Containment — Kestrel", values: GitHubTests.values)
    private let token = "ghp_" + String(repeating: "A1b2C3d4E5", count: 3) + "zZ9yX8"

    override func setUp() {
        super.setUp()
        GitHub.keepContainmentRecords(at: nil)
    }

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await GitHub.$pauses.withValue([0]) {
            try await GitHub.$pause.withValue({ _ in }) { try await callTool(GitHub.containmentAdapter, tool, arguments, on: service, in: gc) }
        }
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func changes(_ service: FakeService) -> [URLRequest] { service.requests.filter { $0.httpMethod != "GET" } }

    private func record(_ result: AdapterResult) -> [String: Any] { result.structured?["record"] as? [String: Any] ?? [:] }
    private func recorded(_ result: AdapterResult) -> [String: String] { record(result)["recorded"] as? [String: String] ?? [:] }
    private func recordID(_ result: AdapterResult) -> String { record(result)["id"] as? String ?? "" }

    private static let membership = "/orgs/kestrel-labs/memberships/mallory"
    private static let owners = "/orgs/kestrel-labs/members?page=1&per_page=100&role=admin"

    func testEveryActionIsHeldAndSaysHowItIsUndone() async throws {
        XCTAssertNil(GitHub.containmentAdapter.watchedTool)
        let listed = try JSONSerialization.jsonObject(with: try await GitHub.containmentAdapter.tools(for: gc)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 23)
        for tool in tools {
            let name = tool["name"] as! String, hints = tool["annotations"] as! [String: Any], summary = tool["description"] as! String
            if ["check-access", "undo-records"].contains(name) {
                XCTAssertEqual(hints["readOnlyHint"] as? Bool, true, name)
            } else {
                XCTAssertEqual(hints["readOnlyHint"] as? Bool, false, name)
                XCTAssertEqual(hints["destructiveHint"] as? Bool, true, "\(name) must be held for approval")
                XCTAssertTrue(summary.contains("Undo") || summary.contains("undone") || summary.contains("Held"), "\(name) says how it is undone: \(summary)")
            }
        }
        for left in ["delete-webhook", "remove-runner", "suspend-installation", "make-private"] {
            XCTAssertFalse(tools.contains { $0["name"] as? String == left }, left)
        }
    }

    func testRemoveMemberRecordsTheRoleAndReinstateMemberInvitesThemBack() async throws {
        let service = FakeService()
        GitHubTests.signIn(service)
        service.sequences[Self.membership] = [(200, #"{"state":"active","role":"member","user":{"login":"mallory","id":42}}"#), (204, ""), (404, "{}")]
        let removed = try await call("remove-member", #"{"user":"mallory"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertTrue(removed.text.contains("Removed mallory"), removed.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" }, ["DELETE /orgs/kestrel-labs/memberships/mallory"])
        XCTAssertEqual(recorded(removed)["role"], "member")
        XCTAssertEqual(recorded(removed)["userID"], "42")
        XCTAssertEqual(record(removed)["undo"] as? String, "reinstate-member")
        XCTAssertEqual(record(removed)["state"] as? String, "done")

        service.answers["/orgs/kestrel-labs/invitations"] = (201, #"{"id":77}"#)
        let back = try await call("reinstate-member", #"{"record":"\#(recordID(removed))"}"#, service)
        XCTAssertFalse(back.isError, back.text)
        let invite = try XCTUnwrap(changes(service).last)
        XCTAssertEqual(invite.httpMethod, "POST")
        XCTAssertEqual(body(invite)["invitee_id"] as? Int, 42)
        XCTAssertEqual(body(invite)["role"] as? String, "reinstate")
        let again = try await call("reinstate-member", #"{"record":"\#(recordID(removed))"}"#, service)
        XCTAssertTrue(again.isError && again.text.contains("already undone"), again.text)
        // An undo acts only from a record of the action it undoes.
        let wrong = try await call("unblock-user", #"{"record":"\#(recordID(removed))"}"#, service)
        XCTAssertTrue(wrong.isError && wrong.text.contains("is of remove-member"), wrong.text)
    }

    func testRemoveMemberRefusesTheSignedInOwnerAndTheLastOwner() async throws {
        let service = FakeService()
        GitHubTests.signIn(service)
        let me = try await call("remove-member", #"{"user":"pion-owner"}"#, service)
        XCTAssertTrue(me.isError && me.text.contains("signed in as"), me.text)
        service.answers[Self.membership] = (200, #"{"state":"active","role":"admin","user":{"login":"mallory","id":42}}"#)
        service.answers[Self.owners] = (200, #"[{"login":"mallory"}]"#)
        let last = try await call("remove-member", #"{"user":"mallory"}"#, service)
        XCTAssertTrue(last.isError && last.text.contains("only owner"), last.text)
        let malformed = try await call("remove-member", #"{"user":"../admin"}"#, service)
        XCTAssertTrue(malformed.isError)
        XCTAssertTrue(changes(service).isEmpty)
        XCTAssertTrue(try GitHub.undoRecords(ServiceClient(base: gc.endpoint, access: service, settings: gc.settings ?? [:], account: gc.id)).isEmpty)
    }

    func testRemovingAnOutsideCollaboratorRecordsTheirRepositoriesAndRestoreGivesThemBack() async throws {
        let service = FakeService()
        service.sequences["/orgs/kestrel-labs/outside_collaborators"] = [(200, #"[{"login":"contractor-1"}]"#), (200, "[]")]
        service.answers["/orgs/kestrel-labs/repos"] = (200, GitHubTests.repos)
        service.answers["/repos/kestrel-labs/payroll/collaborators/contractor-1/permission"] = (200, #"{"permission":"write","role_name":"maintain"}"#)
        service.answers["/repos/kestrel-labs/site/collaborators/contractor-1/permission"] = (200, #"{"permission":"read","role_name":"read"}"#)
        service.answers["/orgs/kestrel-labs/outside_collaborators/contractor-1"] = (204, "")
        let removed = try await call("remove-outside-collaborator", #"{"user":"contractor-1"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertTrue(removed.text.contains("payroll (maintain)"), removed.text)
        XCTAssertEqual(record(removed)["grants"] as? [[String: String]], [["repo": "payroll", "permission": "maintain"]], "Reading a public repository is everyone's")
        let delete = try XCTUnwrap(changes(service).first)
        XCTAssertEqual("\(delete.httpMethod!) \(delete.url!.path)", "DELETE /orgs/kestrel-labs/outside_collaborators/contractor-1")
        // The record was kept before the change was sent.
        let sweep = service.requests.firstIndex { $0.url?.path.hasSuffix("/permission") == true }!
        XCTAssertLessThan(sweep, service.requests.firstIndex(of: delete)!)

        service.answers["/repos/kestrel-labs/payroll/collaborators/contractor-1"] = (201, "{}")
        let back = try await call("restore-collaborator", #"{"record":"\#(recordID(removed))"}"#, service)
        XCTAssertFalse(back.isError, back.text)
        let put = try XCTUnwrap(changes(service).last)
        XCTAssertEqual("\(put.httpMethod!) \(put.url!.path)", "PUT /repos/kestrel-labs/payroll/collaborators/contractor-1")
        XCTAssertEqual(body(put)["permission"] as? String, "maintain")
        XCTAssertTrue(back.text.contains("invited"), back.text)
    }

    func testBlockUserRemovesAMemberFirstThenBlocksAndUnblockLiftsOnlyTheBlock() async throws {
        let service = FakeService()
        GitHubTests.signIn(service)
        service.sequences["/orgs/kestrel-labs/blocks/mallory"] = [(404, "{}"), (204, ""), (204, "")]
        service.sequences[Self.membership] = [(200, #"{"state":"active","role":"member","user":{"login":"mallory","id":42}}"#), (204, ""), (404, "{}")]
        let blocked = try await call("block-user", #"{"user":"mallory"}"#, service)
        XCTAssertFalse(blocked.isError, blocked.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" },
                       ["DELETE /orgs/kestrel-labs/memberships/mallory", "PUT /orgs/kestrel-labs/blocks/mallory"], "Removed first, then blocked")
        XCTAssertTrue(blocked.text.contains("First removed mallory") && blocked.text.contains("Blocked mallory"), blocked.text)
        let client = ServiceClient(base: gc.endpoint, access: service, settings: gc.settings ?? [:], account: gc.id)
        XCTAssertEqual(try GitHub.undoRecords(client).map(\.action), ["remove-member", "block-user"])
        XCTAssertEqual(recorded(blocked)["removed"], "member")
        XCTAssertFalse(recorded(blocked)["removalRecord"]?.isEmpty ?? true)

        service.sequences["/orgs/kestrel-labs/blocks/mallory"] = [(204, ""), (204, ""), (404, "{}")]
        let unblocked = try await call("unblock-user", #"{"record":"\#(recordID(blocked))"}"#, service)
        XCTAssertFalse(unblocked.isError, unblocked.text)
        XCTAssertEqual(changes(service).last.map { "\($0.httpMethod!) \($0.url!.path)" }, "DELETE /orgs/kestrel-labs/blocks/mallory")
        XCTAssertTrue(unblocked.text.contains("not given back by this"), unblocked.text)

        // Someone already blocked is left as they are.
        let already = FakeService()
        already.answers["/orgs/kestrel-labs/blocks/mallory"] = (204, "")
        let refused = try await call("block-user", #"{"user":"mallory"}"#, already)
        XCTAssertTrue(refused.isError && refused.text.contains("already blocked"), refused.text)
    }

    func testDemoteOwnerAndRestoreOwnerSetTheRole() async throws {
        let service = FakeService()
        GitHubTests.signIn(service)
        service.answers[Self.owners] = (200, #"[{"login":"mallory"},{"login":"pion-owner"}]"#)
        service.sequences[Self.membership] = [(200, #"{"state":"active","role":"admin","user":{"login":"mallory","id":42}}"#), (200, #"{"state":"active","role":"member"}"#),
                                              (200, #"{"state":"active","role":"member"}"#)]
        let demoted = try await call("demote-owner", #"{"user":"mallory"}"#, service)
        XCTAssertFalse(demoted.isError, demoted.text)
        let put = try XCTUnwrap(changes(service).first)
        XCTAssertEqual("\(put.httpMethod!) \(put.url!.path)", "PUT /orgs/kestrel-labs/memberships/mallory")
        XCTAssertEqual(body(put) as? [String: String], ["role": "member"])
        XCTAssertEqual(recorded(demoted)["role"], "admin")

        service.sequences[Self.membership] = [(200, #"{"state":"active","role":"admin"}"#), (200, #"{"state":"active","role":"admin"}"#)]
        let restored = try await call("restore-owner", #"{"record":"\#(recordID(demoted))"}"#, service)
        XCTAssertFalse(restored.isError, restored.text)
        XCTAssertEqual(body(changes(service).last) as? [String: String], ["role": "admin"])
    }

    func testRemoveFromTeamRecordsTheRoleAndRestoresIt() async throws {
        let service = FakeService()
        let path = "/orgs/kestrel-labs/teams/platform/memberships/mallory"
        service.sequences[path] = [(200, #"{"role":"maintainer","state":"active"}"#), (204, ""), (404, "{}")]
        let removed = try await call("remove-from-team", #"{"team":"platform","user":"mallory"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" }, ["DELETE \(path)"])
        XCTAssertEqual(recorded(removed)["role"], "maintainer")
        service.sequences[path] = [(200, #"{"role":"maintainer","state":"active"}"#)]
        let back = try await call("restore-team-membership", #"{"record":"\#(recordID(removed))"}"#, service)
        XCTAssertFalse(back.isError, back.text)
        XCTAssertEqual(body(changes(service).last) as? [String: String], ["role": "maintainer"])
    }

    func testRevokingAFineGrainedTokenSaysItCannotBeUndone() async throws {
        let service = FakeService()
        service.sequences["/orgs/kestrel-labs/personal-access-tokens"] = [(200, #"[{"id":22,"owner":{"login":"mallory"},"token_name":"deploy"}]"#), (200, "[]")]
        service.answers["/orgs/kestrel-labs/personal-access-tokens/22"] = (204, "")
        let revoked = try await call("revoke-fine-grained-token", #"{"token":22}"#, service)
        XCTAssertFalse(revoked.isError, revoked.text)
        let post = try XCTUnwrap(changes(service).first)
        XCTAssertEqual("\(post.httpMethod!) \(post.url!.path)", "POST /orgs/kestrel-labs/personal-access-tokens/22")
        XCTAssertEqual(body(post) as? [String: String], ["action": "revoke"])
        XCTAssertNil(record(revoked)["undo"])
        XCTAssertTrue(revoked.text.contains("cannot be undone"), revoked.text)
    }

    func testDeletingADeployKeyRecordsItsPublicKeyAndRestoreAddsItBack() async throws {
        let service = FakeService()
        service.sequences["/repos/kestrel-labs/payroll/keys/6"] = [(200, #"{"id":6,"key":"ssh-ed25519 BBBB","title":"mystery","read_only":false}"#), (204, ""), (404, "{}")]
        let deleted = try await call("delete-deploy-key", #"{"repo":"payroll","key":6}"#, service)
        XCTAssertFalse(deleted.isError, deleted.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" }, ["DELETE /repos/kestrel-labs/payroll/keys/6"])
        XCTAssertEqual(recorded(deleted)["key"], "ssh-ed25519 BBBB")
        XCTAssertEqual(recorded(deleted)["readOnly"], "false")

        service.answers["/repos/kestrel-labs/payroll/keys"] = (201, #"{"id":60,"title":"mystery","read_only":false}"#)
        let back = try await call("restore-deploy-key", #"{"record":"\#(recordID(deleted))"}"#, service)
        XCTAssertFalse(back.isError, back.text)
        let post = body(changes(service).last)
        XCTAssertEqual(post["key"] as? String, "ssh-ed25519 BBBB")
        XCTAssertEqual(post["title"] as? String, "mystery")
        XCTAssertEqual(post["read_only"] as? Bool, false)
        XCTAssertTrue(back.text.contains("key 60"), back.text)

        // A repository of another owner is refused before anything is sent.
        let elsewhere = FakeService()
        let refused = try await call("delete-deploy-key", #"{"repo":"evil-corp/payroll","key":6}"#, elsewhere)
        XCTAssertTrue(refused.isError && refused.text.contains("belongs to evil-corp"), refused.text)
        XCTAssertTrue(elsewhere.requests.isEmpty)
    }

    func testDisablingAWebhookSendsOnlyActiveAndSaysWhenItsSecretWasLost() async throws {
        let service = FakeService()
        let path = "/orgs/kestrel-labs/hooks/12"
        service.sequences[path] = [(200, #"{"id":12,"active":true,"events":["push"],"config":{"url":"https://203.0.113.77/collect","content_type":"json","secret":"********"}}"#),
                                   (200, "{}"), (200, #"{"id":12,"active":false,"events":["push"],"config":{"url":"https://203.0.113.77/collect"}}"#)]
        let disabled = try await call("disable-webhook", #"{"hook":12}"#, service)
        XCTAssertFalse(disabled.isError, disabled.text)
        let patch = try XCTUnwrap(changes(service).first)
        XCTAssertEqual("\(patch.httpMethod!) \(patch.url!.path)", "PATCH \(path)")
        XCTAssertEqual(body(patch) as? [String: Bool], ["active": false], "Only active is sent")
        XCTAssertTrue(disabled.text.contains("no longer reads back with a secret"), disabled.text)
        XCTAssertEqual(recorded(disabled)["secret"], "true")

        service.sequences[path] = [(200, "{}"), (200, #"{"id":12,"active":true,"config":{"url":"https://203.0.113.77/collect"}}"#)]
        let enabled = try await call("enable-webhook", #"{"record":"\#(recordID(disabled))"}"#, service)
        XCTAssertFalse(enabled.isError, enabled.text)
        XCTAssertEqual(body(changes(service).last) as? [String: Bool], ["active": true])
        XCTAssertTrue(enabled.text.contains("set a new secret"), enabled.text)
    }

    func testRevokingAnSSOAuthorizationDeletesIt() async throws {
        let service = FakeService()
        GitHubTests.signIn(service)
        service.sequences["/orgs/kestrel-labs/credential-authorizations"] = [(200, #"[{"login":"mallory","credential_id":161,"credential_type":"personal access token","token_last_eight":"12345678"}]"#), (200, "[]")]
        service.answers["/orgs/kestrel-labs/credential-authorizations/161"] = (204, "")
        let revoked = try await call("revoke-sso-credential", #"{"credential":161}"#, service)
        XCTAssertFalse(revoked.isError, revoked.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" }, ["DELETE /orgs/kestrel-labs/credential-authorizations/161"])
        XCTAssertEqual(recorded(revoked)["lastEight"], "12345678")
    }

    func testDisableActionsRecordsWhatItReplacesAndEnableActionsPutsItBack() async throws {
        let service = FakeService()
        let org = "/orgs/kestrel-labs/actions/permissions", selected = org + "/repositories"
        service.sequences[org] = [(200, #"{"enabled_repositories":"selected","allowed_actions":"selected"}"#), (204, ""), (200, #"{"enabled_repositories":"none"}"#)]
        service.answers[selected] = (200, #"{"total_count":2,"repositories":[{"id":101},{"id":102}]}"#)
        let off = try await call("disable-actions", "{}", service)
        XCTAssertFalse(off.isError, off.text)
        XCTAssertEqual(body(changes(service).first) as? [String: String], ["enabled_repositories": "none"])
        XCTAssertEqual(recorded(off)["selectedRepositoryIDs"], "101,102")
        XCTAssertEqual(recorded(off)["allowedActions"], "selected")

        service.sequences[org] = [(204, ""), (200, #"{"enabled_repositories":"selected","allowed_actions":"selected"}"#)]
        let on = try await call("enable-actions", #"{"record":"\#(recordID(off))"}"#, service)
        XCTAssertFalse(on.isError, on.text)
        let puts = changes(service).suffix(2)
        XCTAssertEqual(body(puts.first)["enabled_repositories"] as? String, "selected")
        XCTAssertEqual(body(puts.first)["allowed_actions"] as? String, "selected")
        XCTAssertEqual(puts.last?.url?.path, selected)
        XCTAssertEqual(body(puts.last)["selected_repository_ids"] as? [Int], [101, 102])

        // One repository.
        let repo = "/repos/kestrel-labs/payroll/actions/permissions"
        service.sequences[repo] = [(200, #"{"enabled":true,"allowed_actions":"all"}"#), (204, ""), (200, #"{"enabled":false}"#)]
        let repoOff = try await call("disable-actions", #"{"repo":"payroll"}"#, service)
        XCTAssertFalse(repoOff.isError, repoOff.text)
        XCTAssertEqual(changes(service).last?.url?.path, repo)
        XCTAssertEqual(body(changes(service).last) as? [String: Bool], ["enabled": false])
        XCTAssertEqual(recorded(repoOff)["allowedActions"], "all")
    }

    func testCancelWorkflowRunSendsOneCancelAndReadsItBack() async throws {
        let service = FakeService()
        let run = "/repos/kestrel-labs/payroll/actions/runs/900"
        service.sequences[run] = [(200, #"{"id":900,"name":"exfil","status":"in_progress","head_branch":"main","actor":{"login":"mallory"}}"#),
                                  (200, #"{"id":900,"status":"completed","conclusion":"cancelled"}"#)]
        service.answers[run + "/cancel"] = (202, "{}")
        let cancelled = try await call("cancel-workflow-run", #"{"repo":"payroll","run":900}"#, service)
        XCTAssertFalse(cancelled.isError, cancelled.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" }, ["POST \(run)/cancel"])
        XCTAssertTrue(cancelled.text.contains("reads back cancelled") && cancelled.text.contains("cannot be undone"), cancelled.text)
    }

    func testReportLeakedTokenGoesSignedOutAndNeverKeepsTheToken() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-containment-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        GitHub.keepContainmentRecords(at: file)
        let service = FakeService(), signedOut = FakeService()
        signedOut.answers["/credentials/revoke"] = (202, "{}")
        let reported = try await GitHub.$anonymous.withValue(signedOut) { try await call("report-leaked-token", #"{"token":"\#(token)"}"#, service) }
        XCTAssertFalse(reported.isError, reported.text)
        XCTAssertTrue(service.requests.isEmpty, "Nothing goes through the connection's sign-in")
        let sent = try XCTUnwrap(signedOut.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.github.com/credentials/revoke")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body(sent)["credentials"] as? [String], [token])
        XCTAssertEqual(recorded(reported)["prefix"], "ghp_")
        XCTAssertEqual(recorded(reported)["sha256"], GitHub.fingerprint(token))
        XCTAssertEqual(GitHub.fingerprint(token).count, 16)
        // The token is in neither the result nor the record kept on disk.
        let result = String(data: try JSONSerialization.data(withJSONObject: reported.structured ?? [:]), encoding: .utf8) ?? ""
        XCTAssertFalse(reported.text.contains(token) || result.contains(token))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(token))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(String(token.dropFirst(4).prefix(12))))

        // A refusal never repeats the token either.
        let refusing = FakeService()
        refusing.answers["/credentials/revoke"] = (422, #"{"message":"Validation failed for \#(token)"}"#)
        let refused = try await GitHub.$anonymous.withValue(refusing) { try await call("report-leaked-token", #"{"token":"\#(token)"}"#, service) }
        XCTAssertTrue(refused.isError)
        XCTAssertFalse(refused.text.contains(token), refused.text)
        let notAToken = try await GitHub.$anonymous.withValue(refusing) { try await call("report-leaked-token", #"{"token":"hunter2"}"#, service) }
        XCTAssertTrue(notAToken.isError && notAToken.text.contains("Nothing was sent"), notAToken.text)
        XCTAssertEqual(refusing.requests.count, 1)
    }

    func testUndoRecordsSurviveARelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-containment-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        GitHub.keepContainmentRecords(at: file)
        let service = FakeService()
        service.sequences["/repos/kestrel-labs/payroll/keys/6"] = [(200, #"{"id":6,"key":"ssh-ed25519 BBBB","title":"mystery","read_only":true}"#), (204, ""), (404, "{}")]
        let deleted = try await call("delete-deploy-key", #"{"repo":"payroll","key":6}"#, service)
        XCTAssertFalse(deleted.isError, deleted.text)
        GitHub.keepContainmentRecords(at: nil)
        GitHub.keepContainmentRecords(at: file)
        let listed = try await call("undo-records", "{}", service)
        XCTAssertTrue(listed.text.contains(recordID(deleted)) && listed.text.contains("undo with restore-deploy-key"), listed.text)
        XCTAssertFalse(listed.text.contains("ssh-ed25519"), "The public key stays in the structured record")
        // Another connection sees none of them.
        let other = try GitHub.containment.makeConnection(name: "Other", values: GitHubTests.values)
        let theirs = try await callTool(GitHub.containmentAdapter, "undo-records", "{}", on: service, in: other)
        XCTAssertTrue(theirs.text.contains("has done nothing"), theirs.text)
    }

    func testCheckAccessComparesTheInstallationWithWhatTheActionsTake() async throws {
        let service = FakeService()
        GitHubTests.signIn(service)
        service.answers["/user/installations"] = (200, #"{"total_count":1,"installations":[{"id":9,"app_slug":"pion-containment","account":{"login":"kestrel-labs"},"repository_selection":"all","permissions":{"members":"write","metadata":"read","organization_hooks":"read"}}]}"#)
        let check = try await call("check-access", "{}", service)
        XCTAssertFalse(check.isError, check.text)
        XCTAssertTrue(check.text.contains("✓ Signed in as pion-owner, an owner"), check.text)
        XCTAssertTrue(check.text.contains("Organization permissions › Webhooks: Read and write") && check.text.contains("Organization permissions › Blocking users: Read and write"), check.text)
        XCTAssertFalse(check.text.contains("lacks: Organization permissions › Members"), check.text)
        XCTAssertTrue(changes(service).isEmpty, "check-access sends no change")
    }
}
