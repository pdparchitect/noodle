import AppletBridge
import XCTest

@testable import NoodleCore

final class AppletAccessTests: XCTestCase {
    func testSkillRequiresInstalledCompanionAndBundledCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("Noodle Applet.app")
        let helper = root.appendingPathComponent("noodlet")
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("workspace"),
            launcherExecutableURL: root.appendingPathComponent("messenger"),
            discoverAppletApplication: { application })
        try repository.prepare()
        try Data("fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let agent = try repository.createAgent(named: "Builder").agent
        let workspace = repository.directory(for: agent)
        let skill = workspace.appendingPathComponent(".agents/skills/applet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path), "Bundling the CLI alone must not expose Applet")

        let executable = application.appendingPathComponent("Contents/MacOS/NoodleApplet")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata = ["CFBundleIdentifier": AppletConnection.providerID, "CFBundleExecutable": "NoodleApplet"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: application.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try repository.synchronizeAgentWorkspace(agent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.path))
        XCTAssertEqual(repository.appletExecutableURL, helper)

        // A partially removed app can still be registered with Launch Services.
        try FileManager.default.removeItem(at: executable)
        try repository.synchronizeAgentWorkspace(agent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try repository.synchronizeAgentWorkspace(agent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.path))

        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent("Noodle Applet.app")
        try FileManager.default.moveItem(at: application, to: trashed)
        XCTAssertFalse(AppletAgentSkill.isCompanionInstalled(at: trashed))
        try FileManager.default.moveItem(at: trashed, to: application)
        try FileManager.default.removeItem(at: helper)
        try repository.synchronizeAgentWorkspace(agent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path), "Both app and bundled helper are required")
    }

    func testEveryCommandIsDocumentedInGeneratedSkillAndHelp() {
        for command in AppletOperation.allCases {
            let guidance = MessengerDocumentation.appletGuidance(command)
            XCTAssertFalse(guidance.isEmpty)
            XCTAssertTrue(MessengerDocumentation.appletCLIHelp.contains(guidance))
            XCTAssertTrue(MessengerDocumentation.appletSkill.contains(guidance))
            XCTAssertTrue(MessengerDocumentation.referenceMarkdown.contains(guidance))
        }
    }
    func testManagedSkillPreservesCustomSkillAndExposesCorrectHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/applet")
        try AppletAgentSkill.synchronize(
            workspace: root, enabled: true, executable: URL(fileURLWithPath: "/fixture/noodlet"))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: skill.appendingPathComponent("noodlet").path), "/fixture/noodlet")
        XCTAssertEqual(
            try String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8),
            MessengerDocumentation.appletSkill)
        try AppletAgentSkill.synchronize(workspace: root, enabled: false, executable: nil)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("custom".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        XCTAssertThrowsError(
            try AppletAgentSkill.synchronize(workspace: root, enabled: true, executable: nil))
        XCTAssertEqual(
            try String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "custom")
    }
}
