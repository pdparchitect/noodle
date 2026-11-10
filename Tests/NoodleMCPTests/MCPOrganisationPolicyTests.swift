import Foundation
import NoodleCore
import XCTest
@testable import NoodleMCP

/// The service itself refuses a connection the organisation blocks, so no path around Settings reaches it.
final class MCPOrganisationPolicyTests: XCTestCase {
    private struct Blocking: OrganisationPolicy {
        func allows(_ action: OrganisationAction) -> Bool {
            if case .toolConnection(_, let endpoint) = action { return endpoint.host != "blocked.example" }
            return true
        }
        func value(of setting: OrganisationSetting) -> Bool? { nil }
        var rules: [OrganisationRule] { [] }
    }

    override func tearDown() async throws {
        await MainActor.run { Organisation.enforce(UnmanagedPolicy()) }
    }

    func testABlockedConnectionCanNeitherSignInNorBeUsed() async throws {
        await MainActor.run { Organisation.enforce(Blocking()) }
        let service = MCPService(namespace: "noodle.tests.\(UUID())")
        let record = try MCPConnectionRecord(name: "Blocked", endpoint: URL(string: "https://blocked.example/mcp")!)
        let request = MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
        do { _ = try await service.perform(request, connection: record); XCTFail("A blocked connection was used") }
        catch { XCTAssertEqual(error.localizedDescription, "Your organisation doesn't allow this tool connection.") }
        do {
            try await service.signIn(record, redirectURI: URL(string: "noodle-dev://mcp/oauth/callback")!) { _ in
                XCTFail("A blocked connection opened its sign-in page"); throw CancellationError()
            }
            XCTFail("A blocked connection signed in")
        } catch { XCTAssertEqual(error.localizedDescription, "Your organisation doesn't allow this tool connection.") }
        XCTAssertEqual(MCPConnectionProviders.safeError(MCPServiceError.notAllowed), "Your organisation doesn't allow this tool connection.")
    }
}
