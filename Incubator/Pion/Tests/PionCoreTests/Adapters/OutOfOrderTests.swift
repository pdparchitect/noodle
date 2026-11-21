import Foundation
import NoodleCore
@testable import PionCore
import XCTest

/// Every read that asks a service for many things in one call, run again and again against a service that answers
/// out of order, as real ones do. Pion crashed at launch when a release build freed what such reads still held, which
/// the debug build never showed: run these with `swift test -c release -Xswiftc -enable-testing` too.
final class OutOfOrderTests: XCTestCase {
    private static let rounds = 15

    private func service() -> FakeService {
        let service = FakeService()
        service.answerDelay = 0.01
        return service
    }

    func testFalconUsers() async throws {
        let connection = try CrowdStrike.preset.makeConnection(name: "Falcon", values: ["region": "api.crowdstrike.com"])
        let service = service()
        let ids = (0..<20).map { "u-\($0)" }
        service.answers["/user-management/queries/users/v1"] = (200, #"{"resources":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"#)
        service.answers["/user-management/entities/users/GET/v1"] = (200, #"{"resources":[\#(ids.map { #"{"uuid":"\#($0)","uid":"\#($0)@kestrel.example"}"# }.joined(separator: ","))]}"#)
        service.answers["/user-management/combined/user-roles/v1"] = (200, #"{"resources":[{"role_id":"falcon_administrator","role_name":"Falcon Administrator"}]}"#)
        for _ in 0..<Self.rounds {
            let users = try await callTool(CrowdStrike.adapter, "users", "{}", on: service, in: connection)
            XCTAssertEqual(users.text.components(separatedBy: "Falcon Administrator").count - 1, 20, users.text)
        }
    }

    func testEntraRoleHolders() async throws {
        let connection = try Entra.preset.makeConnection(name: "Entra", values: ["tenant": "contoso.onmicrosoft.com"])
        let service = service()
        let roles = (0..<20).map { #"{"id":"r-\#($0)","displayName":"Role \#($0)"}"# }
        service.answers["/v1.0/directoryRoles"] = (200, #"{"value":[\#(roles.joined(separator: ","))]}"#)
        for index in 0..<20 {
            service.answers["/v1.0/directoryRoles/r-\(index)/members"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.user","id":"u\##(index)","userPrincipalName":"u\##(index)@contoso.com"}]}"##)
        }
        for _ in 0..<Self.rounds {
            let holders = try await callTool(Entra.adapter, "role-holders", "{}", on: service, in: connection)
            XCTAssertTrue((0..<20).allSatisfy { holders.text.contains("Role \($0) (1): user u\($0)@contoso.com") }, holders.text)
        }
    }

    func testEntraAppCredentials() async throws {
        let connection = try Entra.preset.makeConnection(name: "Entra", values: ["tenant": "contoso.onmicrosoft.com"])
        let service = service()
        let app = #"{"value":[{"id":"a","displayName":"Payroll Sync","passwordCredentials":[{"keyId":"k1","startDateTime":"2026-01-01T00:00:00Z","endDateTime":"2027-01-01T00:00:00Z"}],"keyCredentials":[]}]}"#
        service.answers["/v1.0/applications"] = (200, app)
        service.answers["/v1.0/servicePrincipals"] = (200, app.replacingOccurrences(of: "Payroll Sync", with: "Legacy Bot"))
        for _ in 0..<Self.rounds {
            let credentials = try await callTool(Entra.adapter, "app-credentials", "{}", on: service, in: connection)
            XCTAssertTrue(credentials.text.contains("Payroll Sync") && credentials.text.contains("Legacy Bot"), credentials.text)
        }
    }

    func testGitHubTeams() async throws {
        let connection = try GitHub.preset.makeConnection(name: "GitHub", values: ["org": "kestrel-labs", "clientID": "Ov23liKestrel"])
        let service = service()
        service.answers["/orgs/kestrel-labs/teams"] = (200, "[" + (0..<20).map { #"{"slug":"t\#($0)","name":"Team \#($0)"}"# }.joined(separator: ",") + "]")
        for index in 0..<20 { service.answers["/orgs/kestrel-labs/teams/t\(index)/members"] = (200, #"[{"login":"m\#(index)"}]"#) }
        for _ in 0..<Self.rounds {
            let teams = try await callTool(GitHub.adapter, "teams", "{}", on: service, in: connection)
            XCTAssertTrue((0..<20).allSatisfy { teams.text.contains("Team \($0) (1): m\($0)") }, teams.text)
        }
    }

    func testOktaAdminRoles() async throws {
        let connection = try Okta.preset.makeConnection(name: "Okta", values: ["domain": "acme.okta.com"])
        let service = service()
        service.answers["/api/v1/iam/assignees/users"] = (200, #"{"value":[\#((0..<20).map { #"{"id":"00u\#($0)"}"# }.joined(separator: ","))]}"#)
        for index in 0..<20 {
            service.answers["/api/v1/users/00u\(index)/roles"] = (200, #"[{"type":"READ_ONLY_ADMIN","label":"Read Only Administrator","status":"ACTIVE","assignmentType":"USER"}]"#)
            service.answers["/api/v1/users/00u\(index)"] = (200, #"{"id":"00u\#(index)","profile":{"login":"admin\#(index)@acme.example"}}"#)
        }
        for _ in 0..<Self.rounds {
            let admins = try await callTool(Okta.adapter, "admin-roles", "{}", on: service, in: connection)
            XCTAssertTrue((0..<20).allSatisfy { admins.text.contains("admin\($0)@acme.example") }, admins.text)
        }
    }

    func testWorkspaceOAuthApps() async throws {
        let connection = try GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let service = service()
        let token = "/admin/reports/v1/activity/users/all/applications/token"
        service.answers[token + "?eventName=authorize&maxResults=1000&startTime=2026-06-01T00:00:00Z"] = (200, #"{"items":[{"id":{"time":"2026-11-10T09:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"pdp@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"app_name","value":"Reclaim.ai"},{"name":"client_id","value":"111.apps.googleusercontent.com"},{"name":"scope","multiValue":["https://www.googleapis.com/auth/calendar"]}]}]}]}"#)
        service.answers[token + "?eventName=revoke&maxResults=1000&startTime=2026-06-01T00:00:00Z"] = (200, #"{"items":[]}"#)
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, #"{"items":[]}"#)
        for _ in 0..<Self.rounds {
            let apps = try await callTool(GoogleWorkspace.adapter, "oauth-apps", #"{"since":"2026-06-01T00:00:00Z"}"#, on: service, in: connection)
            XCTAssertTrue(apps.text.contains("111.apps.googleusercontent.com"), apps.text)
        }
    }
}
