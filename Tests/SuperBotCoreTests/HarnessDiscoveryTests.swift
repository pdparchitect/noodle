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

    func testDiscoverySeparatesHarnessPresenceFromACPReadiness() throws {
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let binaries = root.appendingPathComponent("bin", isDirectory: true)
        let codex = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let discovery = HarnessDiscovery(
            homeDirectory: root,
            applicationsDirectory: applications,
            executableSearchDirectories: [binaries]
        )
        let engineOnly = discovery.discover(.codex)
        XCTAssertEqual(engineOnly.readiness, .engineOnly)
        XCTAssertEqual(engineOnly.enginePath, codex.path)

        let adapter = binaries.appendingPathComponent("codex-acp")
        XCTAssertTrue(FileManager.default.createFile(atPath: adapter.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adapter.path)

        let ready = discovery.discover(.codex)
        XCTAssertEqual(ready.readiness, .ready)
        XCTAssertEqual(ready.acpAdapterPath, adapter.path)
    }

    func testDesktopApplicationWithoutCLIIsNotReportedAsReady() throws {
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let claude = applications.appendingPathComponent("Claude.app", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        let result = HarnessDiscovery(
            homeDirectory: root,
            applicationsDirectory: applications,
            executableSearchDirectories: []
        ).discover(.claude)

        XCTAssertEqual(result.readiness, .applicationOnly)
        XCTAssertEqual(result.applicationPath, claude.path)
        XCTAssertNil(result.enginePath)
        XCTAssertNil(result.acpAdapterPath)
    }
}
