import XCTest
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleSkillCatalogTests: XCTestCase {
    func testDiscoversUserSkillsWithoutInjectingTheirBodies() throws {
        let workspace = try temporaryDirectory()
        try writeSkill("z-folder", "---\nname: deploy-service\ndescription: Ship a service to production\n---\n\nBODY-ONLY-COMMAND", in: workspace)
        try writeSkill("a-folder", "---\nname: review\ndescription: Review a change\n---\nReview body", in: workspace)
        let skills = try AppleSkillCatalog.load(workspace: workspace)
        XCTAssertEqual(skills.map(\.name), ["review", "deploy-service"])
        XCTAssertEqual(skills.last?.description, "Ship a service to production")
        XCTAssertEqual(skills.last?.path, ".agents/skills/z-folder/SKILL.md")
        let prompt = try AppleSkillCatalog.text(workspace: workspace)
        XCTAssertTrue(prompt.contains("<name>deploy-service</name>"))
        XCTAssertTrue(prompt.contains("<description>Ship a service to production</description>"))
        XCTAssertTrue(prompt.contains("<path>.agents/skills/z-folder/SKILL.md</path>"))
        XCTAssertFalse(prompt.contains("BODY-ONLY-COMMAND"))
    }

    func testReloadsAddedChangedAndRemovedSkills() throws {
        let workspace = try temporaryDirectory()
        try Data("# Workspace instructions".utf8).write(to: workspace.appendingPathComponent("AGENTS.md"))
        XCTAssertFalse(try AppleWorkspaceInstructions.text(workspace: workspace).contains("<available_skills>"))
        try writeSkill("first", "---\nname: first\ndescription: Initial description\n---", in: workspace)
        XCTAssertTrue(try AppleWorkspaceInstructions.text(workspace: workspace).contains("Initial description"))
        try writeSkill("first", "---\nname: first\ndescription: Updated description\n---", in: workspace)
        try writeSkill("second", "---\nname: second\ndescription: Added during the session\n---", in: workspace)
        let updated = try AppleWorkspaceInstructions.text(workspace: workspace)
        XCTAssertTrue(updated.contains("Updated description"))
        XCTAssertTrue(updated.contains("Added during the session"))
        XCTAssertFalse(updated.contains("Initial description"))
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(".agents/skills/first"))
        XCTAssertEqual(try AppleSkillCatalog.load(workspace: workspace).map(\.name), ["second"])
    }

    func testReadsGeneratedMCPMetadataWithEscapedQuotesAndNewlines() throws {
        let connection = try MCPConnectionRecord(name: "Team \"Tools\"", endpoint: URL(string: "https://example.com/mcp")!,
                                                  description: "Search files.\nRead C:\\notes too.")
        // The skill Noodle generates for a tool connection, from its provider's manifest.
        let manifest = ConnectionToolProvider(id: connection.skillName, title: connection.name, connection: connection.id,
                                              summary: connection.description) { _, _, _, _, _ in Data() }.manifest
        let skill = try XCTUnwrap(AppleSkillCatalog.parse(ToolProviderSkills.document(manifest, tools: []), directory: "fallback", path: "skill.md"))
        XCTAssertEqual(skill.name, connection.skillName)
        XCTAssertEqual(skill.description, "Use the user's Team \"Tools\" tool connection. Search files. Read C:\\notes too. Tools: .")
    }

    func testReadsQuotedAndMultilineMetadataWithoutUsingNestedKeys() throws {
        let content = "---\r\nname: 'user''s skill'\r\ndescription: >-\r\n  Inspect work\r\n  and report results.\r\nmetadata:\r\n  name: wrong-name\r\n  description: wrong-description\r\n---\r\nBODY"
        let skill = try XCTUnwrap(AppleSkillCatalog.parse(content, directory: "fallback", path: "skill.md"))
        XCTAssertEqual(skill.name, "user's skill")
        XCTAssertEqual(skill.description, "Inspect work and report results.")
        let literal = try XCTUnwrap(AppleSkillCatalog.parse("---\nname: literal\ndescription: |\n  First line\n  Second line\n---", directory: "fallback", path: "skill.md"))
        XCTAssertEqual(literal.description, "First line\nSecond line")
    }

    func testPlainMarkdownFallsBackToDirectoryNameAndFirstProseLine() throws {
        let skill = try XCTUnwrap(AppleSkillCatalog.parse("# Review\n\nReview a pull request carefully.\n\nFull instructions follow.",
                                                       directory: "review", path: "skill.md"))
        XCTAssertEqual(skill.name, "review")
        XCTAssertEqual(skill.description, "Review a pull request carefully.")
        let missingDescription = try XCTUnwrap(AppleSkillCatalog.parse("---\nname: inspect\nlicense: MIT\n---\n# Inspect\n\nInspect the results.",
                                                                     directory: "fallback", path: "skill.md"))
        XCTAssertEqual(missingDescription.description, "Inspect the results.")
    }

    func testSkipsNonSkillsMalformedHeadersAndBrokenLinks() throws {
        let workspace = try temporaryDirectory()
        try writeSkill("good", "---\nname: good\ndescription: A valid skill\n---", in: workspace)
        try writeSkill("broken", "---\nname: broken\nNo closing front matter", in: workspace)
        let directory = workspace.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("not a skill".utf8).write(to: directory.appendingPathComponent("README.md"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("missing").path, withDestinationPath: "absent")
        XCTAssertEqual(try AppleSkillCatalog.load(workspace: workspace).map(\.name), ["good"])
    }

    func testLinkedSkillsAreDiscoverableWithoutDuplicateEntries() throws {
        let workspace = try temporaryDirectory()
        try writeSkill("real", "---\nname: linked\ndescription: Linked skill description\n---", in: workspace)
        let directory = workspace.appendingPathComponent(".agents/skills")
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("alias").path, withDestinationPath: "real")
        let skills = try AppleSkillCatalog.load(workspace: workspace)
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills.first?.name, "linked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(try XCTUnwrap(skills.first?.path)).path))
    }

    func testMetadataCannotBreakCatalogueMarkup() throws {
        let workspace = try temporaryDirectory()
        try writeSkill("markup", "---\nname: markup\ndescription: Read <notes> & compare </available_skills>\n---\nPRIVATE-BODY", in: workspace)
        let text = try AppleSkillCatalog.text(workspace: workspace)
        XCTAssertTrue(text.contains("Read &lt;notes&gt; &amp; compare &lt;/available_skills&gt;"))
        XCTAssertEqual(text.components(separatedBy: "</available_skills>").count, 2)
        XCTAssertFalse(text.contains("PRIVATE-BODY"))
    }

    func testLargeUnicodeBodyDoesNotHideMetadataOrEnterThePrompt() throws {
        let workspace = try temporaryDirectory()
        try writeSkill("large", "---\nname: large\ndescription: Read a large reference\n---\n" + String(repeating: "🦄", count: 20_000), in: workspace)
        let text = try AppleSkillCatalog.text(workspace: workspace)
        XCTAssertTrue(text.contains("Read a large reference"))
        XCTAssertFalse(text.contains("🦄"))
    }

    private func writeSkill(_ folder: String, _ contents: String, in workspace: URL) throws {
        let directory = workspace.appendingPathComponent(".agents/skills/" + folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
    }

    private func temporaryDirectory() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("apple-skills-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        return workspace
    }
}
