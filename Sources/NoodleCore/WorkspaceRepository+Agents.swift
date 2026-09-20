import AppletBridge
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension WorkspaceRepository {
    public func createAgent(
        named rawName: String,
        harnessIdentifier: String? = nil,
        modelIdentifier: String? = nil,
        reasoningEffort: String? = nil,
        publicDescription: String? = nil,
        avatarSymbolName: String? = nil,
        avatarColorIndex: Int? = nil,
        avatarImageData: Data? = nil,
        backstory: String = "",
        now: Date = Date()
    ) throws -> CreatedAgentWorkspace {
        let name = try ConversationName.validated(rawName)
        try prepare()

        let agent = AgentRecord(
            displayName: name,
            createdAt: now,
            updatedAt: now,
            harnessIdentifier: harnessIdentifier,
            modelIdentifier: modelIdentifier,
            reasoningEffort: reasoningEffort,
            publicDescription: Self.normalizedOptionalText(publicDescription),
            avatarSymbolName: avatarSymbolName,
            avatarColorIndex: avatarColorIndex,
            avatarImageData: avatarImageData
        )
        let layout = storage(for: agent.id)
        try layout.create()
        var createdConversationID: UUID?
        do {
            let agentDirectory = layout.workspace
            try AgentConfiguration(agent: agent, backstory: backstory.trimmingCharacters(in: .whitespacesAndNewlines)).save(to: layout)
            try "# Memory\n\n".write(
                to: agentDirectory.appendingPathComponent("memory.md"),
                atomically: true,
                encoding: .utf8
            )
            try synchronizeAgentWorkspace(agent)

            let conversation = BotConversation(
                displayName: name,
                kind: .direct,
                participantIDs: [agent.id],
                createdAt: now,
                updatedAt: now
            )
            createdConversationID = conversation.id
            try createConversationFiles(conversation)
            return CreatedAgentWorkspace(agent: agent, conversation: conversation)
        } catch {
            let original = error
            do {
                if let createdConversationID {
                    let directory = conversationDirectory(id: createdConversationID)
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                }
                try FileManager.default.removeItem(at: layout.package)
            } catch { throw AgentStorageError("Bot creation failed and its incomplete workspace could not be removed: \(error.localizedDescription)") }
            throw original
        }
    }

    public func renameAgent(_ agent: AgentRecord, to rawName: String, now: Date = Date()) throws -> AgentRecord {
        try updateAgent(
            agent,
            displayName: rawName,
            harnessIdentifier: agent.harnessIdentifier,
            modelIdentifier: agent.modelIdentifier,
            reasoningEffort: agent.reasoningEffort,
            publicDescription: agent.publicDescription,
            avatarSymbolName: agent.avatarSymbolName,
            avatarColorIndex: agent.avatarColorIndex,
            avatarImageData: agent.avatarImageData,
            now: now
        )
    }

    public func updateAgent(
        _ agent: AgentRecord,
        displayName rawName: String,
        harnessIdentifier: String?,
        modelIdentifier: String?,
        reasoningEffort: String?,
        publicDescription: String? = nil,
        avatarSymbolName: String? = nil,
        avatarColorIndex: Int? = nil,
        avatarImageData: Data? = nil,
        now: Date = Date()
    ) throws -> AgentRecord {
        var renamed = agent
        renamed.displayName = try ConversationName.validated(rawName)
        renamed.updatedAt = now
        renamed.harnessIdentifier = harnessIdentifier
        renamed.modelIdentifier = modelIdentifier
        renamed.reasoningEffort = reasoningEffort
        renamed.publicDescription = Self.normalizedOptionalText(publicDescription)
        renamed.avatarSymbolName = avatarSymbolName
        renamed.avatarColorIndex = avatarColorIndex
        renamed.avatarImageData = avatarImageData
        try saveAgentRecord(renamed)
        return renamed
    }

    public func setAgentIcon(from attachment: ConversationAttachment) throws -> AgentRecord {
        guard let conversation = try loadConversations().first(where: { $0.id == attachment.conversationID }),
              conversation.kind == .direct, conversation.participantIDs.count == 1,
              var agent = try loadAgents().first(where: { $0.id == conversation.participantIDs[0] }) else {
            throw WorkspaceError.invalidAttachment
        }
        let url = attachmentFileURL(attachment)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 50 * 1024 * 1024, ConversationBackground.canUseImage(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw ConversationBackgroundError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversationBackgroundError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversationBackgroundError.invalidImage }
        // Appearance only: preserve runtime configuration and do not restart the bot.
        agent.avatarImageData = data as Data
        agent.updatedAt = Date()
        try saveAgentRecord(agent)
        return agent
    }

    public func synchronizeAgentWorkspaces(_ agents: [AgentRecord]) throws {
        for agent in agents {
            try synchronizeAgentWorkspace(agent)
        }
    }

    public func synchronizeAgentWorkspace(_ agent: AgentRecord) throws {
        try storage(for: agent.id).validate()
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingAgent(agent.id)
        }

        let backstory = try loadAgentBackstory(agent)
        let folderInstructions = AgentFolder.instructions(try loadAgentFolders(agent))
        let workspaceFiles = try WorkspaceMailbox(workspace: directory, path: "")
        let agentsFiles = try WorkspaceMailbox(workspace: directory, path: ".agents", create: true)
        let messengerFiles = try WorkspaceMailbox(workspace: directory, path: ".agents/skills/messenger", create: true)

        if !workspaceFiles.contains("preferences.md") {
            try workspaceFiles.writeData(Data(Self.initialAgentPreferences.utf8), named: "preferences.md", replaceExisting: false)
        }
        // TODO(0.22.0): Remove these three clean-ups of what Noodle wrote before the 0.21.0 milestone.
        BrowserAgentSkill.removeLegacy(workspace: directory)
        ComputerAgentSkill.removeLegacy(workspace: directory)
        MCPSkillWriter.removeLegacy(workspace: directory)
        let appletExecutable = appletExecutableURL
        let appletEnabled = appletExecutable != nil
        let appletInstructions = appletEnabled ? "\n" + AppletGuidance.bootstrap + "\n" : ""
        try workspaceFiles.writeData(Data((Self.renderedAgentInstructions(backstory: backstory) + folderInstructions + ToolProviderSkills.instructions(workspace: directory) + appletInstructions).utf8), named: "AGENTS.md")
        workspaceFiles.remove("instructions.md")
        try workspaceFiles.symlink("CLAUDE.md", destination: "AGENTS.md")
        try AppletAgentSkill.synchronize(workspace: directory, enabled: appletEnabled, executable: appletEnabled ? appletExecutable : nil)
        _ = try synchronizeClaudeSkillLinks(in: directory)

        try messengerFiles.writeData(Data(Self.messengerSkill.utf8), named: "SKILL.md")
        if let launcherExecutableURL {
            try messengerFiles.symlink("messenger", destination: launcherExecutableURL.path)
        }

        // Earlier versions kept a list of managed paths here. Nothing read it.
        // TODO(0.22.0): Remove this clean-up after upgrades pass through the 0.21.0 milestone.
        agentsFiles.remove("managed-skills.json")
    }

    public func loadAgentBackstory(_ agent: AgentRecord) throws -> String {
        try AgentConfiguration.load(from: storage(for: agent.id)).requireBackstory()
    }

    public func loadAgentPreferences(_ agent: AgentRecord) throws -> String {
        let files = try WorkspaceMailbox(workspace: directory(for: agent), path: "")
        guard files.contains("preferences.md") else { return "" }
        return String(decoding: try files.read("preferences.md", limit: 4 * 1_048_576), as: UTF8.self)
    }

    public func updateAgentBackstory(_ agent: AgentRecord, backstory: String) throws {
        let layout = storage(for: agent.id)
        var configuration = try AgentConfiguration.load(from: layout)
        _ = try configuration.requireBackstory()
        configuration.backstory = backstory.trimmingCharacters(in: .whitespacesAndNewlines)
        try configuration.save(to: layout)
    }

    public func loadAgentFolders(_ agent: AgentRecord) throws -> [AgentFolder] {
        try AgentConfiguration.load(from: storage(for: agent.id)).folders
    }

    public func updateAgentFolders(_ agent: AgentRecord, folders: [AgentFolder]) throws {
        let layout = storage(for: agent.id)
        var configuration = try AgentConfiguration.load(from: layout)
        configuration.folders = try AgentFolder.validated(folders, protecting: AgentFolder.protectedLocations(root: rootURL))
        try configuration.save(to: layout)
    }

    public func loadAgentHarnessProfile(_ agent: AgentRecord) throws -> UUID? {
        try AgentConfiguration.load(from: storage(for: agent.id)).harnessProfile
    }

    public func updateAgentHarnessProfile(_ agent: AgentRecord, profile: UUID?) throws {
        let layout = storage(for: agent.id)
        var configuration = try AgentConfiguration.load(from: layout)
        configuration.harnessProfile = profile
        try configuration.save(to: layout)
    }

    public func deleteAgent(_ agent: AgentRecord) throws {
        let package = storage(for: agent.id).package
        guard FileManager.default.fileExists(atPath: package.path) else { throw WorkspaceError.missingAgent(agent.id) }
        let affected = try loadConversations().filter { $0.participantIDs.contains(agent.id) }
        let groups = try affected.filter { $0.kind != .direct }.map { conversation in
            let directory = try WorkspaceMailbox(workspace: conversationDirectory(id: conversation.id), path: "")
            return (conversation, directory, try directory.read("conversation.json", limit: 4 * 1_048_576))
        }
        var moved: [(URL, URL)] = []
        do {
            // Rename first: an unwritable agent parent must fail before touching
            // conversations, and every moved directory remains intact for rollback.
            for original in [package] + affected.filter({ $0.kind == .direct }).map({ conversationDirectory(id: $0.id) }) {
                let staged = original.deletingLastPathComponent().appendingPathComponent(".deleting-" + UUID().uuidString.lowercased())
                try FileManager.default.moveItem(at: original, to: staged)
                moved.append((original, staged))
            }
            for (conversation, directory, _) in groups {
                var updated = conversation
                updated.participantIDs.removeAll { $0 == agent.id }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try directory.writeData(encoder.encode(updated), named: "conversation.json")
            }
        } catch {
            let original = error
            var rollbackError: Error?
            for (_, directory, data) in groups {
                do {
                    if (try? directory.read("conversation.json", limit: 4 * 1_048_576)) != data {
                        try directory.writeData(data, named: "conversation.json")
                    }
                } catch { rollbackError = error }
            }
            for (destination, staged) in moved.reversed() {
                do { try FileManager.default.moveItem(at: staged, to: destination) }
                catch { rollbackError = error }
            }
            if let rollbackError { throw AgentStorageError("Bot deletion failed and could not be fully restored: \(rollbackError.localizedDescription)") }
            throw original
        }
        // Logical deletion is complete. A cleanup failure leaves a hidden intact
        // staging directory; it must not report failure and invite another delete.
        for (_, staged) in moved { try? FileManager.default.removeItem(at: staged) }
    }

    public func loadAgents() throws -> [AgentRecord] {
        try prepare()
        return try agentPackages().map { layout in
            try layout.validate()
            let configuration = try AgentConfiguration.load(from: layout)
            _ = try configuration.requireBackstory()
            return configuration.agent
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func agentPackages() throws -> [AgentStorageLayout] {
        try FileManager.default.contentsOfDirectory(at: agentsURL, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]).compactMap { url in
            let layout = AgentStorageLayout(package: url)
            guard AgentStorageLayout.exists(layout.configuration) else { return nil }
            try AgentStorageLayout.requireDirectory(url)
            try AgentStorageLayout.requireFile(layout.configuration)
            return layout
        }
    }

    private func saveAgentRecord(_ agent: AgentRecord) throws {
        let layout = storage(for: agent.id)
        var configuration = try AgentConfiguration.load(from: layout)
        configuration.agent = agent
        try configuration.save(to: layout)
    }

    private func synchronizeClaudeSkillLinks(in directory: URL) throws -> [String] {
        let root = try WorkspaceMailbox(workspace: directory, path: "")
        // Preserve user redirects, without following them for privileged I/O.
        if root.contains(".claude"), root.linkDestination(".claude") != nil { return [] }
        guard let claude = try? WorkspaceMailbox(workspace: directory, path: ".claude", create: true) else { return [] }
        let destination = "../.agents/skills"
        if claude.linkDestination("skills") == destination { return [".claude/skills"] }
        if !claude.contains("skills") {
            try claude.symlink("skills", destination: destination)
            return [".claude/skills"]
        }
        guard let native = try? WorkspaceMailbox(workspace: directory, path: ".claude/skills") else { return [] }
        let shared = try WorkspaceMailbox(workspace: directory, path: ".agents/skills")
        var managedPaths: [String] = []
        for name in try shared.names().sorted() {
            let target = "../../.agents/skills/" + name
            if native.linkDestination(name) == target {
                managedPaths.append(".claude/skills/" + name)
            } else if !native.contains(name) {
                try native.symlink(name, destination: target)
                managedPaths.append(".claude/skills/" + name)
            }
        }
        return managedPaths
    }

    private static let initialAgentPreferences = "# Preferences\n\n"

    private static func renderedAgentInstructions(backstory: String) -> String {
        let normalizedBackstory = backstory.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # Noodle Agent

        > Generated by Noodle. Do not edit: changes will be overwritten during workspace synchronization. Backstory is stored in Noodle's private configuration and edited through Noodle. Save standing preferences in `preferences.md`. `CLAUDE.md` points to this same generated file.

        ## Backstory

        \(normalizedBackstory)

        \(managedAgentInstructions)
        """
    }

    private static var managedAgentInstructions: String {
        """
        ## Noodle Runtime

        This directory is the bot's persistent workspace. The Backstory section above is this bot's user-authored instructions. Noodle manages the runtime section, Messenger core skill, and assigned MCP connection skills; unrelated skills under `.agents/skills` belong to this bot and are left untouched.

        ## Preferences and memory

        Read `preferences.md` at the start of each session and reread it after changes. Apply it as this bot's standing user preferences, such as tone, formatting, and working style; newer explicit user requests take precedence. When the user asks you to remember a preference, update `preferences.md`. Use `memory.md` for durable facts, decisions, and ongoing context. Noodle creates `preferences.md` with only a heading if missing and preserves both files during workspace synchronization; keep persistent notes there, not in generated instructions.

        ## Messages

        \(MessengerDocumentation.bootstrapInstructions)
        """
    }

    private static var messengerSkill: String {
        """
        ---
        name: messenger
        description: Read and reply to this bot's Noodle direct and group conversations.
        ---

        # Messenger

        \(MessengerDocumentation.skillInstructions)
        """
    }
}
