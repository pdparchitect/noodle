import Darwin
import XCTest
@testable import NoodleCore

final class MCPFileContentTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func expand(_ object: [String: Any], currentDirectory: URL? = nil) throws -> [String: Any] {
        try self.object(MCPFileContent.arguments(json(object), workspace: workspace, currentDirectory: currentDirectory ?? workspace))
    }
    private func extract(_ object: [String: Any], callID: UUID = UUID(), resourceRead: Bool = false) throws -> [String: Any] {
        try self.object(MCPFileContent.result(json(object), workspace: workspace, callID: callID, resourceRead: resourceRead))
    }

    func testFileReferencesExpandNestedValuesAndPreserveLiteralAtSigns() throws {
        let bytes = Data([0, 255, 128, 10])
        let folder = workspace.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("report.pdf"))
        let result = try expand([
            "@key": "@@literal", "email": "a@example.com", "number": 12, "null": NSNull(),
            "items": [["data": "@./report.pdf"], "@@@name"],
            "absolute": "@" + folder.appendingPathComponent("report.pdf").path
        ], currentDirectory: folder)
        XCTAssertEqual(result["@key"] as? String, "@literal")
        XCTAssertEqual(result["email"] as? String, "a@example.com")
        XCTAssertEqual(result["number"] as? Int, 12)
        XCTAssertTrue(result["null"] is NSNull)
        let items = try XCTUnwrap(result["items"] as? [Any])
        XCTAssertEqual((items[0] as? [String: String])?["data"], bytes.base64EncodedString())
        XCTAssertEqual(items[1] as? String, "@@name")
        XCTAssertEqual(result["absolute"] as? String, bytes.base64EncodedString())
        let unchanged = Data("{ \"text\": \"a@b\", \"data\": \"already encoded\" }".utf8)
        XCTAssertEqual(try MCPFileContent.arguments(unchanged, workspace: workspace, currentDirectory: workspace), unchanged)
    }

    func testReferencesRejectOutsideTraversalLinksDirectoriesAndSpecialFiles() throws {
        let file = workspace.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let outside = root.appendingPathComponent("outside")
        try Data([2]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("parent"), withDestinationURL: root)
        try FileManager.default.linkItem(at: outside, to: workspace.appendingPathComponent("hardlink"))
        let fifo = workspace.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for path in [outside.path, "../outside", "link", "parent/outside", "hardlink", ".", "fifo", "missing", "", "bad\0path"] {
            XCTAssertThrowsError(try expand(["data": "@" + path]), path)
        }
    }

    func testExpandedArgumentsEnforceAggregateAndJSONOverheadLimits() throws {
        let file = workspace.appendingPathComponent("file")
        try Data(repeating: 255, count: 400_000).write(to: file)
        XCTAssertNoThrow(try expand(["data": "@file"]))
        XCTAssertThrowsError(try expand(["data": ["@file", "@file"]]))
        try Data(repeating: 0, count: MCPBridgeFiles.maxRequestBytes / 4 * 3).write(to: file)
        XCTAssertThrowsError(try expand(["data": "@file"]), "The JSON wrapper also counts")
        try Data(repeating: 0, count: MCPBridgeFiles.maxRequestBytes).write(to: file)
        XCTAssertThrowsError(try expand(["data": "@file"]))
        XCTAssertThrowsError(try MCPFileContent.arguments(Data("[]".utf8), workspace: workspace, currentDirectory: workspace))
    }

    func testMixedBinaryBlocksBecomeFilesWithoutLosingMetadataOrStructuredData() throws {
        let bytes = Data([0, 255, 10, 128])
        let encoded = bytes.base64EncodedString()
        let structured: [String: Any] = ["blob": encoded, "data": encoded, "type": "image"]
        let text: [String: Any] = ["type": "text", "text": "ready"]
        let link: [String: Any] = ["type": "resource_link", "uri": "reports://next", "name": "next"]
        let result = try extract([
            "isError": true, "_meta": ["request": "id"], "structuredContent": structured,
            "content": [text,
                ["type": "image", "data": encoded, "mimeType": "image/png", "annotations": ["audience": ["user"]]],
                ["type": "audio", "data": encoded, "mimeType": "audio/wav", "_meta": ["extra": true]],
                ["type": "resource", "resource": ["uri": "reports://../../bad.pdf", "mimeType": "application/pdf", "blob": encoded, "_meta": ["inner": true]]],
                link]
        ])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(try json(result["structuredContent"]!), try json(structured))
        XCTAssertEqual((result["_meta"] as? [String: String])?["request"], "id")
        let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(try json(blocks[0]), try json(text))
        XCTAssertEqual(try json(blocks[4]), try json(link))
        for block in blocks[1...3] {
            XCTAssertEqual(block["type"] as? String, "file")
            XCTAssertEqual(block["bytes"] as? Int, bytes.count)
            XCTAssertNil(block["data"])
            let path = try XCTUnwrap(block["path"] as? String)
            XCTAssertTrue(path.hasPrefix(workspace.path + "/.noodle/tool-attachments/"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertNotNil(blocks[1]["annotations"])
        XCTAssertEqual(blocks[2]["sourceType"] as? String, "audio")
        XCTAssertNotNil(blocks[2]["_meta"])
        let resource = try XCTUnwrap(blocks[3]["resource"] as? [String: Any])
        XCTAssertNil(resource["blob"])
        XCTAssertNotNil(resource["_meta"])
        XCTAssertEqual(resource["uri"] as? String, "reports://../../bad.pdf")
        XCTAssertTrue((blocks[3]["path"] as? String)?.hasSuffix("/004.pdf") == true)
    }

    func testRawAndTextOnlyResultsAreUnchangedAndCreateNoFiles() throws {
        let raw = try json(["content": [["type": "image", "data": "AA==", "mimeType": "image/png"]]])
        XCTAssertEqual(try MCPFileContent.result(raw, workspace: workspace, callID: UUID(), raw: true), raw)
        let text = Data("{ \"content\": [{\"type\":\"text\",\"text\":\"hi\"}] }".utf8)
        XCTAssertEqual(try MCPFileContent.result(text, workspace: workspace, callID: UUID()), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(MCPFileContent.directory).path))
    }

    func testResultSizeLimitAppliesBeforeSavingAndToRawOutput() throws {
        let oversized = Data(repeating: 32, count: MCPBridgeFiles.maxResultBytes + 1)
        for raw in [false, true] {
            XCTAssertThrowsError(try MCPFileContent.result(oversized, workspace: workspace, callID: UUID(), raw: raw))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(MCPFileContent.directory).path))
    }

    func testResourceReadsExtractBlobsAndLeaveTextResourcesAlone() throws {
        let text = ["uri": "reports://text", "text": "hello"]
        let result = try extract(["contents": [text, ["uri": "reports://file", "blob": "", "mimeType": "unknown/mime"]]], resourceRead: true)
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        XCTAssertEqual(try json(contents[0]), try json(text))
        XCTAssertEqual(contents[1]["uri"] as? String, "reports://file")
        XCTAssertEqual(contents[1]["bytes"] as? Int, 0)
        XCTAssertNil(contents[1]["blob"])
        let path = try XCTUnwrap(contents[1]["path"] as? String)
        XCTAssertTrue(path.hasSuffix(".bin"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data())
    }

    func testInvalidBase64FailsBeforeSavingAnyFiles() throws {
        XCTAssertThrowsError(try extract(["content": [
            ["type": "image", "data": "AA==", "mimeType": "image/png"],
            ["type": "audio", "data": "not base64!", "mimeType": "audio/wav"]
        ]]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(MCPFileContent.directory).path))
    }

    func testDestinationLinksAreRejectedAndExistingFilesPreserved() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let noodle = try WorkspaceMailbox(workspace: workspace, path: ".noodle", create: true)
        try FileManager.default.createSymbolicLink(at: noodle.url.appendingPathComponent("tool-attachments"), withDestinationURL: outside)
        let binary: [String: Any] = ["content": [["type": "image", "data": "AA==", "mimeType": "image/png"]]]
        XCTAssertThrowsError(try extract(binary))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        noodle.remove("tool-attachments")
        let id = UUID()
        let folder = try WorkspaceMailbox(workspace: workspace, path: MCPFileContent.directory + "/" + id.uuidString.lowercased(), create: true)
        try folder.writeData(Data("keep".utf8), named: "002.png")
        XCTAssertThrowsError(try extract(["content": [
            ["type": "image", "data": "AA==", "mimeType": "image/png"],
            ["type": "image", "data": "AA==", "mimeType": "image/png"]
        ]], callID: id))
        XCTAssertEqual(try folder.read("002.png", limit: 10), Data("keep".utf8))
        XCTAssertFalse(folder.contains("001.png"), "Files from this failed extraction are removed")
    }
}
