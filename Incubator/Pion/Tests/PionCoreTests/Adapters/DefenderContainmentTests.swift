import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class DefenderContainmentTests: XCTestCase {
    private let tenant = try! Defender.containment.makeConnection(name: "Defender Containment — Contoso",
                                                                 values: ["tenant": "contoso.onmicrosoft.com", "clientID": EntraTests.client])
    private let laptop = "1e5bc9d7e413ddd7902c2932e418702b84d0cc07", server = "2e5bc9d7e413ddd7902c2932e418702b84d0cc07"
    private let action = "7b419894-4d22-4624-a699-5df62b3ab681"
    private let sha1 = "0123456789abcdef0123456789abcdef01234567"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await Defender.$pauses.withValue([0, 0]) { try await callTool(Defender.containmentAdapter, tool, arguments, on: service, in: tenant) }
    }

    /// The changes a call sent: every request but a read.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
    }

    private func body(_ service: FakeService) -> [String: Any] {
        service.requests.last { $0.httpMethod == "POST" }?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func machine(_ id: String, health: String = "Active", onboarding: String = "onboarded") -> (Int, String) {
        (200, #"{"id":"\#(id)","computerDnsName":"lt-0423.contoso.com","healthStatus":"\#(health)","onboardingStatus":"\#(onboarding)","osPlatform":"Windows11","riskScore":"High","exposureLevel":"Medium","rbacGroupName":"Laptops","lastSeen":"2026-11-23T08:00:00Z","lastIpAddress":"10.0.0.7","machineTags":["VIP"]}"#)
    }

    private func machineAction(_ id: String, _ type: String, _ status: String, device: String? = nil, at: String = "2026-11-23T09:00:00Z", scope: String? = nil,
                               file: String? = nil, fileType: String = "Sha1") -> String {
        let related = file.map { #","relatedFileInfo":{"fileIdentifier":"\#($0)","fileIdentifierType":"\#(fileType)"}"# } ?? ""
        return #"{"id":"\#(id)","type":"\#(type)","status":"\#(status)","machineId":"\#(device ?? laptop)","computerDnsName":"lt-0423.contoso.com","requestor":"someone@contoso.example","requestorComment":"earlier","creationDateTimeUtc":"\#(at)","lastUpdateDateTimeUtc":"\#(at)"\#(scope.map { #","scope":"\#($0)""# } ?? "")\#(related)}"#
    }

    /// A tenant with an active onboarded laptop with no history, whose every action Defender takes as Pending, then Succeeded.
    private func service(history: [String] = []) -> FakeService {
        let service = FakeService()
        service.answers["/api/machines/\(laptop)"] = machine(laptop)
        service.answers["/api/machineactions"] = (200, #"{"value":[\#(history.joined(separator: ","))]}"#)
        for act in Defender.Act.allCases {
            service.answers["/api/machines/\(laptop)/\(act.endpoint)"] = (201, machineAction(action, act.rawValue, "Pending", at: "2026-11-23T10:00:00Z",
                                                                                               file: act == .quarantine ? sha1 : nil))
        }
        return service
    }

    func testContainmentIsItsOwnToolWithASignInOfItsOwnToTheDefenderForEndpointAPI() throws {
        XCTAssertEqual(Defender.containment.name, "Microsoft Defender XDR Containment")
        XCTAssertNotEqual(Defender.containment.id, Defender.preset.id)
        XCTAssertNotNil(UUID(uuidString: Defender.containment.id))
        XCTAssertEqual(tenant.endpoint.absoluteString, "https://api.security.microsoft.com")
        XCTAssertEqual(tenant.adapter, "defender-containment")
        XCTAssertNotNil(PionAdapters.all["defender-containment"])
        XCTAssertNil(Defender.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == Defender.containment.id })
        XCTAssertNil(tenant.clientCredentials)
        guard case .connection(let configuration) = Defender.containment.configuration, case .connection(let audit) = Defender.preset.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.oauthPathField, "tenant")
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        let oauth = try XCTUnwrap(configuration.oauth(for: tenant.settings))
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(oauth.unlistedScopes, ["offline_access"])
        XCTAssertEqual(oauth.scopes, Defender.containmentPermissions.map { "https://api.securitycenter.microsoft.com/" + $0 },
                       "every scope is for the one resource Defender for Endpoint's tokens must name")
        XCTAssertTrue(Set(oauth.scopes).isDisjoint(with: Set(audit.oauth!.scopes)), "a grant of its own, apart from Audit's read-only one")
        XCTAssertFalse(oauth.scopes.contains { $0.contains("LiveResponse") || $0.contains("Offboard") || $0.hasSuffix(".All") }, "nothing broader than its actions take")
        XCTAssertTrue(Defender.containmentSetup.contains { $0.contains("WindowsDefenderATP") && $0.contains("Delegated permissions") })
        XCTAssertTrue(Defender.containmentPermissions.allSatisfy { permission in Defender.containmentSetup.contains { $0.contains("`\(permission)`") } })
        for role in ["**Response (manage)**", "**Active remediation actions**", "**Alerts investigation**", "Never make the admin a Global or Security Administrator"] {
            XCTAssertTrue(Defender.containmentSetup.contains { $0.contains(role) }, role)
        }
    }

    /// Every action is held for approval and says what recovering from it involves; the reads are not held.
    func testEveryActionIsHeldForApprovalAndSaysHowToRecover() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await Defender.containmentAdapter.tools(for: tenant)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        func tool(_ name: String) throws -> [String: Any] { try XCTUnwrap(tools.first { $0["name"] as? String == name }, name) }
        let recovery: [String: [String]] = [
            "isolate-device": ["release-isolation restores the device's network access", "must be asked for explicitly", "minutes to apply"],
            "release-isolation": ["isolate-device again", "an attacker's still on it"],
            "restrict-app-execution": ["remove-app-restriction lets every app run again", "signed by Microsoft"],
            "remove-app-restriction": ["restrict-app-execution again", "any app run again"],
            "stop-and-quarantine-file": ["loses their in-memory state", "cannot be undone", "quarantined file can be restored"],
            "run-av-scan": ["changes nothing on the device's state", "processor and disk", "may quarantine files"],
            "collect-investigation-package": ["changes nothing on the device's state", "uses its resources"],
        ]
        for (name, words) in recovery {
            let annotations = try XCTUnwrap(try tool(name)["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, true, name)
            let summary = try XCTUnwrap(try tool(name)["description"] as? String)
            XCTAssertTrue(summary.contains("Recovery:"), name)
            for word in words { XCTAssertTrue(summary.contains(word), "\(name) says \(word): \(summary)") }
            let schema = try XCTUnwrap(try tool(name)["inputSchema"] as? [String: Any])
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []).isSuperset(of: ["device", "comment"]), true, "\(name) takes a comment")
        }
        for name in ["device", "machine-actions", "action-status", "check-access"] {
            XCTAssertEqual((try tool(name)["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, name)
        }
        XCTAssertEqual(tools.count, recovery.count + 4)
    }

    /// An accepted request is not a done one: Pending is reported as Pending, with the machine action's ID, after
    /// reading it again, and the comment carries the approval's reason.
    func testIsolatingReportsTheMachineActionAndPendingHonestly() async throws {
        let service = service()
        service.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "Isolate", "Pending", at: "2026-11-23T10:00:00Z"))
        let isolated = try await call("isolate-device", #"{"device":"\#(laptop.uppercased())","comment":"Ransomware on lt-0423, INV-12: approved by the champion","isolationType":"Selective"}"#, service)
        XCTAssertFalse(isolated.isError, isolated.text)
        XCTAssertEqual(changes(service), ["POST /api/machines/\(laptop)/isolate"])
        XCTAssertEqual(body(service)["IsolationType"] as? String, "Selective")
        XCTAssertEqual(body(service)["Comment"] as? String, "Requested through Pion after the champion's approval: Ransomware on lt-0423, INV-12: approved by the champion")
        for words in ["machine action \(action)", "Pending: the device has not carried it out yet, so it is not done", "Pending is not Succeeded: poll it with action-status \(action)",
                      "minutes to apply", "release-isolation restores", "was read at"] {
            XCTAssertTrue(isolated.text.contains(words), "\(words): \(isolated.text)")
        }
        XCTAssertEqual(isolated.structured?["done"] as? Bool, false)
        XCTAssertEqual(isolated.structured?["action"] as? String, action)
        XCTAssertEqual(service.requests.filter { $0.url?.path == "/api/machineactions/\(action)" }.count, 2, "read again after each pause")
    }

    func testSucceededIsDoneAndFailedIsAnErrorThatGivesTheID() async throws {
        let service = service()
        service.sequences["/api/machineactions/\(action)"] = [(200, machineAction(action, "RunAntiVirusScan", "InProgress")), (200, machineAction(action, "RunAntiVirusScan", "Succeeded"))]
        let scanned = try await call("run-av-scan", #"{"device":"\#(laptop)","comment":"Scan after the alert, INV-12","scanType":"Full"}"#, service)
        XCTAssertFalse(scanned.isError, scanned.text)
        XCTAssertTrue(scanned.text.contains("Succeeded: done") && !scanned.text.contains("Pending is not Succeeded"), scanned.text)
        XCTAssertEqual(scanned.structured?["done"] as? Bool, true)
        XCTAssertEqual(body(service)["ScanType"] as? String, "Full")
        let failing = self.service()
        failing.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "CollectInvestigationPackage", "Failed"))
        let failed = try await call("collect-investigation-package", #"{"device":"\#(laptop)","comment":"Forensics for INV-12"}"#, failing)
        XCTAssertTrue(failed.isError && failed.text.contains("Failed: not done") && failed.text.contains(action), failed.text)
        let unread = self.service()
        unread.answers["/api/machineactions/\(action)"] = (503, #"{"error":{"code":"ServiceUnavailable","message":"Try later"}}"#)
        let unknown = try await call("restrict-app-execution", #"{"device":"\#(laptop)","comment":"Contain INV-12"}"#, unread)
        XCTAssertFalse(unknown.isError, unknown.text)
        XCTAssertTrue(unknown.text.contains("could not be read again") && unknown.text.contains("Pending"), unknown.text)
    }

    /// Each action goes to its own path, with only its own fields.
    func testEachActionPostsToItsOwnPathWithItsBody() async throws {
        let cases: [(String, String, String, Set<String>)] = [
            ("isolate-device", "", "isolate", ["Comment", "IsolationType"]),
            ("restrict-app-execution", "", "restrictCodeExecution", ["Comment"]),
            ("stop-and-quarantine-file", #","sha1":"\#(sha1.uppercased())""#, "StopAndQuarantineFile", ["Comment", "Sha1"]),
            ("run-av-scan", "", "runAntiVirusScan", ["Comment", "ScanType"]),
            ("collect-investigation-package", "", "collectInvestigationPackage", ["Comment"]),
        ]
        for (tool, extra, path, fields) in cases {
            let service = service()
            let act = try XCTUnwrap(Defender.Act.allCases.first { $0.endpoint == path })
            service.answers["/api/machineactions/\(action)"] = (200, machineAction(action, act.rawValue, "Succeeded", file: act == .quarantine ? sha1.uppercased() : nil))
            let result = try await call(tool, #"{"device":"\#(laptop)","comment":"Contain INV-12"\#(extra)}"#, service)
            XCTAssertFalse(result.isError, "\(tool): \(result.text)")
            XCTAssertEqual(changes(service), ["POST /api/machines/\(laptop)/\(path)"], tool)
            XCTAssertEqual(Set(body(service).keys), fields, tool)
        }
        let service = service(history: [machineAction("a0", "Isolate", "Succeeded", scope: "Full"), machineAction("a1", "RestrictCodeExecution", "Succeeded")])
        service.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "Unisolate", "Succeeded"))
        let released = try await call("release-isolation", #"{"device":"\#(laptop)","comment":"Clean, INV-12"}"#, service)
        XCTAssertFalse(released.isError, released.text)
        XCTAssertEqual(changes(service), ["POST /api/machines/\(laptop)/unisolate"])
        service.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "UnrestrictCodeExecution", "Succeeded"))
        let lifted = try await call("remove-app-restriction", #"{"device":"\#(laptop)","comment":"Clean, INV-12"}"#, service)
        XCTAssertFalse(lifted.isError, lifted.text)
        XCTAssertEqual(body(service)["Sha1"] as? String, nil)
        let quarantined = self.service()
        quarantined.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "StopAndQuarantineFile", "Succeeded", file: sha1))
        _ = try await call("stop-and-quarantine-file", #"{"device":"\#(laptop)","comment":"INV-12","sha1":"\#(sha1.uppercased())"}"#, quarantined)
        XCTAssertEqual(body(quarantined)["Sha1"] as? String, sha1)
    }

    /// Nothing is sent for a malformed ID, a device not found, not onboarded or not active, an action of the same
    /// kind or its opposite pending, isolating what is isolated or releasing what is not, or without a comment.
    func testItRefusesWhatAnActionMustNotGoAheadOn() async throws {
        func refused(_ tool: String, _ arguments: String, _ service: FakeService, _ words: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            let result = try await call(tool, arguments, service)
            XCTAssertTrue(result.isError, "\(tool) \(arguments): \(result.text)", file: file, line: line)
            XCTAssertTrue(result.text.contains(words), "\(words): \(result.text)", file: file, line: line)
            XCTAssertTrue(result.text.hasPrefix("Nothing was changed"), result.text, file: file, line: line)
            XCTAssertTrue(changes(service).isEmpty, "\(tool) sent \(changes(service))", file: file, line: line)
        }
        let plain = service()
        for bad in ["1e5bc9d7", "../machines", "\(laptop)/isolate", "zz5bc9d7e413ddd7902c2932e418702b84d0cc07", ""] {
            try await refused("isolate-device", #"{"device":"\#(bad)","comment":"INV-12"}"#, plain, "40-character Defender for Endpoint ID")
        }
        XCTAssertTrue(plain.requests.isEmpty, "a malformed ID reads nothing either")
        try await refused("isolate-device", #"{"device":"\#(laptop)","comment":"  "}"#, plain, "give a comment")
        try await refused("isolate-device", #"{"device":"\#(laptop)","comment":"\#(String(repeating: "x", count: 900))"}"#, plain, "give a comment")
        try await refused("stop-and-quarantine-file", #"{"device":"\#(laptop)","comment":"INV-12","sha1":"abc"}"#, plain, "SHA1")
        try await refused("isolate-device", #"{"device":"\#(server)","comment":"INV-12"}"#, plain, "has no device \(server)")
        let other = service()
        other.answers["/api/machines/\(laptop)"] = machine(server)
        try await refused("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, other, "answered for device \(server)")
        let inactive = service()
        inactive.answers["/api/machines/\(laptop)"] = machine(laptop, health: "Inactive")
        try await refused("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, inactive, "is not active (health Inactive")
        let unonboarded = service()
        unonboarded.answers["/api/machines/\(laptop)"] = machine(laptop, onboarding: "CanBeOnboarded")
        try await refused("run-av-scan", #"{"device":"\#(laptop)","comment":"INV-12"}"#, unonboarded, "is not onboarded")
        let pending = service(history: [machineAction("p1", "Isolate", "Pending"), machineAction("p2", "RestrictCodeExecution", "InProgress"),
                                        machineAction("p3", "RunAntiVirusScan", "Pending", device: server)])
        try await refused("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, pending, "already Pending: machine action p1")
        try await refused("release-isolation", #"{"device":"\#(laptop)","comment":"INV-12"}"#, pending, "the two would race")
        try await refused("remove-app-restriction", #"{"device":"\#(laptop)","comment":"INV-12"}"#, pending, "the two would race")
        let scan = try await call("run-av-scan", #"{"device":"\#(laptop)","comment":"INV-12"}"#, pending)
        XCTAssertFalse(scan.isError, "another device's pending scan is not this one's: \(scan.text)")
        let isolated = service(history: [machineAction("i1", "Isolate", "Succeeded", at: "2026-11-22T09:00:00Z", scope: "Full")])
        try await refused("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, isolated, "the last observed isolation action on lt-0423.contoso.com [\(laptop)] isolated it")
        let released = service(history: [machineAction("i1", "Isolate", "Succeeded", at: "2026-11-22T09:00:00Z"), machineAction("u1", "Unisolate", "Succeeded", at: "2026-11-22T10:00:00Z")])
        try await refused("release-isolation", #"{"device":"\#(laptop)","comment":"INV-12"}"#, released, "released it (u1)")
        let lifted = service(history: [machineAction("r1", "RestrictCodeExecution", "Succeeded", at: "2026-11-22T09:00:00Z"), machineAction("r2", "UnrestrictCodeExecution", "Succeeded", at: "2026-11-22T10:00:00Z")])
        try await refused("remove-app-restriction", #"{"device":"\#(laptop)","comment":"INV-12"}"#, lifted, "lifted the restriction (r2)")
        let unreadable = service()
        unreadable.answers["/api/machineactions"] = (403, #"{"error":{"code":"Forbidden","message":"Missing permission."}}"#)
        let blind = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, unreadable)
        XCTAssertTrue(blind.isError && blind.text.contains("Machine.ReadWrite") && changes(unreadable).isEmpty, "whether one is pending is never guessed: \(blind.text)")
    }

    /// An answer Pion cannot read, or one for another action or device, is never taken for success.
    func testAnAnswerThatIsNotTheActionAskedForIsNeverSuccess() async throws {
        let garbled = service()
        garbled.answers["/api/machines/\(laptop)/isolate"] = (201, #"{"status":"Pending"}"#)
        let unknown = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, garbled)
        XCTAssertTrue(unknown.isError && unknown.text.contains("whether it took it is not known"), unknown.text)
        let other = service()
        other.answers["/api/machines/\(laptop)/isolate"] = (201, machineAction(action, "Isolate", "Pending", device: server))
        let wrong = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, other)
        XCTAssertTrue(wrong.isError && wrong.text.contains("could not be verified: Defender's answer names device \(server)") && wrong.text.contains(action), wrong.text)
        XCTAssertFalse(wrong.text.contains("Succeeded: done"))
        let refused = service()
        refused.answers["/api/machines/\(laptop)/isolate"] = (400, #"{"error":{"code":"ActiveRequestAlreadyExists","message":"Action is already in progress"}}"#)
        let busy = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, refused)
        XCTAssertTrue(busy.isError && busy.text.contains("Action is already in progress"), busy.text)
        let denied = service()
        denied.answers["/api/machines/\(laptop)/isolate"] = (403, #"{"error":{"code":"Forbidden","message":"User has no permission to perform this action."}}"#)
        let noRole = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, denied)
        XCTAssertTrue(noRole.isError && noRole.text.contains("Machine.Isolate") && noRole.text.contains("Active remediation actions"), noRole.text)
    }

    func testActionStatusReadsOneActionByItsIDOnly() async throws {
        let service = service()
        service.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "Isolate", "Pending"))
        let status = try await call("action-status", #"{"id":"\#(action.uppercased())"}"#, service)
        XCTAssertFalse(status.isError, status.text)
        XCTAssertTrue(status.text.contains("Pending: the device has not carried it out yet, so it is not done"), status.text)
        XCTAssertEqual(status.structured?["done"] as? Bool, false)
        for bad in ["../machines", "not-a-guid", ""] {
            let refused = try await call("action-status", #"{"id":"\#(bad)"}"#, service)
            XCTAssertTrue(refused.isError, bad)
        }
        let other = "8b419894-4d22-4624-a699-5df62b3ab681"
        service.answers["/api/machineactions/\(other)"] = (200, machineAction(action, "Isolate", "Succeeded"))
        let mismatched = try await call("action-status", #"{"id":"\#(other)"}"#, service)
        XCTAssertTrue(mismatched.isError, mismatched.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "api.security.microsoft.com" && $0.httpMethod == "GET" })
    }

    func testMachineActionsSayWhoAskedAndWhyAndDeviceReadsStateWithoutChangingIt() async throws {
        let service = service(history: [machineAction("a0", "Isolate", "Succeeded", at: "2026-11-22T09:00:00Z", scope: "Full"),
                                        machineAction("a1", "LiveResponse", "Succeeded", at: "2026-11-23T09:00:00Z"),
                                        machineAction("a2", "RunAntiVirusScan", "Pending", at: "2026-11-23T09:30:00Z")])
        let since = Entra.iso(Date().addingTimeInterval(-3 * 86_400))
        let listed = try await call("machine-actions", #"{"device":"\#(laptop)","since":"\#(since)"}"#, service)
        XCTAssertFalse(listed.isError, listed.text)
        XCTAssertTrue(listed.text.contains("LiveResponse") && listed.text.contains("requested by someone@contoso.example") && listed.text.contains("\"earlier\""), listed.text)
        XCTAssertLessThan(listed.text.range(of: "[a2]")!.lowerBound, listed.text.range(of: "[a0]")!.lowerBound, "newest first")
        XCTAssertEqual(queryItems(service.requests.last)["$filter"], "machineId eq '\(laptop)' and creationDateTimeUtc ge \(since)")
        let device = try await call("device", #"{"device":"\#(laptop)"}"#, service)
        XCTAssertFalse(device.isError, device.text)
        for words in ["lt-0423.contoso.com [\(laptop)]", "health Active", "Onboarded and active", "Pending machine actions", "[a2]", "Last observed: Isolate (Full) succeeded",
                      "not its state verified", "Whether its apps are restricted could not be confirmed: no machine action on record restricted its apps"] {
            XCTAssertTrue(device.text.contains(words), "\(words): \(device.text)")
        }
        XCTAssertEqual(device.structured?["lastObservedIsolated"] as? Bool, true)
        XCTAssertNil(device.structured?["lastObservedRestricted"] as? Bool, "nothing on record is unknown, never false")
        XCTAssertEqual(device.structured?["pendingComplete"] as? Bool, true)
        XCTAssertTrue(changes(service).isEmpty)
    }

    /// The key FakeService answers the pending-action read with, apart from every other read of machine actions.
    private var pendingKey: String {
        EntraTests.key("/api/machineactions", ["$filter": "machineId eq '\(laptop)' and (status eq 'Pending' or status eq 'InProgress')", "$top": "200"])
    }

    /// Only a whole read of a device's pending actions shows none conflicts: one stopped at its page limit, or at a
    /// next page Pion will not follow, sends nothing, and device says it is unfinished.
    func testPendingActionsThatCouldNotAllBeReadBlockEveryAction() async throws {
        let endless = #"{"value":[],"@odata.nextLink":"https://api.security.microsoft.com/api/machineactions?$skip=200"}"#
        let elsewhere = #"{"value":[],"@odata.nextLink":"https://evil.example/api/machineactions?$skip=200"}"#
        for (page, why) in [(endless, "more than the 5 pages"), (elsewhere, "does not follow")] {
            let service = service()
            // Every page of every read of machine actions links to another.
            service.answers["/api/machineactions"] = (200, page)
            for (tool, extra) in [("isolate-device", ""), ("release-isolation", ""), ("run-av-scan", ""), ("stop-and-quarantine-file", #","sha1":"\#(sha1)""#)] {
                let result = try await call(tool, #"{"device":"\#(laptop)","comment":"INV-12"\#(extra)}"#, service)
                XCTAssertTrue(result.isError, "\(tool): \(result.text)")
                XCTAssertTrue(result.text.contains("not every pending machine action") && result.text.contains(why), result.text)
            }
            XCTAssertTrue(changes(service).isEmpty, "nothing sent: \(changes(service))")
            let device = try await call("device", #"{"device":"\#(laptop)"}"#, service)
            XCTAssertTrue(device.text.contains("Not every pending machine action could be read"), device.text)
            XCTAssertEqual(device.structured?["pendingComplete"] as? Bool, false)
        }
    }

    /// No isolation on record, or a history read only in part, is unknown, never "not isolated": release and isolate
    /// go ahead, saying the state before could not be confirmed.
    func testAStateThatCannotBeConfirmedIsUnknownAndBlocksNothing() async throws {
        let empty = service()
        empty.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "Unisolate", "Pending"))
        let released = try await call("release-isolation", #"{"device":"\#(laptop)","comment":"INV-12"}"#, empty)
        XCTAssertFalse(released.isError, released.text)
        XCTAssertTrue(released.text.contains("Whether the device was isolated before this could not be confirmed: no machine action on record isolated or released it"), released.text)
        XCTAssertEqual(changes(empty), ["POST /api/machines/\(laptop)/unisolate"])
        let state = try await Defender.state(of: laptop, ServiceClient(base: tenant.endpoint, access: empty, settings: tenant.settings ?? [:]))
        XCTAssertNil(state.isolated)
        XCTAssertNil(state.restricted)

        let partial = service(history: [machineAction("u1", "Unisolate", "Succeeded", at: "2026-11-22T10:00:00Z")])
        partial.answers[pendingKey] = (200, #"{"value":[]}"#)
        // Every other read of machine actions, the succeeded ones included, stops at a link Pion will not follow.
        partial.answers["/api/machineactions"] = (200, #"{"value":[\#(machineAction("u1", "Unisolate", "Succeeded", at: "2026-11-22T10:00:00Z"))],"@odata.nextLink":"https://evil.example/api/machineactions?$skip=1"}"#)
        partial.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "Unisolate", "Pending"))
        let anyway = try await call("release-isolation", #"{"device":"\#(laptop)","comment":"INV-12"}"#, partial)
        XCTAssertFalse(anyway.isError, "a release seen in part is no proof it is released: \(anyway.text)")
        XCTAssertTrue(anyway.text.contains("could not be confirmed: not every one of its succeeded machine actions could be read"), anyway.text)

        let tied = service(history: [machineAction("i1", "Isolate", "Succeeded", at: "2026-11-22T10:00:00Z"), machineAction("u1", "Unisolate", "Succeeded", at: "2026-11-22T10:00:00Z")])
        tied.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "Isolate", "Pending"))
        let isolated = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, tied)
        XCTAssertFalse(isolated.isError, isolated.text)
        XCTAssertTrue(isolated.text.contains("asked for at the same moment"), isolated.text)
    }

    /// Nothing is said done until Defender's answer names the same action, the device asked for, its type and the
    /// scope asked for: otherwise the result keeps the action's ID and says it could not be verified.
    func testAnActionIsConfirmedOnlyForTheDeviceTypeAndScopeAskedFor() async throws {
        let bare = #"{"id":"\#(action)","type":"Isolate","status":"Pending"}"#
        let unknownDevice = service()
        unknownDevice.answers["/api/machines/\(laptop)/isolate"] = (201, bare)
        unknownDevice.answers["/api/machineactions/\(action)"] = (503, #"{"error":{"code":"ServiceUnavailable","message":"Try later"}}"#)
        let unverified = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, unknownDevice)
        XCTAssertTrue(unverified.isError, unverified.text)
        XCTAssertTrue(unverified.text.contains("could not be verified: Defender's answer named no device") && unverified.text.contains(action) && unverified.text.contains("not reported done"), unverified.text)

        let filledIn = service()
        filledIn.answers["/api/machines/\(laptop)/isolate"] = (201, bare)
        filledIn.answers["/api/machineactions/\(action)"] = (200, machineAction(action, "Isolate", "Succeeded", scope: "Full"))
        let verified = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12"}"#, filledIn)
        XCTAssertFalse(verified.isError, "the device named once read again: \(verified.text)")
        XCTAssertEqual(verified.structured?["done"] as? Bool, true)

        let cases: [(String, (Int, String), String)] = [
            ("another device", (200, machineAction(action, "Isolate", "Succeeded", device: server)), "names device \(server)"),
            ("another type", (200, machineAction(action, "Unisolate", "Succeeded")), "Defender's answer is a Unisolate"),
            ("another scope", (200, machineAction(action, "Isolate", "Succeeded", scope: "Full")), "is Full, not the Selective asked for"),
        ]
        for (name, polled, words) in cases {
            let service = service()
            service.answers["/api/machineactions/\(action)"] = polled
            let result = try await call("isolate-device", #"{"device":"\#(laptop)","comment":"INV-12","isolationType":"Selective"}"#, service)
            XCTAssertTrue(result.isError, "\(name): \(result.text)")
            XCTAssertTrue(result.text.contains(words) && result.text.contains(action) && !result.text.contains("Succeeded: done"), "\(name): \(result.text)")
        }
        let scan = service()
        scan.answers["/api/machines/\(laptop)/runAntiVirusScan"] = (201, machineAction(action, "RunAntiVirusScan", "Pending", scope: "Quick"))
        let quick = try await call("run-av-scan", #"{"device":"\#(laptop)","comment":"INV-12","scanType":"Full"}"#, scan)
        XCTAssertTrue(quick.isError && quick.text.contains("is Quick, not the Full asked for"), quick.text)
    }

    /// A quarantine is said done only when Defender names the very SHA1 approved, on submission and on every read
    /// after; another file stops at once, and a file not named, or named by another kind of identifier, is read again
    /// and then said not verified, keeping the action's ID.
    func testAQuarantineIsConfirmedOnlyForTheFileApproved() async throws {
        let other = "fedcba9876543210fedcba9876543210fedcba98"
        let arguments = #"{"device":"\#(laptop)","comment":"INV-12","sha1":"\#(sha1)"}"#
        func run(_ acknowledged: String, _ polled: (Int, String)?) async throws -> (AdapterResult, FakeService) {
            let service = service()
            service.answers["/api/machines/\(laptop)/StopAndQuarantineFile"] = (201, acknowledged)
            if let polled { service.answers["/api/machineactions/\(action)"] = polled }
            return (try await call("stop-and-quarantine-file", arguments, service), service)
        }
        func polls(_ service: FakeService) -> Int { service.requests.filter { $0.url?.path == "/api/machineactions/\(action)" }.count }

        let (submitted, early) = try await run(machineAction(action, "StopAndQuarantineFile", "Succeeded", file: other), nil)
        XCTAssertTrue(submitted.isError && submitted.text.contains("names file \(other), not \(sha1)") && submitted.text.contains(action), submitted.text)
        XCTAssertEqual(polls(early), 0, "another file stops at once")

        let (polled, late) = try await run(machineAction(action, "StopAndQuarantineFile", "Pending", file: sha1),
                                           (200, machineAction(action, "StopAndQuarantineFile", "Succeeded", file: other.uppercased())))
        XCTAssertTrue(polled.isError && polled.text.contains("names file \(other), not \(sha1)") && !polled.text.contains("Succeeded: done"), polled.text)
        XCTAssertEqual(polls(late), 1)

        let (silent, quiet) = try await run(machineAction(action, "StopAndQuarantineFile", "Succeeded"),
                                            (200, machineAction(action, "StopAndQuarantineFile", "Succeeded")))
        XCTAssertTrue(silent.isError && silent.text.contains("Defender did not say which file; the outcome for \(sha1) could not be verified") && silent.text.contains(action), silent.text)
        XCTAssertEqual(polls(quiet), 2, "read again after each of the test's two pauses")

        let (named, _) = try await run(machineAction(action, "StopAndQuarantineFile", "Pending"),
                                       (200, machineAction(action, "StopAndQuarantineFile", "Succeeded", file: sha1.uppercased())))
        XCTAssertFalse(named.isError, named.text)
        XCTAssertEqual(named.structured?["done"] as? Bool, true)

        let (hashed, _) = try await run(machineAction(action, "StopAndQuarantineFile", "Succeeded", file: sha1, fileType: "Sha256"),
                                        (200, machineAction(action, "StopAndQuarantineFile", "Succeeded", file: sha1, fileType: "Sha256")))
        XCTAssertTrue(hashed.isError && hashed.text.contains("Defender did not say which file"), "another kind of identifier is no match: \(hashed.text)")
    }

    func testCheckAccessTriesTheReadsAndSaysWhatEachActionNeeds() async throws {
        let service = FakeService()
        service.answers["/api/machines"] = (200, #"{"value":[]}"#)
        service.answers["/api/machineactions"] = (403, #"{"error":{"code":"Forbidden","message":"Missing role permissions."}}"#)
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        for words in ["✓ Reading devices", "✗ Reading machine actions: either the app lacks the delegated permission Machine.ReadWrite", "The actions are not tried",
                      "Active remediation actions", "Alerts investigation", "offline_access"] {
            XCTAssertTrue(checked.text.contains(words), "\(words): \(checked.text)")
        }
        XCTAssertTrue(changes(service).isEmpty)
    }
}
