import Foundation
import NoodleAgentBridge
import XCTest

final class AgentHostIdentityTests: XCTestCase {
    private func bundle(team: Any?) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-agent-bridge-\(UUID()).bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var info: [String: Any] = ["CFBundleIdentifier": "com.pdparchitect.noodle.test-\(UUID())"]
        info["NoodleSigningTeam"] = team
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }

    func testRequirementPinsTheIdentifierToTheSigningTeam() throws {
        XCTAssertEqual(
            AgentHostIdentity.requirement(for: "com.pdparchitect.noodle.agent-host", bundle: try bundle(team: "AB12CD34EF")),
            "anchor apple generic and identifier \"com.pdparchitect.noodle.agent-host\" and certificate leaf[subject.OU] = \"AB12CD34EF\"")
    }

    func testRequirementIsRefusedWithoutAWellFormedTeam() throws {
        for team: Any? in [nil, "", "AB12CD34E", "AB12CD34EF1", "ab12cd34ef", "AB12CD34E\"", "AB12CD34É", 1234567890] {
            XCTAssertNil(AgentHostIdentity.requirement(for: "com.pdparchitect.noodle", bundle: try bundle(team: team)), "\(String(describing: team))")
        }
    }

    func testUnconfiguredIdentifiersFallBackToNoodles() {
        XCTAssertEqual(AgentHostIdentity.service, "com.pdparchitect.noodle.agent-host")
        XCTAssertEqual(AgentHostIdentity.application, "com.pdparchitect.noodle")
    }
}
