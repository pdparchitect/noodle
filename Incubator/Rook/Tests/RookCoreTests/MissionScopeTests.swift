import Foundation
@testable import RookCore
import XCTest

final class MissionScopeTests: XCTestCase {
    private var root: URL!
    private var store: RookStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MissionScopeTests-\(UUID().uuidString)", isDirectory: true)
        store = RookStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func open() throws -> Mission {
        try store.open(id: UUID(), title: "External test", objective: "Find a way into the customer portal", champion: "Avery")
    }

    func testRulesAreReadOnePerLineAndWrittenTheSameWayEveryTime() throws {
        let scope = try MissionScope.parse("""
             *.Target.COM
            target.com

            203.0.113.0/24
            DENY   Payments.target.com
            2001:db8::/32
            2001:DB8::7
            target.com
            intranet
            """)
        XCTAssertEqual(scope, ["*.target.com", "target.com", "203.0.113.0/24", "deny payments.target.com",
                               "2001:db8::/32", "2001:db8::7", "intranet"])
        XCTAssertEqual(try scope.map { try ScopeRule($0).isExcluded }, [false, false, false, true, false, false, false])
        XCTAssertEqual(try ScopeRule("*.target.com").target, .subdomains(of: "target.com"))
        XCTAssertEqual(try ScopeRule("203.0.113.9").target, .address("203.0.113.9"))
        XCTAssertEqual(try ScopeRule("203.0.113.0/24").target, .network("203.0.113.0", prefix: 24))
        XCTAssertEqual(try MissionScope.parse(" \n\n"), [])
    }

    func testWhatIsNotADomainAddressOrNetworkIsRefusedWithItsLine() {
        for line in ["https://target.com/login", "target.com:443", "foo bar", "*.", "*foo.com", "*.*.target.com",
                     "10.0.0/8", "10.0.0.0/33", "2001:db8::/129", "10.0.0", "-target.com", "target..com", "deny", "allow target.com"] {
            XCTAssertThrowsError(try MissionScope.parse("target.com\n\(line)"), line) { error in
                XCTAssertTrue(error.localizedDescription.contains("Line 2"), "\(line): \(error.localizedDescription)")
            }
        }
    }

    func testOnlyTheChampionSetsTheScopeAndEachChangeIsAudited() throws {
        let mission = try open()
        XCTAssertEqual(mission.scope, [])
        XCTAssertThrowsError(try store.setScope(["*.target.com"], of: mission.id, by: .agent(UUID())))
        XCTAssertThrowsError(try store.setScope(["not a target"], of: mission.id, by: .champion("Avery")))
        try store.setScope(["*.target.com", "deny payments.target.com"], of: mission.id, by: .champion("Avery"))
        try store.setScope(["*.target.com", "deny payments.target.com"], of: mission.id, by: .champion("Avery"))
        XCTAssertEqual(store.mission(mission.id)?.scope, ["*.target.com", "deny payments.target.com"])
        try store.setScope([], of: mission.id, by: .champion("Avery"))
        XCTAssertEqual(store.mission(mission.id)?.scope, [])
        XCTAssertEqual(store.audit(mission.id).filter { $0.event == "scope" }.map(\.detail),
                       ["Set the scope: *.target.com, deny payments.target.com.", "Cleared the scope."])
    }

    func testAMissionSavedBeforeScopesHasNone() throws {
        let mission = try open()
        let url = store.folder(mission.id).appendingPathComponent("mission.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(object["scopeRules"], "an empty scope is not written")
        XCTAssertEqual(store.mission(mission.id)?.scope, [])
    }

    /// The group's description is what every member is told the group is for, so the scope travels with the objective.
    func testAgentsAreToldTheScopeWithTheObjective() throws {
        XCTAssertEqual(MissionScope.groupDescription(objective: "Get in", scope: []), "Get in")
        let described = MissionScope.groupDescription(objective: "Get in",
                                                      scope: ["*.target.com", "203.0.113.0/24", "deny payments.target.com"])
        XCTAssertEqual(described, """
            Get in

            In scope, set by the champion:
            - *.target.com
            - 203.0.113.0/24

            Out of scope, even where an in-scope rule covers it:
            - payments.target.com
            """)

        var mission = try open()
        let unset = CaseToolProvider.describe(mission, CaseRecord(), lead: nil) { _ in nil }
        XCTAssertTrue(unset.contains("Scope: none set yet. Ask the champion what is in scope before you go near a target."), unset)
        mission.scope = ["*.target.com", "deny payments.target.com"]
        let set = CaseToolProvider.describe(mission, CaseRecord(), lead: nil) { _ in nil }
        XCTAssertTrue(set.contains("In scope, set by the champion:\n- *.target.com"), set)
        XCTAssertTrue(set.contains("Out of scope, even where an in-scope rule covers it:\n- payments.target.com"), set)
    }
}

final class MissionExceptionsTests: XCTestCase {
    private var root: URL!
    private var store: RookStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MissionExceptionsTests-\(UUID().uuidString)", isDirectory: true)
        store = RookStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Exceptions open services for lookups; they are never targets, so they take no deny lines.
    func testExceptionsOnlyOpenAndOnlyTheChampionSetsThem() throws {
        XCTAssertEqual(try MissionScope.parseExceptions(" Crt.sh \nshodan.io\n\n8.8.8.8"), ["crt.sh", "shodan.io", "8.8.8.8"])
        XCTAssertThrowsError(try MissionScope.parseExceptions("crt.sh\ndeny shodan.io")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Line 2"), error.localizedDescription)
        }
        let mission = try store.open(id: UUID(), title: "External test", objective: "Get in", champion: "Avery")
        XCTAssertEqual(mission.exceptions, [])
        XCTAssertThrowsError(try store.setExceptions(["crt.sh"], of: mission.id, by: .agent(UUID())))
        XCTAssertThrowsError(try store.setExceptions(["deny crt.sh"], of: mission.id, by: .champion("Avery")))
        try store.setExceptions(["crt.sh"], of: mission.id, by: .champion("Avery"))
        try store.setExceptions([], of: mission.id, by: .champion("Avery"))
        XCTAssertEqual(store.audit(mission.id).filter { $0.event == "exceptions" }.map(\.detail),
                       ["Opened services: crt.sh.", "Closed the opened services."])
    }

    /// Agents are told services exist, never which, so none is taken for a target.
    func testAgentsAreToldServicesAreOpenButNotWhich() {
        let described = MissionScope.groupDescription(objective: "Get in", scope: ["*.target.com"], exceptions: ["crt.sh"])
        XCTAssertTrue(described.contains("Some services outside the scope can also be reached from this Mission's computers"), described)
        XCTAssertFalse(described.contains("crt.sh"))
        XCTAssertEqual(MissionScope.groupDescription(objective: "Get in", scope: [], exceptions: []), "Get in")
    }
}

final class MissionLogTests: XCTestCase {
    /// Gateway logs land in the Mission's own folder, so its export carries them; only plain file names are taken.
    func testLogsAppendToTheMissionFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MissionLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RookStore(root: root)
        let mission = try store.open(id: UUID(), title: "External test", objective: "Get in", champion: "Avery")
        try store.appendLog(["{\"a\":1}", "{\"a\":2}"], to: "network.log", in: mission.id)
        try store.appendLog(["{\"a\":3}"], to: "network.log", in: mission.id)
        try store.appendLog([], to: "dns.log", in: mission.id)
        let text = try String(contentsOf: store.folder(mission.id).appendingPathComponent("network.log"), encoding: .utf8)
        XCTAssertEqual(text, "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n")
        XCTAssertThrowsError(try store.appendLog(["x"], to: "../escape.log", in: mission.id))
    }
}
