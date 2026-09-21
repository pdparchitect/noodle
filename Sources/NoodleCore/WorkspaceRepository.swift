import Darwin
import AppletBridge
import ComputerBridge
import BrowserBridge
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CreatedAgentWorkspace: Sendable {
    public let agent: AgentRecord
    public let conversation: BotConversation
}

public enum WorkspaceError: LocalizedError, Equatable {
    case emptyName
    case missingAgent(UUID)
    case missingConversation(UUID)
    case insufficientGroupParticipants
    case invalidAgentDirectory
    case invalidAttachment
    case missingMessage(UUID)
    case invalidReaction

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name."
        case .missingAgent:
            return "One of the selected bots no longer exists."
        case .missingConversation:
            return "The selected conversation no longer exists."
        case .insufficientGroupParticipants:
            return "Add at least one bot to the group."
        case .invalidAgentDirectory:
            return "The Messenger command is not inside a valid bot workspace."
        case .invalidAttachment:
            return "The selected attachment could not be imported."
        case .missingMessage:
            return "The selected message no longer exists."
        case .invalidReaction:
            return "Choose a single emoji for the reaction."
        }
    }
}

public struct WorkspaceRepository: Sendable {
    public let rootURL: URL
    public let launcherExecutableURL: URL?
    private let discoverAppletApplication: @Sendable () -> URL?


    public init(rootURL: URL, launcherExecutableURL: URL? = nil,
                discoverAppletApplication: @escaping @Sendable () -> URL? = { AppletAgentSkill.installedApplicationURL() }) {
        self.rootURL = AgentStorageLayout.canonicalURL(rootURL)
        self.launcherExecutableURL = launcherExecutableURL?.standardizedFileURL
        self.discoverAppletApplication = discoverAppletApplication
    }

    public var appletExecutableURL: URL? {
        guard let executable = launcherExecutableURL?.deletingLastPathComponent().appendingPathComponent("noodlet"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              AppletAgentSkill.isCompanionInstalled(at: discoverAppletApplication()) else { return nil }
        return executable
    }

    public var agentsURL: URL {
        rootURL.appendingPathComponent("Agents", isDirectory: true)
    }

    public var conversationsURL: URL {
        rootURL.appendingPathComponent("Conversations", isDirectory: true)
    }

    private var conversationStateURL: URL {
        rootURL.appendingPathComponent("conversation-state.json")
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: agentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
    }

    public func loadUnreadConversationIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: conversationStateURL.path) else {
            return []
        }
        return try read(ConversationReadState.self, from: conversationStateURL)
            .unreadConversationIDs
    }

    public func saveUnreadConversationIDs(_ ids: Set<UUID>) throws {
        try prepare()
        try write(
            ConversationReadState(unreadConversationIDs: ids),
            to: conversationStateURL
        )
    }

    public var harnessProfiles: HarnessProfileStore { HarnessProfileStore(root: rootURL) }
    public var managedHarnesses: ManagedHarnessStore { ManagedHarnessStore(root: rootURL) }

    public func directory(for agent: AgentRecord) -> URL {
        directory(forAgentID: agent.id)
    }

    public func directory(forAgentID id: UUID) -> URL {
        storage(for: id).workspace
    }

    public func storage(for id: UUID) -> AgentStorageLayout {
        AgentStorageLayout(package: agentsURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true))
    }

    public func conversationDirectory(id: UUID) -> URL {
        conversationsURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public func attachmentsDirectory(conversationID: UUID) -> URL {
        conversationDirectory(id: conversationID).appendingPathComponent("Attachments", isDirectory: true)
    }

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
        try AgentTips.synchronize(workspace: directory)
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

    public func createGroup(
        named rawName: String,
        publicDescription: String? = nil,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        let name = try ConversationName.validated(rawName)
        let uniqueIDs = Array(Set(participantIDs))
        guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

        let knownIDs = Set(existingAgents.map(\.id))
        guard Set(uniqueIDs).isSubset(of: knownIDs) else {
            throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
        }

        let conversation = BotConversation(
            displayName: name,
            publicDescription: Self.normalizedOptionalText(publicDescription),
            kind: .group,
            participantIDs: uniqueIDs.sorted { $0.uuidString < $1.uuidString },
            createdAt: now,
            updatedAt: now
        )
        try createConversationFiles(conversation)
        return conversation
    }

    public func updateGroupParticipants(
        conversationID: UUID,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        guard let conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.kind == .group
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        return try updateGroup(
            conversationID: conversationID,
            named: conversation.displayName,
            publicDescription: conversation.publicDescription,
            participantIDs: participantIDs,
            existingAgents: existingAgents,
            now: now
        )
    }

    public func updateGroup(
        conversationID: UUID,
        named rawName: String,
        publicDescription: String?,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        guard FileManager.default.fileExists(atPath: conversationDirectory(id: conversationID).path) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        return try withConversationLock(conversationID) {
            guard var conversation = try loadConversations().first(where: {
                $0.id == conversationID && $0.kind == .group
            }) else {
                throw WorkspaceError.missingConversation(conversationID)
            }

            let name = try ConversationName.validated(rawName)
            let uniqueIDs = Array(Set(participantIDs))
            guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

            let knownIDs = Set(existingAgents.map(\.id))
            guard Set(uniqueIDs).isSubset(of: knownIDs) else {
                throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var inboxWrites: [(URL, Data)] = []
            let previousIDs = Set(conversation.participantIDs)
            let addedIDs = Set(uniqueIDs).subtracting(previousIDs)
            let removedIDs = previousIDs.subtracting(uniqueIDs)
            let normalizedDescription = Self.normalizedOptionalText(publicDescription)
            let descriptionChanged = conversation.publicDescription != normalizedDescription
            let needsNotice = !addedIDs.isEmpty || !removedIDs.isEmpty || descriptionChanged
            var messages = needsNotice ? try loadMessages(conversationID: conversation.id) : []
            if !addedIDs.isEmpty {
                let messageCount = messages.count
                let reactionSequence = messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0
                let conversationKey = conversation.id.uuidString.lowercased()
                for agentID in addedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    var inbox = try loadInbox(for: agentID)
                    inbox.conversationOffsets[conversationKey] = messageCount
                    if inbox.reactionOffsets == nil { inbox.reactionOffsets = [:] }
                    inbox.reactionOffsets?[conversationKey] = reactionSequence
                    let file = inboxURL(for: agentID)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    inboxWrites.append((file, try encoder.encode(inbox)))
                }
            }

            conversation.displayName = name
            conversation.publicDescription = normalizedDescription
            conversation.participantIDs = uniqueIDs.sorted { $0.uuidString < $1.uuidString }
            conversation.updatedAt = now
            if needsNotice {
                let namesByID = Dictionary(uniqueKeysWithValues: existingAgents.map { ($0.id, $0.displayName) })
                let addedNames = addedIDs.compactMap { namesByID[$0] }.sorted()
                let removedNames = removedIDs.compactMap { namesByID[$0] }.sorted()
                var changes: [GroupNotice] = []
                if !addedNames.isEmpty {
                    changes.append(.membersAdded(addedNames))
                }
                if !removedNames.isEmpty {
                    changes.append(.membersRemoved(removedNames))
                }
                if descriptionChanged {
                    changes.append(.descriptionChanged(normalizedDescription))
                }
                messages.append(ChatMessage(
                    conversationID: conversation.id,
                    author: .system,
                    body: changes.map(\.body).joined(separator: " "),
                    createdAt: now,
                    delivery: .delivered
                ))
            }
            let directory = conversationDirectory(id: conversation.id)
            var writes = [(directory.appendingPathComponent("conversation.json"), try encoder.encode(conversation))]
            writes.append(contentsOf: inboxWrites)
            if needsNotice { writes.append((directory.appendingPathComponent("messages.json"), try encoder.encode(messages))) }
            // Prepare every destination before publishing anything, then undo only
            // completed writes if a later atomic replacement fails. The conversation
            // lock also protects the notice from racing transcript appends.
            let previous = try writes.map { file, _ in
                FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            }
            var completed = 0
            do {
                for (file, data) in writes {
                    try AtomicFile.write(data, to: file)
                    completed += 1
                }
            } catch {
                let saveError = error
                var restoreError: Error?
                for index in (0..<completed).reversed() {
                    do {
                        if let data = previous[index] { try AtomicFile.write(data, to: writes[index].0) }
                        else { try FileManager.default.removeItem(at: writes[index].0) }
                    } catch { if restoreError == nil { restoreError = error } }
                }
                if let restoreError {
                    throw NSError(domain: "Noodle.GroupEdit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "\(saveError.localizedDescription) Previous group settings could not be fully restored: \(restoreError.localizedDescription)"])
                }
                throw saveError
            }
            return conversation
        }
    }

    public func updateConversation(_ conversation: BotConversation) throws {
        let file = conversationDirectory(id: conversation.id).appendingPathComponent("conversation.json")
        try write(conversation, to: file)
    }

    public func deleteConversation(id: UUID) throws {
        let directory = conversationDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingConversation(id)
        }
        try FileManager.default.removeItem(at: directory)
    }

    public func loadConversations() throws -> [BotConversation] {
        try prepare()
        return try loadChildren(from: conversationsURL, filename: "conversation.json", as: BotConversation.self)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func createConversationFiles(_ conversation: BotConversation) throws {
        try prepare()
        let directory = conversationDirectory(id: conversation.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try write(conversation, to: directory.appendingPathComponent("conversation.json"))
        try write([ChatMessage](), to: directory.appendingPathComponent("messages.json"))
        try FileManager.default.createDirectory(
            at: attachmentsDirectory(conversationID: conversation.id),
            withIntermediateDirectories: true
        )
    }

    public func importAttachment(
        from sourceURL: URL,
        into conversationID: UUID,
        mediaType: String,
        now: Date = Date(),
        voice: VoiceMessage? = nil
    ) throws -> ConversationAttachment {
        if let voice {
            guard sourceURL.isFileURL, mediaType.hasPrefix("audio/"), voice.isValid else {
                throw WorkspaceError.invalidAttachment
            }
        }
        if !sourceURL.isFileURL {
            return try importLinkAttachment(sourceURL, into: conversationID, now: now)
        }
        guard try loadConversations().contains(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkspaceError.invalidAttachment }

        let attachmentID = UUID()
        let resolvedMediaType = detectedImageMediaType(at: sourceURL) ?? mediaType
        let attachment = ConversationAttachment(
            id: attachmentID,
            conversationID: conversationID,
            originalFilename: sourceURL.lastPathComponent,
            storedFilename: storedAttachmentName(id: attachmentID, originalFilename: sourceURL.lastPathComponent),
            mediaType: resolvedMediaType,
            byteCount: Int64(values.fileSize ?? 0),
            createdAt: now,
            voice: voice
        )
        let directory = attachmentsDirectory(conversationID: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceURL,
            to: directory.appendingPathComponent(attachment.storedFilename)
        )
        try write(attachment, to: directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).json"))
        return attachment
    }

    public func importAttachment(
        data: Data,
        originalFilename: String,
        into conversationID: UUID,
        mediaType: String,
        now: Date = Date(),
        linkURL: URL? = nil,
        computer: ComputerCard? = nil,
        browser: BrowserCard? = nil,
        annotation: AttachmentAnnotation? = nil
    ) throws -> ConversationAttachment {
        if let annotation {
            guard annotation.isValid, computer == nil, browser == nil, linkURL == nil, mediaType == annotation.mediaType,
                  let source = try loadAttachments(conversationID: conversationID).first(where: { $0.id == annotation.sourceAttachmentID }),
                  source.originalFilename == annotation.sourceFilename else { throw WorkspaceError.invalidAttachment }
            if let messageID = annotation.sourceMessageID {
                guard try loadMessages(conversationID: conversationID).contains(where: { $0.id == messageID }) else {
                    throw WorkspaceError.invalidAttachment
                }
            }
            if annotation.version == 1 {
                guard data.starts(with: Data("%PDF-".utf8)) else { throw WorkspaceError.invalidAttachment }
            } else if annotation.region != nil {
                guard detectedImageMediaType(in: data) == "image/png",
                      let image = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw WorkspaceError.invalidAttachment }
            } else {
                guard data == Data(annotation.textRepresentation.utf8) else { throw WorkspaceError.invalidAttachment }
            }
        }
        if let computer {
            guard computer.version == 1, mediaType == ComputerCard.mediaType, linkURL == nil, browser == nil,
                  data.count <= 900_000, (try? JSONDecoder().decode(ComputerReference.self, from: data)) == computer.reference else {
                throw WorkspaceError.invalidAttachment
            }
        }
        if let browser {
            guard computer == nil, annotation == nil, linkURL == nil, mediaType == BrowserReference.mediaType,
                  (try? BrowserReference.decode(data)) == browser.reference else { throw WorkspaceError.invalidAttachment }
        }
        if let linkURL {
            guard MessageLink.publicWebURL(from: linkURL, preservingFragment: true) == linkURL || NoodletLink.id(in: linkURL) != nil,
                  mediaType == "application/x-webloc",
                  let bookmark = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                  bookmark["URL"] == linkURL.absoluteString else { throw WorkspaceError.invalidAttachment }
        }
        guard try loadConversations().contains(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let filename = URL(fileURLWithPath: originalFilename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else { throw WorkspaceError.invalidAttachment }

        let attachmentID = UUID()
        let resolvedMediaType = detectedImageMediaType(in: data) ?? mediaType
        let attachment = ConversationAttachment(
            id: attachmentID,
            conversationID: conversationID,
            originalFilename: filename,
            storedFilename: storedAttachmentName(id: attachmentID, originalFilename: filename),
            mediaType: resolvedMediaType,
            byteCount: Int64(data.count),
            createdAt: now,
            url: linkURL,
            computer: computer,
            browser: browser,
            annotation: annotation
        )
        let directory = attachmentsDirectory(conversationID: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent(attachment.storedFilename),
            options: .atomic
        )
        do {
            try write(attachment, to: directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).json"))
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(attachment.storedFilename))
            throw error
        }
        return attachment
    }

    public func importLinkAttachment(_ url: URL, into conversationID: UUID, now: Date = Date()) throws -> ConversationAttachment {
        guard let url = NoodletLink.canonical(url)
            ?? MessageLink.publicWebURL(from: url, preservingFragment: true) else { throw AttachmentSource.InvalidSource() }
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        return try importAttachment(data: data, originalFilename: NoodletLink.id(in: url) != nil ? "Noodlet.webloc" : "\(url.host ?? "Link").webloc", into: conversationID,
            mediaType: "application/x-webloc", now: now, linkURL: url)
    }

    /// Only unsent annotations can change. Check message references under the
    /// same lock as submission, including edits from an already-open preview.
    public func reviseAnnotationComment(_ expected: ConversationAttachment, comment: String, content: Data) throws -> ConversationAttachment {
        try withConversationLock(expected.conversationID) {
            guard let current = try loadAttachments(conversationID: expected.conversationID).first(where: { $0.id == expected.id }),
                  let original = current.annotation, original == expected.annotation,
                  current.storedFilename == expected.storedFilename else { throw WorkspaceError.invalidAttachment }
            guard try !loadMessages(conversationID: current.conversationID)
                .contains(where: { $0.attachments.contains(current.id) }) else { throw WorkspaceError.invalidAttachment }
            let annotation = original.replacingComment(comment)
            guard annotation.isValid else { throw WorkspaceError.invalidAttachment }
            if annotation == original { return current }
            if annotation.version == 1 {
                guard content.starts(with: Data("%PDF-".utf8)) else { throw WorkspaceError.invalidAttachment }
            } else if annotation.region == nil {
                guard content == Data(annotation.textRepresentation.utf8) else { throw WorkspaceError.invalidAttachment }
            } else {
                guard content == (try Data(contentsOf: attachmentFileURL(current))) else { throw WorkspaceError.invalidAttachment }
            }
            let updated = ConversationAttachment(id: current.id,
                conversationID: current.conversationID, originalFilename: current.originalFilename,
                storedFilename: storedAttachmentName(id: UUID(), originalFilename: current.originalFilename),
                mediaType: current.mediaType, byteCount: Int64(content.count),
                createdAt: current.createdAt, annotation: annotation)
            let file = attachmentFileURL(updated)
            try content.write(to: file, options: .atomic)
            do {
                try write(updated, to: attachmentsDirectory(conversationID: current.conversationID)
                    .appendingPathComponent("\(updated.id.uuidString.lowercased()).json"))
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            try? FileManager.default.removeItem(at: attachmentFileURL(current))
            return updated
        }
    }

    public func loadAttachments(conversationID: UUID) throws -> [ConversationAttachment] {
        let directory = attachmentsDirectory(conversationID: conversationID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { metadataURL in
            let attachment = try read(ConversationAttachment.self, from: metadataURL)
            if attachment.url != nil { return attachment }
            let fileURL = attachmentFileURL(attachment)
            guard let detectedMediaType = detectedImageMediaType(at: fileURL),
                  detectedMediaType != attachment.mediaType else { return attachment }

            let repaired = ConversationAttachment(
                id: attachment.id,
                conversationID: attachment.conversationID,
                originalFilename: attachment.originalFilename,
                storedFilename: attachment.storedFilename,
                mediaType: detectedMediaType,
                byteCount: attachment.byteCount,
                createdAt: attachment.createdAt,
                voice: attachment.voice,
                computer: attachment.computer,
                browser: attachment.browser,
                annotation: attachment.annotation
            )
            try? write(repaired, to: metadataURL)
            return repaired
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    private func detectedImageMediaType(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return detectedImageMediaType(from: source)
    }

    private func detectedImageMediaType(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return detectedImageMediaType(from: source)
    }

    private func detectedImageMediaType(from source: CGImageSource) -> String? {
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let contentType = UTType(typeIdentifier),
              contentType.conforms(to: .image) else { return nil }
        return contentType.preferredMIMEType
    }

    public func attachmentFileURL(_ attachment: ConversationAttachment) -> URL {
        attachmentsDirectory(conversationID: attachment.conversationID)
            .appendingPathComponent(attachment.storedFilename)
    }

    public func removeAttachment(_ attachment: ConversationAttachment) throws {
        let file = attachmentFileURL(attachment)
        let metadata = attachmentsDirectory(conversationID: attachment.conversationID)
            .appendingPathComponent("\(attachment.id.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        if FileManager.default.fileExists(atPath: metadata.path) {
            try FileManager.default.removeItem(at: metadata)
        }
    }

    private func storedAttachmentName(id: UUID, originalFilename: String) -> String {
        let suffix = URL(fileURLWithPath: originalFilename).pathExtension
        return id.uuidString.lowercased() + (suffix.isEmpty ? "" : ".\(suffix)")
    }

    public func append(_ message: ChatMessage) throws {
        let file = conversationDirectory(id: message.conversationID).appendingPathComponent("messages.json")
        try withConversationLock(message.conversationID) {
            var messages = try loadMessages(conversationID: message.conversationID)
            messages.append(message)
            try write(messages, to: file)
        }
    }

    private func inboxURL(for agentID: UUID) -> URL {
        // Mutable messaging state is not skill/configuration data. Codex keeps
        // .agents read-only even within a writable workspace.
        directory(forAgentID: agentID).appendingPathComponent(".noodle/inbox.json")
    }

    private func loadInbox(for agentID: UUID) throws -> AgentInbox {
        let current = inboxURL(for: agentID)
        if FileManager.default.fileExists(atPath: current.path) {
            return try read(AgentInbox.self, from: current)
        }
        // Lazy migration: preserve the old cursor (including reaction offsets),
        // leave its file untouched, and write the new location only on consume.
        let legacy = directory(forAgentID: agentID).appendingPathComponent(".agents/inbox.json")
        if FileManager.default.fileExists(atPath: legacy.path) {
            return try read(AgentInbox.self, from: legacy)
        }
        return AgentInbox()
    }

    private func saveInbox(_ inbox: AgentInbox, for agentID: UUID) throws {
        let file = inboxURL(for: agentID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(inbox, to: file)
    }

    public func latestMessages(
        for agentID: UUID,
        consuming: Bool = true,
        in conversationID: UUID? = nil,
        includingRead: Bool = false,
        preparing: (([MessengerDelivery]) throws -> Void)? = nil
    ) throws -> [MessengerDelivery] {
        let agents = try loadAgents()
        guard let readingAgent = agents.first(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let me = MessengerIdentity(handle: .me, agentID: agentID, displayName: readingAgent.displayName)
        let conversations = try loadConversations().filter {
            $0.participantIDs.contains(agentID) && (conversationID == nil || $0.id == conversationID)
        }
        if let conversationID, conversations.isEmpty { throw WorkspaceError.missingConversation(conversationID) }
        var inbox = try loadInbox(for: agentID)
        var deliveries: [MessengerDelivery] = []
        var fetched: [(conversationID: UUID, count: Int)] = []

        func identity(for author: MessageAuthor) -> MessengerIdentity {
            switch author {
            case .user: return MessengerIdentity(handle: .user, displayName: "User")
            case .agent(let id):
                return id == agentID ? me : MessengerIdentity(
                    handle: .bot, agentID: id,
                    displayName: agentsByID[id]?.displayName ?? "Unknown Bot"
                )
            case .system: return MessengerIdentity(handle: .system, displayName: "Noodle")
            }
        }

        for conversation in conversations {
            let messages = try loadMessages(conversationID: conversation.id)
            let key = conversation.id.uuidString.lowercased()
            let offset = includingRead ? 0 : min(inbox.conversationOffsets[key, default: 0], messages.count)
            let attachments = try loadAttachments(conversationID: conversation.id)
            let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
            let participants = conversation.participantIDs.map { participantID in
                if participantID == agentID { return me }
                return MessengerIdentity(
                    handle: .bot,
                    agentID: participantID,
                    displayName: agentsByID[participantID]?.displayName ?? "Unknown Bot"
                )
            }

            func delivery(for message: ChatMessage) -> MessengerDelivery {
                var delivery = MessengerDelivery(
                        me: me,
                        conversation: conversation,
                        participants: participants,
                        sender: identity(for: message.author),
                        message: message,
                        attachments: message.attachments.compactMap { attachmentID in
                            guard let attachment = byID[attachmentID] else { return nil }
                            return MessengerAttachment(
                                attachment: attachment,
                                absolutePath: attachmentFileURL(attachment).standardizedFileURL.path
                            )
                        }
                )
                delivery.reactions = (message.reactions ?? []).map {
                    MessengerReaction(emoji: $0.emoji, sender: identity(for: $0.author))
                }
                return delivery
            }

            for message in messages.dropFirst(offset) {
                if !includingRead, case .agent(let authorID) = message.author, authorID == agentID { continue }
                deliveries.append(delivery(for: message))
            }

            let changes = messages.flatMap { $0.reactionChanges ?? [] }
            let reactionOffset = inbox.reactionOffsets?[key] ?? 0
            if !includingRead {
                let byMessageID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                for change in changes.sorted(by: { $0.sequence < $1.sequence }) where change.sequence > reactionOffset {
                    if change.author == .agent(agentID) { continue }
                    guard let message = byMessageID[change.messageID] else { continue }
                    var item = delivery(for: message)
                    item.reactionChange = MessengerReactionChange(
                        id: change.id, emoji: change.emoji, removed: change.removed,
                        sender: identity(for: change.author), createdAt: change.createdAt
                    )
                    deliveries.append(item)
                }
            }
            if consuming && !includingRead {
                inbox.conversationOffsets[key] = messages.count
                if inbox.reactionOffsets == nil { inbox.reactionOffsets = [:] }
                inbox.reactionOffsets?[key] = changes.map(\.sequence).max() ?? 0
                if messages.contains(where: { $0.author == .user && $0.delivery == .queued }) {
                    fetched.append((conversation.id, messages.count))
                }
            }
        }

        deliveries.sort {
            ($0.reactionChange?.createdAt ?? $0.message.createdAt) < ($1.reactionChange?.createdAt ?? $1.message.createdAt)
        }
        // Broker attachment delivery must succeed before advancing the inbox.
        try preparing?(deliveries)
        if consuming && !includingRead {
            try saveInbox(inbox, for: agentID)
            // Display status only: the inbox has advanced, so a failure here must not fail the read.
            for item in fetched { try? markDelivered(conversationID: item.conversationID, upTo: item.count) }
        }
        return deliveries
    }

    /// A user's message is delivered once any recipient's harness has fetched it.
    private func markDelivered(conversationID: UUID, upTo count: Int) throws {
        try withConversationLock(conversationID) {
            var messages = try loadMessages(conversationID: conversationID)
            let queued = messages.indices.prefix(count).filter {
                messages[$0].author == .user && messages[$0].delivery == .queued
            }
            guard !queued.isEmpty else { return }
            for index in queued { messages[index].delivery = .delivered }
            try write(messages, to: conversationDirectory(id: conversationID).appendingPathComponent("messages.json"))
        }
    }

    public func participantRoster(for agentID: UUID, conversationID: UUID) throws -> MessengerRoster {
        let agents = try loadAgents()
        guard let readingAgent = agents.first(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        guard let conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.participantIDs.contains(agentID)
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let messages = try loadMessages(conversationID: conversationID)
        var lastActivity: [UUID: Date] = [:]
        for message in messages {
            guard case .agent(let authorID) = message.author else { continue }
            lastActivity[authorID] = max(lastActivity[authorID] ?? .distantPast, message.createdAt)
        }

        let me = MessengerIdentity(handle: .me, agentID: agentID, displayName: readingAgent.displayName)
        let participants = conversation.participantIDs.compactMap { participantID -> MessengerParticipantStatus? in
            guard let agent = agentsByID[participantID] else { return nil }
            let identity = participantID == agentID
                ? me
                : MessengerIdentity(handle: .bot, agentID: participantID, displayName: agent.displayName)
            return MessengerParticipantStatus(
                participant: identity,
                publicDescription: agent.publicDescription,
                lastActiveAt: lastActivity[participantID]
            )
        }.sorted {
            if $0.participant.handle == .me { return true }
            if $1.participant.handle == .me { return false }
            return $0.participant.displayName.localizedCaseInsensitiveCompare(
                $1.participant.displayName
            ) == .orderedAscending
        }
        return MessengerRoster(me: me, conversation: conversation, participants: participants)
    }

    @discardableResult
    public func setReaction(
        conversationID: UUID, messageID: UUID, author: MessageAuthor,
        emoji: String, present: Bool, now: Date = Date()
    ) throws -> ChatMessage {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MessageReaction.isValidEmoji(emoji) else {
            throw WorkspaceError.invalidReaction
        }
        guard let conversation = try loadConversations().first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        switch author {
        case .user: break
        case .agent(let id):
            guard conversation.participantIDs.contains(id), try loadAgents().contains(where: { $0.id == id }) else {
                throw WorkspaceError.missingAgent(id)
            }
        case .system: throw WorkspaceError.invalidReaction
        }
        return try withConversationLock(conversationID) {
            var messages = try loadMessages(conversationID: conversationID)
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
                throw WorkspaceError.missingMessage(messageID)
            }
            var reactions = messages[index].reactions ?? []
            let existing = reactions.firstIndex { $0.author == author && $0.emoji == emoji }
            guard present != (existing != nil) else { return messages[index] }
            if present {
                reactions.append(MessageReaction(id: UUID(), author: author, emoji: emoji, createdAt: now))
            } else if let existing {
                reactions.remove(at: existing)
            }
            let sequence = (messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0) + 1
            let change = MessageReactionChange(
                id: UUID(), conversationID: conversationID, messageID: messageID,
                sequence: sequence, author: author, emoji: emoji, removed: !present, createdAt: now
            )
            messages[index].reactions = reactions
            messages[index].reactionChanges = (messages[index].reactionChanges ?? []) + [change]
            // Persist the badge and its inbox event in the same atomic write.
            try write(messages, to: conversationDirectory(id: conversationID).appendingPathComponent("messages.json"))
            return messages[index]
        }
    }

    public func sendAgentMessage(
        agentID: UUID,
        conversationID: UUID,
        body: String,
        attachmentIDs: [UUID] = [],
        now: Date = Date()
    ) throws -> ChatMessage {
        let name = try validatedName(body)
        guard try loadAgents().contains(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        guard let conversation = try loadConversations().first(where: { $0.id == conversationID }),
              conversation.participantIDs.contains(agentID) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let availableAttachmentIDs = Set(try loadAttachments(conversationID: conversationID).map(\.id))
        guard Set(attachmentIDs).count == attachmentIDs.count,
              Set(attachmentIDs).isSubset(of: availableAttachmentIDs) else {
            throw WorkspaceError.invalidAttachment
        }
        let message = ChatMessage(
            conversationID: conversationID,
            author: .agent(agentID),
            body: name,
            createdAt: now,
            delivery: .delivered,
            attachmentIDs: attachmentIDs
        )
        try append(message)
        var updated = conversation
        updated.updatedAt = now
        try updateConversation(updated)
        return message
    }

    public func notificationRecipientIDs(for messages: [ChatMessage]) throws -> Set<UUID> {
        let conversationsByID = Dictionary(
            uniqueKeysWithValues: try loadConversations().map { ($0.id, $0) }
        )
        var recipientIDs = Set<UUID>()

        for message in messages {
            guard case .agent(let senderID) = message.author,
                  let conversation = conversationsByID[message.conversationID],
                  conversation.kind == .group else { continue }

            recipientIDs.formUnion(
                conversation.participantIDs.filter { $0 != senderID }
            )
        }

        return recipientIDs
    }

    public func sendUserMessage(
        conversationID: UUID,
        body: String,
        attachmentIDs: [UUID] = [],
        now: Date = Date()
    ) throws -> ChatMessage {
        let text = try validatedName(body)
        guard var conversation = try loadConversations().first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let message = ChatMessage(
            conversationID: conversationID,
            author: .user,
            body: text,
            createdAt: now,
            delivery: .queued,
            attachmentIDs: attachmentIDs
        )
        try append(message)
        conversation.updatedAt = now
        try updateConversation(conversation)
        return message
    }

    /// Queue retries reuse the request UUID, so restarting after delivery never sends twice.
    public func sendSharedMessage(_ request: SharedRequest, files: [URL]) throws -> ChatMessage {
        guard var conversation = try loadConversations().first(where: { $0.id == request.conversationID }),
              request.filenames.count == files.count else { throw SharedInboxError.invalidRequest }
        return try withConversationLock(conversation.id) {
            var messages = try loadMessages(conversationID: conversation.id)
            if let existing = messages.first(where: { $0.id == request.id }) { return existing }
            var imported: [ConversationAttachment] = []
            do {
                for file in files {
                    imported.append(try importAttachment(from: file, into: conversation.id,
                        mediaType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
                }
                let message = ChatMessage(id: request.id, conversationID: conversation.id, author: .user,
                    body: request.body.isEmpty ? "Sent \(files.count) attachment\(files.count == 1 ? "" : "s")" : request.body,
                    delivery: .queued, attachmentIDs: imported.map(\.id))
                messages.append(message)
                try write(messages, to: conversationDirectory(id: conversation.id).appendingPathComponent("messages.json"))
                conversation.updatedAt = message.createdAt
                try? updateConversation(conversation)
                return message
            } catch {
                for attachment in imported { try? removeAttachment(attachment) }
                throw error
            }
        }
    }

    public func loadMessages(conversationID: UUID) throws -> [ChatMessage] {
        let file = conversationDirectory(id: conversationID).appendingPathComponent("messages.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try read([ChatMessage].self, from: file)
    }

    private func validatedName(_ rawName: String) throws -> String {
        let value = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WorkspaceError.emptyName }
        return value
    }

    private static func normalizedOptionalText(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func loadChildren<Value: Decodable>(
        from parent: URL,
        filename: String,
        as type: Value.Type
    ) throws -> [Value] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try directories.compactMap { directory in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            let file = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try read(Value.self, from: file)
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(encoder.encode(value), to: url)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func withConversationLock<Value>(_ id: UUID, operation: () throws -> Value) throws -> Value {
        let lockURL = conversationDirectory(id: id).appendingPathComponent(".messages.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

private struct ConversationReadState: Codable {
    let version: Int
    let unreadConversationIDs: Set<UUID>

    init(unreadConversationIDs: Set<UUID>) {
        version = 1
        self.unreadConversationIDs = unreadConversationIDs
    }
}
