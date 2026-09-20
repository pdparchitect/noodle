import BrowserBridge
import NoodleCore
import XCTest

final class BrowserWebMCPTests: XCTestCase {
    func testArgumentAndScriptFilesStayInsideWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("{\"text\":\"🍄\"}".utf8)
        for path in ["arguments.json", "nested/arguments.json"] {
            try contents.write(to: workspace.appendingPathComponent(path))
            XCTAssertEqual(try ComputerWorkspaceFiles.read(workspace: workspace, path: path, limit: 100), contents)
            XCTAssertThrowsError(try ComputerWorkspaceFiles.read(workspace: workspace, path: path, limit: 2))
        }
        let outside = root.appendingPathComponent("outside.json")
        try contents.write(to: outside)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link.json"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("linked-parent"), withDestinationURL: root)
        for path in ["link.json", "linked-parent/outside.json", "../outside.json", "nested", outside.path] {
            XCTAssertThrowsError(try ComputerWorkspaceFiles.read(workspace: workspace, path: path, limit: 100), path)
        }
    }

    func testNamespacedCommandsAndGeneratedGuidance() throws {
        XCTAssertEqual(try BrowserOperation.expandingWebMCPCommand(["webmcp", "list", "--browser", "id"]), ["webmcp-list", "--browser", "id"])
        XCTAssertEqual(try BrowserOperation.expandingWebMCPCommand(["webmcp", "call", "--tool", "id"]), ["webmcp-call", "--tool", "id"])
        XCTAssertEqual(try BrowserOperation.expandingWebMCPCommand(["webmcp", "--help"]), ["--help"])
        XCTAssertThrowsError(try BrowserOperation.expandingWebMCPCommand(["webmcp"]))
        XCTAssertThrowsError(try BrowserOperation.expandingWebMCPCommand(["webmcp", "unknown"]))
        XCTAssertFalse(MessengerDocumentation.browserGuidance(.webMCPList).isEmpty)
        XCTAssertFalse(MessengerDocumentation.browserGuidance(.webMCPCall).isEmpty)
        XCTAssertTrue(MessengerDocumentation.browserToolGuidance.contains("document.modelContext.executeTool"))
        XCTAssertTrue(MessengerDocumentation.browserConventions.contains("needs-user-action"))
        XCTAssertFalse(MessengerDocumentation.browserToolGuidance.contains("skills/browser/browser"), "nothing points bots at the removed command")
    }

    func testRequestRequiresScopedIdentityAndJSONObjects() throws {
        var request = BrowserRequest(.webMCPCall, browserID: UUID(), tabID: UUID())
        request.toolID = "document:registration"
        for invalid in ["[]", "null", "true", "1", "\"string\"", "{bad}", String(repeating: " ", count: 1_048_577)] {
            request.arguments = invalid
            XCTAssertThrowsError(try request.validate(), invalid.prefix(40).description)
        }
        request.arguments = #"{"text":"quotes ' \" and Unicode 🍄","nested":{"items":[1,true,null]}}"#
        XCTAssertNoThrow(try request.validate())
        let roundTrip = try JSONDecoder().decode(BrowserRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTrip.toolID, request.toolID)
        XCTAssertEqual(roundTrip.arguments, request.arguments)
        request.tabID = nil
        XCTAssertThrowsError(try request.validate())
        request.tabID = UUID(); request.browserID = nil
        XCTAssertThrowsError(try request.validate())
        request.browserID = UUID(); request.toolID = ""
        XCTAssertThrowsError(try request.validate())
        request.toolID = String(repeating: "x", count: 257)
        XCTAssertThrowsError(try request.validate())
        request.toolID = "id"; request.operation = .webMCPList
        XCTAssertThrowsError(try request.validate())
        request.toolID = nil; request.arguments = nil
        XCTAssertNoThrow(try request.validate())
    }
}
