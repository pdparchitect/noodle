import XCTest
@testable import SuperBotCore

final class HarnessDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superbot-harness-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiscoveryFindsBundledCodexExecutable() throws {
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let codex = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let result = HarnessDiscovery(
            homeDirectory: root,
            applicationsDirectory: applications,
            executableSearchDirectories: []
        ).discover(.codex)

        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.executablePath, codex.path)
        XCTAssertEqual(result.detail, "Installed")
    }

    func testDiscoveryDoesNotTreatApplicationAloneAsHarness() throws {
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("ChatGPT.app"),
            withIntermediateDirectories: true
        )

        let result = HarnessDiscovery(
            homeDirectory: root,
            applicationsDirectory: applications,
            executableSearchDirectories: []
        ).discover(.codex)

        XCTAssertFalse(result.isAvailable)
        XCTAssertNil(result.executablePath)
        XCTAssertEqual(result.detail, "Not installed")
    }

    func testHarnessModelCarriesItsOwnEffortChoices() {
        let model = HarnessModel(
            id: "gpt-test",
            displayName: "GPT Test",
            description: "Test model",
            supportedEfforts: [HarnessEffort(id: "low", description: "Fast")],
            defaultEffort: "low",
            isDefault: true
        )

        XCTAssertEqual(model.supportedEfforts.first?.displayName, "Low")
        XCTAssertEqual(model.defaultEffort, "low")
        XCTAssertTrue(model.isDefault)
    }
}
