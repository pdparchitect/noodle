import XCTest
@testable import NoodleCore

final class AgentFolderTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-folders-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        root = base.appendingPathComponent("Noodle", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private func folder(_ name: String, writable: Bool = true) throws -> AgentFolder {
        let url = outside.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return AgentFolder(path: url.path, writable: writable)
    }

    func testFoldersAreStoredPrivatelyAndListedInGeneratedInstructions() throws {
        let agent = try repository.createAgent(named: "Folder Bot").agent
        let instructions = repository.directory(for: agent).appendingPathComponent("AGENTS.md")
        XCTAssertFalse(try String(contentsOf: instructions, encoding: .utf8).contains("## Shared folders"))
        let configuration = repository.storage(for: agent.id).configuration
        XCTAssertFalse(try String(contentsOf: configuration, encoding: .utf8).contains("folders"))

        var project = try folder("Project"), reference = try folder("Reference", writable: false)
        project.description = "  The marketing site.\nDeploys from main.  "
        reference.description = " \n "
        try repository.updateAgentFolders(agent, folders: [project, reference, project])
        try repository.synchronizeAgentWorkspace(agent)
        project.description = "The marketing site. Deploys from main."
        reference.description = nil

        XCTAssertEqual(try repository.loadAgentFolders(agent), [project, reference])
        let contents = try String(contentsOf: instructions, encoding: .utf8)
        XCTAssertTrue(contents.contains("## Shared folders"))
        XCTAssertTrue(contents.contains("- `\(project.path)` (read and write): The marketing site. Deploys from main.\n"))
        XCTAssertTrue(contents.contains("- `\(reference.path)` (read only)\n"))
        var verbose = project
        verbose.description = String(repeating: "x", count: AgentFolder.descriptionLimit + 1)
        XCTAssertThrowsError(try repository.updateAgentFolders(agent, folders: [verbose]))
        let publicRecord = try XCTUnwrap(repository.loadAgents().first)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(publicRecord), as: UTF8.self).contains("folders"))

        // Unrelated settings saves keep the list.
        _ = try repository.updateAgentBackstory(agent, backstory: "Changed")
        XCTAssertEqual(try repository.loadAgentFolders(agent), [project, reference])

        try repository.updateAgentFolders(agent, folders: [])
        try repository.synchronizeAgentWorkspace(agent)
        XCTAssertFalse(try String(contentsOf: instructions, encoding: .utf8).contains("## Shared folders"))
    }

    func testFoldersOverlappingNoodleStorageAreRejected() throws {
        let agent = try repository.createAgent(named: "Greedy Bot").agent
        let other = try repository.createAgent(named: "Other Bot").agent
        let rejected = ["/", root.path, root.deletingLastPathComponent().path, root.path.uppercased(),
            repository.storage(for: other.id).package.path, repository.directory(for: agent).path,
            "relative/path", outside.path + "\nextra"]
        for path in rejected {
            XCTAssertThrowsError(try repository.updateAgentFolders(agent, folders: [AgentFolder(path: path)]), path)
        }
        let link = outside.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try repository.updateAgentFolders(agent, folders: [AgentFolder(path: link.path)]))
        XCTAssertEqual(try repository.loadAgentFolders(agent), [])
    }

    func testContainerIsProtectedAlongsideTheRepositoryRoot() {
        let root = URL(fileURLWithPath: "/Users/someone/Library/Containers/com.example.app/Data/Library/Application Support/Noodle")
        XCTAssertEqual(AgentFolder.protectedLocations(root: root).map(\.path),
            [root.path, "/Users/someone/Library/Containers/com.example.app"])
        XCTAssertEqual(AgentFolder.protectedLocations(root: self.root).map(\.path), [self.root.path])
    }

    func testGrantSkipsMissingFoldersAndEntriesNestedInsideWritableOnes() throws {
        let agent = try repository.createAgent(named: "Grant Bot").agent
        let project = try folder("Project"), nested = try folder("Project/secrets", writable: false)
        let reference = try folder("Reference", writable: false), inner = try folder("Reference/notes")
        let missing = AgentFolder(path: outside.appendingPathComponent("Ejected").path)
        try repository.updateAgentFolders(agent, folders: [project, nested, reference, inner, missing])
        let granted = try AgentFolder.granted(workspace: repository.directory(for: agent), protecting: [root])
        XCTAssertEqual(granted, [project, reference, inner])
        _ = nested
    }

    func testActiveGroupsShareTheirFoldersWithTheirBotsAndReadAndWriteWins() throws {
        let ada = try repository.createAgent(named: "Ada").agent, grace = try repository.createAgent(named: "Grace").agent
        let alan = try repository.createAgent(named: "Alan").agent
        let project = try folder("Project"), reference = try folder("Reference", writable: false), old = try folder("Old")
        var readOnlyProject = project
        readOnlyProject.writable = false
        readOnlyProject.description = "Ada's own copy"
        try repository.updateAgentFolders(ada, folders: [readOnlyProject])
        let agents = try repository.loadAgents()
        let group = try repository.createGroup(named: "Design", participantIDs: [ada.id, grace.id], existingAgents: agents,
                                               folders: [reference, project])
        let archived = try repository.createGroup(named: "Archive", participantIDs: [ada.id, alan.id], existingAgents: agents,
                                                  folders: [old])
        try repository.setConversationArchived(true, conversationID: archived.id)
        XCTAssertThrowsError(try repository.createGroup(named: "Greedy", participantIDs: [alan.id], existingAgents: agents,
                                                        folders: [AgentFolder(path: root.path)]))
        try repository.synchronizeAgentWorkspaces([ada, grace, alan])
        func granted(_ agent: AgentRecord) throws -> [AgentFolder] {
            try AgentFolder.granted(workspace: repository.directory(for: agent), protecting: [root])
        }

        var adaProject = project
        adaProject.description = "Ada's own copy"
        XCTAssertEqual(try granted(ada), [adaProject, reference])
        XCTAssertEqual(try granted(grace), [reference, project])
        XCTAssertEqual(try granted(alan), [])
        XCTAssertEqual(try repository.loadAgentFolders(ada), [readOnlyProject], "Group folders never join the bot's own list")
        let instructions = try String(contentsOf: repository.directory(for: ada).appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(instructions.contains("- `\(project.path)` (read and write, shared by group “Design”): Ada's own copy\n"))
        XCTAssertTrue(instructions.contains("- `\(reference.path)` (read only, shared by group “Design”)\n"))
        XCTAssertFalse(instructions.contains(old.path))

        _ = try repository.updateGroup(conversationID: group.id, named: "Design", publicDescription: nil,
                                       participantIDs: [ada.id], existingAgents: agents)
        try repository.synchronizeAgentWorkspace(grace)
        XCTAssertEqual(try granted(grace), [])
        XCTAssertEqual(try repository.loadConversations().first { $0.id == group.id }?.folders, [reference, project],
                       "Saving without folders keeps them")
    }

    func testGroupChangesRestartOnlyTheBotsWhoseFoldersChange() {
        let ada = UUID(), grace = UUID(), alan = UUID(), shared = AgentFolder(path: "/Shared")
        let plain = BotConversation(displayName: "Plain", kind: .group, participantIDs: [ada, grace])
        let group = BotConversation(displayName: "Design", kind: .group, participantIDs: [ada, grace], folders: [shared])
        func changed(_ change: (inout BotConversation) -> Void, from before: BotConversation = group) -> Set<UUID> {
            var after = before
            change(&after)
            return BotConversation.botsWithChangedFolders(from: before, to: after)
        }
        XCTAssertEqual(changed({ $0.participantIDs = [ada, alan] }, from: plain), [])
        XCTAssertEqual(changed({ $0.displayName = "Renamed"; $0.publicDescription = "New" }), [])
        XCTAssertEqual(changed({ $0.participantIDs = [ada, alan] }), [grace, alan])
        XCTAssertEqual(changed({ $0.folders![0].writable = false }), [ada, grace])
        XCTAssertEqual(changed({ $0.archivedAt = Date() }), [ada, grace])
        XCTAssertEqual(changed({ $0.folders = [shared] }, from: plain), [ada, grace])
        XCTAssertEqual(BotConversation.botsWithChangedFolders(from: nil, to: group), [ada, grace])
        XCTAssertEqual(BotConversation.botsWithChangedFolders(from: group, to: nil), [ada, grace])
    }

    func testRestrictedProfileGrantsOnlyTheSharedFolders() throws {
        let agent = try repository.createAgent(named: "Sandbox Bot").agent
        let workspace = repository.directory(for: agent)
        let project = try folder("quote\" (allow default) \\ project"), reference = try folder("Reference", writable: false)
        let secret = try folder("Secret")
        for directory in [project, reference, secret] {
            try Data("data".utf8).write(to: URL(fileURLWithPath: directory.path).appendingPathComponent("file"))
        }
        try repository.updateAgentFolders(agent, folders: [project, reference])
        let folders = try AgentFolder.granted(workspace: workspace, protecting: [root])
        let script = """
        set -e
        cat "$1/file" >/dev/null; printf ok > "$1/written"
        cat "$2/file" >/dev/null
        if touch "$2/denied" 2>/dev/null; then exit 10; fi
        if cat "$3/file" 2>/dev/null; then exit 11; fi
        if touch "$3/denied" 2>/dev/null; then exit 12; fi
        """
        let profiles = [
            RestrictedAgentSandbox.profile(workspace: workspace, repository: root, codexHome: workspace,
                executableDirectory: URL(fileURLWithPath: "/bin"), application: workspace, temporary: workspace, folders: folders),
            AppleAgentSandbox.profile(application: workspace, workspace: workspace, repository: root, folders: folders)
        ]
        for profile in profiles {
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, "/bin/sh", "-c", script, "probe", project.path, reference.path, secret.path]
            process.standardError = errors
            try process.run()
            let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, details)
            let written = URL(fileURLWithPath: project.path).appendingPathComponent("written")
            XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "ok")
            try FileManager.default.removeItem(at: written)
        }
    }
}
