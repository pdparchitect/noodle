import XCTest
@testable import NoodleCore

final class HarnessDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-harness-tests-\(UUID().uuidString)", isDirectory: true)
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
            executableSearchDirectories: [],
            environment: [:]
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
            executableSearchDirectories: [],
            environment: [:]
        ).discover(.codex)

        XCTAssertFalse(result.isAvailable)
        XCTAssertNil(result.executablePath)
        XCTAssertEqual(result.detail, "Not installed")
    }

    func testDiscoveryFindsClaudeCodeNativeInstallerLink() throws {
        let claude = root.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: claude.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let result = HarnessDiscovery(
            homeDirectory: root,
            applicationsDirectory: root,
            executableSearchDirectories: [],
            environment: [:]
        ).discover(.claudeCode)

        XCTAssertEqual(result.executablePath, claude.path)
        XCTAssertEqual(result.provider.displayName, "Claude Code")
    }

    func testNoHarnessOverrideIsDebugOnlyAndSurvivesRefresh() throws {
        let executable = root.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let discovery = HarnessDiscovery(
            homeDirectory: root,
            applicationsDirectory: root,
            executableSearchDirectories: [root],
            environment: ["NOODLE_SIMULATE_NO_HARNESSES": "1"]
        )
        for _ in 0..<3 {
            #if DEBUG
            XCTAssertFalse(discovery.discover(.codex).isAvailable)
            XCTAssertTrue(discovery.discover().allSatisfy { !$0.isAvailable })
            #else
            XCTAssertEqual(discovery.discover(.codex).executablePath, executable.path)
            XCTAssertTrue(discovery.discover().contains { $0.isAvailable })
            #endif
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    }

    func testNoHarnessOverrideRequiresExplicitOne() throws {
        let executable = root.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        for environment in [[:], ["NOODLE_SIMULATE_NO_HARNESSES": "0"],
                            ["NOODLE_SIMULATE_NO_HARNESSES": "true"],
                            ["NOODLE_SIMULATE_NO_HARNESSES": ""]] {
            let discovery = HarnessDiscovery(
                homeDirectory: root,
                applicationsDirectory: root,
                executableSearchDirectories: [root],
                environment: environment
            )
            XCTAssertEqual(discovery.discover(.codex).executablePath, executable.path)
        }
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

    func testClaudeCatalogueContainsOnlyTheStandardAliases() {
        XCTAssertEqual(
            ClaudeCodeCapabilities.models.map(\.id),
            ["fable", "opus", "sonnet", "haiku"]
        )
    }

    func testClaudeModelIdentifiersRemainArgumentSafe() {
        XCTAssertTrue(ClaudeCodeCapabilities.isValidModelIdentifier("fable"))
        XCTAssertTrue(ClaudeCodeCapabilities.isValidModelIdentifier("opus"))
        XCTAssertFalse(ClaudeCodeCapabilities.isValidModelIdentifier("claude-opus-4-7"))
        XCTAssertFalse(ClaudeCodeCapabilities.isValidModelIdentifier("claude-opus-4-7 --verbose"))
        XCTAssertFalse(ClaudeCodeCapabilities.isValidModelIdentifier(""))
    }
}
