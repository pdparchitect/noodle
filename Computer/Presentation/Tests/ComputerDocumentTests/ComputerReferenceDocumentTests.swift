import AppKit
import ComputerBridge
import XCTest
@testable import ComputerDocument

final class ComputerReferenceDocumentTests: XCTestCase {
    private func card(view: String? = "terminal") -> ComputerReference {
        .init(computer: .init(id: UUID(), name: "Saved computer", kind: "Shell", state: "Running", symbol: "terminal"),
            terminalID: view == "web" ? nil : UUID(), terminalPreview: "fixture output", view: view)
    }
    func testExistingTerminalAndDesktopCardsRemainReadableWithoutRuntime() throws {
        for view in [nil, "terminal", "web"] as [String?] {
            let original = card(view: view)
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try ComputerReferenceDocument.decode(data), original)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["password"]); XCTAssertNil(json["url"])
        }
    }
    func testMalformedOversizedAndUnknownReferencesAreRejected() throws {
        XCTAssertThrowsError(try ComputerReferenceDocument.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try ComputerReferenceDocument.decode(Data(repeating: 32, count: 900_001)))
        var invalid = card(); invalid.version = 2
        XCTAssertThrowsError(try ComputerReferenceDocument.decode(JSONEncoder().encode(invalid)))
        invalid = card(); invalid.terminalID = nil
        XCTAssertThrowsError(try ComputerReferenceDocument.decode(JSONEncoder().encode(invalid)))
        invalid = card(); invalid.view = "file:///etc/passwd"
        XCTAssertThrowsError(try ComputerReferenceDocument.decode(JSONEncoder().encode(invalid)))
    }
    func testLegacyAgentFieldIsIgnoredByHumanDocumentReader() throws {
        let original = card(view: "web")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["agentID"] = UUID().uuidString
        XCTAssertEqual(try ComputerReferenceDocument.decode(JSONSerialization.data(withJSONObject: json)), original)
    }
    func testReadAcceptsAReferenceFileAndRejectsDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.noodlecomputer"), original = card()
        try JSONEncoder().encode(original).write(to: url)
        XCTAssertEqual(try ComputerReferenceDocument.read(url), original)
        XCTAssertThrowsError(try ComputerReferenceDocument.read(directory))
        XCTAssertThrowsError(try ComputerReferenceDocument.read(URL(string: "https://example.invalid/reference")!))
    }
    @MainActor func testSavedPreviewRendersWithoutLaunchingOrConnectingToComputer() throws {
        _ = NSApplication.shared
        let view = ComputerDocumentView(card: card())
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertTrue(view.accessibilityLabel()?.contains("Saved computer") == true)
    }

    @MainActor func testPreparingPreviewPreservesTheRootExportedToQuickLook() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).noodlecomputer")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(card()).write(to: url)
        let controller = ComputerDocumentPreviewController()
        let exportedRoot = controller.view
        var completions = 0
        for _ in 0..<3 {
            controller.preparePreviewOfFile(at: url) { error in
                XCTAssertNil(error); completions += 1
            }
            XCTAssertTrue(controller.view === exportedRoot)
            XCTAssertEqual(exportedRoot.subviews.count, 1)
            XCTAssertTrue(exportedRoot.subviews.first is ComputerDocumentView)
            XCTAssertEqual(exportedRoot.subviews.first?.frame, exportedRoot.bounds)
        }
        XCTAssertEqual(completions, 3)
        try Data("invalid".utf8).write(to: url)
        controller.preparePreviewOfFile(at: url) { error in
            XCTAssertNotNil(error); completions += 1
        }
        XCTAssertTrue(controller.view === exportedRoot)
        XCTAssertEqual(exportedRoot.subviews.count, 1)
        XCTAssertEqual(completions, 4)
    }
}
