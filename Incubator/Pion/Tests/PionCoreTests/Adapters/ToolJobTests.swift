import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// Each service with Detection and Containment tools keeps one list of its operations, each naming the jobs it serves,
/// and each tool offers those of its own job.
final class ToolJobTests: XCTestCase {
    private struct Service: Sendable {
        let name: String
        let operations: [any ServiceOperation]
        let detection: OperationAdapter, containment: OperationAdapter
        let detectionTools: Set<String>, containmentTools: Set<String>
        let detectionRequests: Int?, containmentRequests: Int?
        /// The Detection tool the alert watch names.
        var watched = "security-events"
    }

    private static let services = [
        Service(name: "GoogleWorkspace", operations: GoogleWorkspace.operations, detection: GoogleWorkspace.adapter, containment: GoogleWorkspace.containmentAdapter,
                detectionTools: ["activity", "security-events", "admin-roles", "users", "user-groups", "user-devices", "all-devices", "policy-settings",
                                 "group-members", "oauth-apps", "app-activity", "user-timeline", "ip-activity", "link-clicks", "domains", "check-access", "drive-exposure",
                                 "mail-trace", "client-activity"],
                containmentTools: ["user", "tokens", "apps", "app-passwords", "devices", "check-access", "sign-out", "reset-password", "remove-recovery",
                                   "revoke-token", "delete-app-password", "invalidate-backup-codes", "device-block", "suspend", "unsuspend"],
                detectionRequests: 8, containmentRequests: 8),
        Service(name: "AWS", operations: AWS.operations, detection: AWS.adapter, containment: AWS.containmentAdapter,
                detectionTools: ["accounts", "regions", "cloudtrail-events", "guardduty-findings", "securityhub-findings", "access-key", "credential-report",
                                 "iam-access", "access-analyzer-findings", "ec2-instances", "open-security-groups", "logs-insights", "config-history",
                                 "s3-exposure", "identity-center-assignments", "credential-hygiene", "inspector-findings", "macie-findings",
                                 "security-events", "check-access"],
                containmentTools: ["deactivate-access-key", "reactivate-access-key", "quarantine-principal", "release-principal", "revoke-role-sessions",
                                   "remove-session-revocation", "delete-login-profile", "isolate-instance", "unisolate-instance", "detach-instance-profile",
                                   "stop-instance", "snapshot-volumes", "protect-instance", "block-s3-public-access", "restart-logging",
                                   "archive-guardduty-findings", "unarchive-guardduty-findings", "guardduty-feedback", "set-finding-workflow",
                                   "close-findings", "check-access"],
                detectionRequests: nil, containmentRequests: nil),
        Service(name: "GoogleCloud", operations: GoogleCloud.operations, detection: GoogleCloud.adapter, containment: GoogleCloud.containmentAdapter,
                detectionTools: ["audit-logs", "security-events", "scc-findings", "scc-finding", "scc-summary", "iam-policies", "who-can-impersonate",
                                 "public-resources", "sa-keys", "asset-history", "org-policies", "logging-coverage", "find-resources", "check-access"],
                containmentTools: ["disable-sa-key", "enable-sa-key", "disable-service-account", "enable-service-account", "remove-iam-member",
                                   "enforce-public-access-prevention", "revert-public-access-prevention", "snapshot-disks", "stop-instance",
                                   "isolate-instance", "unisolate-instance", "operation-status", "check-access"],
                detectionRequests: nil, containmentRequests: nil),
        Service(name: "Azure", operations: Azure.operations, detection: Azure.adapter, containment: Azure.containmentAdapter,
                detectionTools: ["activity-log", "security-events", "defender-alerts", "resource-graph", "role-assignments", "deny-assignments", "check-access"],
                containmentTools: ["remove-role-assignment", "deallocate-vm", "isolate-vm", "unisolate-vm", "rotate-storage-key", "restrict-storage",
                                   "add-lock", "snapshot-disk", "set-alert-status", "close-alert", "operation-status", "check-access"],
                detectionRequests: nil, containmentRequests: nil),
        Service(name: "Entra", operations: Entra.operations, detection: Entra.adapter, containment: Entra.containmentAdapter,
                detectionTools: ["find-user", "user-groups", "user-sign-in-methods", "sign-ins", "risky-users", "role-holders", "app-permissions",
                                 "directory-audit", "app-credentials", "security-events", "check-access", "conditional-access", "auth-methods-policy"],
                containmentTools: ["user", "disable-sign-in", "enable-sign-in", "revoke-sessions", "delete-sign-in-methods", "remove-directory-role",
                                   "remove-app-credential", "confirm-compromised", "dismiss-user-risk", "check-access"],
                detectionRequests: 4, containmentRequests: 4),
        Service(name: "Okta", operations: Okta.operations, detection: Okta.adapter, containment: Okta.containmentAdapter,
                detectionTools: ["find-user", "user-groups", "user-apps", "user-factors", "sign-in-events", "user-grants", "admin-roles", "api-tokens",
                                 "security-events", "check-access", "sign-on-policies", "mfa-policies", "password-policies"],
                containmentTools: ["user", "suspend", "unsuspend", "deactivate", "clear-sessions", "reset-factors", "delete-factor", "expire-password",
                                   "remove-from-group", "revoke-admin-role", "revoke-app-grants", "revoke-api-token", "check-access"],
                detectionRequests: 8, containmentRequests: 4),
        Service(name: "Cloudflare", operations: Cloudflare.operations, detection: Cloudflare.adapter, containment: Cloudflare.containmentAdapter,
                detectionTools: ["zones", "zone-dns", "zone-settings", "dns-exposure", "firewall-events", "audit-log", "members", "access-logs",
                                 "access-apps", "access-app", "access-users", "access-user", "gateway-activity", "gateway-rules", "gateway-lists", "devices",
                                 "tunnels", "security-events", "check-access"],
                containmentTools: ["access-user", "device", "action-status", "block-ip", "block-asn", "block-country", "unblock", "revoke-access-sessions",
                                   "gateway-block", "gateway-unblock", "revoke-device", "check-access"],
                detectionRequests: 4, containmentRequests: 2),
        Service(name: "Defender", operations: Defender.operations, detection: Defender.adapter, containment: Defender.containmentAdapter,
                detectionTools: ["alerts", "alert", "incidents", "incident", "hunt", "devices", "device", "security-events", "check-access"],
                containmentTools: ["device", "machine-actions", "action-status", "isolate-device", "release-isolation", "restrict-app-execution",
                                   "remove-app-restriction", "stop-and-quarantine-file", "run-av-scan", "collect-investigation-package", "check-access"],
                detectionRequests: 4, containmentRequests: 2),
        Service(name: "CrowdStrike", operations: CrowdStrike.operations, detection: CrowdStrike.adapter, containment: CrowdStrike.containmentAdapter,
                detectionTools: ["hosts", "host", "alerts", "alert", "rtr-sessions", "host-groups", "container-images", "users", "prevention-policies",
                                 "exclusions", "security-events", "check-access"],
                containmentTools: ["host", "action-status", "contain-host", "lift-containment", "block-ioc", "unblock-ioc", "rtr-kill-process", "close-alert",
                                   "update-alert-status", "check-access"],
                detectionRequests: 8, containmentRequests: 2),
        Service(name: "SentinelOne", operations: SentinelOne.operations, detection: SentinelOne.adapter, containment: SentinelOne.containmentAdapter,
                detectionTools: ["agents", "agent", "threats", "threat", "activities", "activity-types", "sites", "groups", "exclusions", "security-events",
                                 "check-access"],
                containmentTools: ["agent", "threat", "action-status", "disconnect-agent", "reconnect-agent", "initiate-scan", "kill-threat",
                                   "quarantine-threat", "unquarantine-threat", "remediate-threat", "rollback-threat", "resolve-threat",
                                   "update-threat-status", "block-hash", "unblock-hash", "check-access"],
                detectionRequests: 4, containmentRequests: 2),
        Service(name: "Vercel", operations: Vercel.operations, detection: Vercel.adapter, containment: Vercel.containmentAdapter,
                detectionTools: ["deployments", "deployment-logs", "activity-log", "firewall-events", "security-events", "check-access", "members",
                                 "access-tokens", "integrations", "project-protection", "env-vars", "domains", "firewall-config"],
                containmentTools: ["project", "enable-attack-mode", "disable-attack-mode", "block-ip", "block-asn", "block-country", "unblock",
                                   "enable-protection", "remove-member", "rollback", "check-access"],
                detectionRequests: 4, containmentRequests: 2),
        Service(name: "Duo", operations: Duo.operations, detection: Duo.adapter, containment: Duo.containmentAdapter,
                detectionTools: ["auth-logs", "admin-logs", "telephony-logs", "user", "security-events", "check-access", "users", "admins",
                                 "integrations", "phones", "policies", "bypass-codes"],
                containmentTools: ["user", "disable-user", "enable-user", "clear-bypass", "delete-bypass-codes", "remove-phone", "remove-token",
                                   "remove-security-key", "send-enrollment", "send-activation", "check-access"],
                detectionRequests: 2, containmentRequests: 2),
        Service(name: "GitHub", operations: GitHub.operations, detection: GitHub.adapter, containment: GitHub.containmentAdapter,
                detectionTools: ["audit-log", "people", "teams", "security-alerts", "check-access", "org-settings", "members-without-2fa",
                                 "app-installations", "webhooks", "repo-security", "deploy-keys", "fine-grained-tokens", "actions-settings",
                                 "credential-authorizations"],
                containmentTools: ["remove-member", "reinstate-member", "remove-outside-collaborator", "restore-collaborator", "cancel-invitation",
                                   "block-user", "unblock-user", "demote-owner", "restore-owner", "remove-from-team", "restore-team-membership",
                                   "revoke-fine-grained-token", "delete-deploy-key", "restore-deploy-key", "disable-webhook", "enable-webhook",
                                   "revoke-sso-credential", "disable-actions", "enable-actions", "cancel-workflow-run", "report-leaked-token",
                                   "check-access", "undo-records"],
                detectionRequests: 8, containmentRequests: 2, watched: "security-alerts"),
    ]

    private let connection = try! ToolConnection(name: "Any", endpoint: URL(string: "https://api.example.com")!, tokenHeader: "x-api-key", adapter: "any")

    private func tools(_ adapter: OperationAdapter) async throws -> [String] {
        let list = try JSONSerialization.jsonObject(with: try await adapter.tools(for: connection)) as? [String: Any]
        return (list?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// An operation left out of its service's list would be in no tool, so the list is checked against every
    /// operation the service's files declare.
    func testEveryOperationIsInItsServicesListAndNamesTheJobsItServes() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Sources/PionCore/Adapters").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let declaration = try NSRegularExpression(pattern: #"struct (\w+): ServiceOperation\b"#)
        for service in Self.services {
            var declared: Set<String> = []
            for file in files where file.hasPrefix(service.name) && file.hasSuffix(".swift") {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    declared.insert((text as NSString).substring(with: match.range(at: 1)))
                }
            }
            let listed = service.operations.map { String(describing: type(of: $0)) }
            XCTAssertFalse(declared.isEmpty, service.name)
            XCTAssertEqual(Set(listed), declared, service.name)
            XCTAssertEqual(listed.count, Set(listed).count, "\(service.name) lists an operation twice")
            for operation in service.operations {
                let kind = type(of: operation)
                XCTAssertFalse(kind.jobs.isEmpty, "\(service.name) \(kind.name)")
                XCTAssertTrue(ToolJob.detection.offers(kind.jobs) || ToolJob.containment.offers(kind.jobs), "\(service.name) \(kind.name) is in no tool")
                // A read-only tool never offers what changes something.
                if !kind.readOnly { XCTAssertEqual(kind.jobs, [.containment], "\(service.name) \(kind.name)") }
            }
        }
    }

    /// The tools offer exactly what they did when each had a list of its own, each name once, watched and paced as before.
    func testEachToolOffersTheOperationsOfItsJob() async throws {
        for service in Self.services {
            let detection = try await tools(service.detection), containment = try await tools(service.containment)
            XCTAssertEqual(Set(detection), service.detectionTools, "\(service.name) Detection")
            XCTAssertEqual(Set(containment), service.containmentTools, "\(service.name) Containment")
            XCTAssertEqual(detection.count, Set(detection).count, "\(service.name) Detection offers a name twice")
            XCTAssertEqual(containment.count, Set(containment).count, "\(service.name) Containment offers a name twice")
            XCTAssertEqual(service.detection.watchedTool, service.watched, service.name)
            XCTAssertNil(service.containment.watchedTool, service.name)
            XCTAssertEqual(service.detection.simultaneousRequests, service.detectionRequests, service.name)
            XCTAssertEqual(service.containment.simultaneousRequests, service.containmentRequests, service.name)
        }
    }

    func testDetectionKeepsAuditReadsButNotThoseContainmentShares() {
        XCTAssertTrue(ToolJob.detection.offers([.detection]))
        XCTAssertTrue(ToolJob.detection.offers([.detection, .audit]))
        XCTAssertTrue(ToolJob.detection.offers([.audit]))
        XCTAssertFalse(ToolJob.detection.offers([.audit, .containment]))
        XCTAssertFalse(ToolJob.detection.offers([.containment]))
        XCTAssertTrue(ToolJob.containment.offers([.audit, .containment]))
        XCTAssertFalse(ToolJob.containment.offers([.detection, .audit]))
        XCTAssertTrue(ToolJob.audit.offers([.detection, .audit]))
        XCTAssertFalse(ToolJob.audit.offers([.detection]))
    }

    /// Where a tool's sign-in names its scopes, Detection's only read.
    func testDetectionSignsInOnlyToRead() throws {
        guard case .connection(let workspace) = GoogleWorkspace.preset.configuration, let oauth = workspace.oauth else { return XCTFail("no sign-in") }
        XCTAssertTrue(oauth.scopes.allSatisfy { $0.hasSuffix(".readonly") }, "\(oauth.scopes)")
        XCTAssertTrue(Entra.auditScopes.allSatisfy { $0.contains(".Read.") }, "\(Entra.auditScopes)")
        XCTAssertTrue(Defender.auditScopes.allSatisfy { $0.contains(".Read") && !$0.contains("Write") }, "\(Defender.auditScopes)")
        XCTAssertTrue(Okta.auditScopes.allSatisfy { $0.hasSuffix(".read") || $0.hasSuffix(".read.self") }, "\(Okta.auditScopes)")
        XCTAssertTrue(CrowdStrike.auditScopes.allSatisfy { $0.access == "Read" }, "\(CrowdStrike.auditScopes)")
        // A GitHub App takes no scopes: Detection's App holds only read permissions.
        XCTAssertTrue(GitHub.detectionPermissions.allSatisfy { !$0.write }, "\(GitHub.detectionPermissions.map(\.title))")
    }

    /// Every read of each Google Workspace tool is run against a service that answers everything, and each request it
    /// sends must be one a scope of that tool's own sign-in allows, so a read moved into Detection that needs
    /// Containment's scopes, such as an account's tokens, fails here rather than for the champion.
    func testWorkspaceReadsAskOnlyForWhatTheirToolsSignInAllows() async throws {
        for (preset, job) in [(GoogleWorkspace.preset, ToolJob.detection), (GoogleWorkspace.containment, .containment)] {
            guard case .connection(let configuration) = preset.configuration, let oauth = configuration.oauth else { return XCTFail(preset.name) }
            let connection = try preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
            for operation in GoogleWorkspace.operations where job.offers(type(of: operation).jobs) && type(of: operation).readOnly {
                let name = type(of: operation).name
                let service = AnswersEverything()
                // mail-trace requires none of its fields, but at least one of what names a message.
                let given = name == "mail-trace" ? ["sender": "m.okafor@kestrel.example"] : Self.example(type(of: operation).input, named: "")
                let input = try JSONSerialization.data(withJSONObject: given)
                _ = try await OperationAdapter(operations: [operation]).run(name, arguments: input, connection: connection, access: service)
                XCTAssertFalse(service.requests.isEmpty, "\(preset.name) \(name) sent nothing to check")
                for request in service.requests {
                    let allowing = Self.workspaceScopes(allowing: request)
                    XCTAssertFalse(allowing.isDisjoint(with: oauth.scopes),
                                   "\(preset.name) \(name) reads \(request.url?.path ?? "?"), which takes one of \(allowing.sorted())")
                }
            }
        }
    }

    /// A service that answers every request with an empty object, recording each.
    private final class AnswersEverything: ServiceAccess, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { sent } }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { sent.append(request) }
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// An input an operation takes: each required field with a value of its kind.
    private static func example(_ schema: JSONSchema, named name: String) -> Any {
        switch schema {
        case .string(_, let values): values?.first ?? (name == "ip" ? "192.0.2.1" : "m.okafor@kestrel.example")
        case .integer(_, let minimum, _): minimum ?? 1
        case .boolean: false
        case .array(let items, _): [example(items, named: name)]
        case .object(let properties, let required, _):
            Dictionary(uniqueKeysWithValues: required.compactMap { key in properties[key].map { (key, example($0, named: key)) } })
        }
    }

    /// The scopes, any one of which Google's Admin SDK reference says allows a read: the audit reports, users,
    /// their sessions, apps and app passwords, admin roles, groups, mobile devices and domains; and Cloud Identity's
    /// reference, its policies. None for any other.
    private static func workspaceScopes(allowing request: URLRequest) -> Set<String> {
        let auth = "https://www.googleapis.com/auth/"
        let parts = (request.url?.path ?? "").split(separator: "/").map(String.init)
        func either(_ scope: String) -> Set<String> { [auth + scope, auth + scope + ".readonly"] }
        guard request.httpMethod == "GET" else { return [] }
        if request.url?.host == "cloudidentity.googleapis.com" {
            if parts == ["v1", "policies"] { return either("cloud-identity.policies") }
            return []
        }
        if parts.starts(with: ["admin", "reports", "v1"]) { return [auth + "admin.reports.audit.readonly"] }
        guard parts.starts(with: ["admin", "directory", "v1"]) else { return [] }
        if parts.contains("tokens") || parts.contains("asps") { return [auth + "admin.directory.user.security"] }
        if parts.contains("mobile") { return either("admin.directory.device.mobile").union([auth + "admin.directory.device.mobile.action"]) }
        if parts.contains("roles") || parts.contains("roleassignments") || parts.contains("privileges") { return either("admin.directory.rolemanagement") }
        if parts.contains("domains") { return either("admin.directory.domain") }
        if parts.contains("groups") { return either("admin.directory.group") }
        if parts.contains("users") { return either("admin.directory.user") }
        return []
    }
}
