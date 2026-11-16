import AppIntents
import AppKit
import Foundation
import NoodleCore

struct NoodleConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Noodle Conversation",
        numericFormat: "\(placeholder: .int) Noodle conversations"
    )
    static let defaultQuery = NoodleConversationQuery()

    let id: String
    let name: String
    let kind: ConversationKind

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: kind == .direct ? "Agent" : "Group",
            image: .init(systemName: kind == .direct ? "person.crop.circle" : "person.3.fill")
        )
    }

    init(_ conversation: BotConversation) {
        id = conversation.id.uuidString
        name = conversation.displayName
        kind = conversation.kind
    }
}

struct NoodleConversationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoodleConversationEntity] {
        try Self.loadConversations(identifiers: identifiers).map(NoodleConversationEntity.init)
    }

    func suggestedEntities() async throws -> [NoodleConversationEntity] {
        try Self.loadConversations().map(NoodleConversationEntity.init)
    }

    func entities(matching string: String) async throws -> [NoodleConversationEntity] {
        try Self.loadConversations(matching: string).map(NoodleConversationEntity.init)
    }

    /// The bots and groups shown on this Mac, newest first: all of them, those with the identifiers, or those whose
    /// names contain the search.
    static func loadConversations(identifiers: [String]? = nil, matching string: String = "") throws -> [BotConversation] {
        let repository = NoodleIntentEnvironment.repository()
        try repository.prepare()
        let archivedAgentIDs = Set(try repository.loadAgents().filter { $0.archivedAt != nil }.map(\.id))
        let wanted = identifiers.map { Set($0.compactMap(UUID.init(uuidString:))) }
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try repository.loadConversations()
            .filter { $0.isShownHere && $0.archivedAt == nil && !($0.kind == .direct && $0.participantIDs.allSatisfy(archivedAgentIDs.contains)) }
            .filter { wanted?.contains($0.id) ?? true }
            .filter { term.isEmpty || $0.displayName.localizedCaseInsensitiveContains(term) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// A bot, by its chat, for what only a bot can do, such as taking a call.
struct NoodleAgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Noodle Agent",
        numericFormat: "\(placeholder: .int) Noodle agents"
    )
    static let defaultQuery = NoodleAgentQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "person.crop.circle"))
    }

    init(_ conversation: BotConversation) {
        id = conversation.id.uuidString
        name = conversation.displayName
    }
}

struct NoodleAgentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoodleAgentEntity] {
        try Self.bots(NoodleConversationQuery.loadConversations(identifiers: identifiers))
    }

    func suggestedEntities() async throws -> [NoodleAgentEntity] {
        try Self.bots(NoodleConversationQuery.loadConversations())
    }

    func entities(matching string: String) async throws -> [NoodleAgentEntity] {
        try Self.bots(NoodleConversationQuery.loadConversations(matching: string))
    }

    private static func bots(_ conversations: [BotConversation]) -> [NoodleAgentEntity] {
        conversations.filter { $0.kind == .direct }.map(NoodleAgentEntity.init)
    }
}

struct SendNoodleCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Agent"
    static let description = IntentDescription(
        "Send a message or files to a Noodle agent or group of agents. Replies appear in the conversation in Noodle.",
        searchKeywords: ["Send to Bot", "Send to a Bot", "Bot", "Send File", "Send and Open"]
    )

    @Parameter(
        title: "Agent or Group",
        description: "The agent or group of agents that should receive the message.",
        requestValueDialog: "Who should receive the message?"
    )
    var conversation: NoodleConversationEntity

    @Parameter(
        title: "Message",
        description: "The question, instruction, or message to send.",
        requestValueDialog: "What would you like to send?"
    )
    var command: String?

    @Parameter(title: "Files", description: "Files to send with the message.")
    var files: [IntentFile]?

    @Parameter(title: "Open Chat", description: "Open the chat in Noodle after sending.", default: false)
    var opensConversation: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$command) to \(\.$conversation)") {
            \.$files
            \.$opensConversation
        }
    }

    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let conversationID = try ConversationIntentSupport.id(of: conversation.id)
        let text = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = files ?? []
        guard !text.isEmpty || !files.isEmpty else { throw $command.needsValueError("What would you like to send?") }

        let store = NoodleIntentEnvironment.store()
        try store.sendCommand(text, files: files.map(ConversationIntentSupport.payload), to: conversationID)
        if opensConversation {
            try await continueInForeground(alwaysConfirm: false)
            try store.openConversation(conversationID)
            NSApp.activate()
        }
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

/// Opens a bot's or group's chat, as clicking its notification does.
struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription(
        "Open your chat with a Noodle agent or group of agents.",
        searchKeywords: ["Open Chat with Agent", "Open Chat with Bot", "Open Conversation", "Conversation", "Chat with Bot",
                         "Bot", "Group"]
    )

    @Parameter(title: "Agent or Group", requestValueDialog: "Which chat should Noodle open?")
    var conversation: NoodleConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$conversation)")
    }

    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        try NoodleIntentEnvironment.store().openConversation(ConversationIntentSupport.id(of: conversation.id))
        NSApp.activate()
        return .result()
    }
}

/// Calls a bot, opening its chat; one that can't take calls just has its chat opened.
struct CallAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Agent"
    static let description = IntentDescription(
        "Call a Noodle agent. If it can't take calls, your chat with it opens instead.",
        searchKeywords: ["Call Bot", "Call a Bot", "Bot"]
    )

    @Parameter(title: "Agent", requestValueDialog: "Which agent should Noodle call?")
    var bot: NoodleAgentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Call \(\.$bot)")
    }

    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        try NoodleIntentEnvironment.store().callFromShortcut(ConversationIntentSupport.id(of: bot.id))
        NSApp.activate()
        return .result()
    }
}

struct NoodleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendNoodleCommandIntent(),
            phrases: [
                "Send to an agent with \(.applicationName)",
                "Send to a bot with \(.applicationName)",
                "Send to \(\.$conversation) with \(.applicationName)",
                "Send a command with \(.applicationName)",
                "Message \(\.$conversation) with \(.applicationName)",
                "Tell \(\.$conversation) using \(.applicationName)"
            ],
            shortTitle: "Send to Agent",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open a chat in \(.applicationName)",
                "Open chat with \(\.$conversation) in \(.applicationName)",
                "Open \(\.$conversation) in \(.applicationName)",
                "Open my chat with \(\.$conversation) in \(.applicationName)"
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: CallAgentIntent(),
            phrases: [
                "Call an agent with \(.applicationName)",
                "Call a bot with \(.applicationName)",
                "Call \(\.$bot) with \(.applicationName)"
            ],
            shortTitle: "Call Agent",
            systemImageName: "phone.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}

extension NoodleStore {
    /// Opens a bot's or group's conversation where it shows, as clicking its notification does.
    func openConversation(_ conversationID: UUID) throws {
        guard conversations.contains(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        openNotification(conversationID: conversationID, messageID: nil)
    }

    /// Opens a bot's chat and calls it. One that can't take calls just has its chat opened, and a call already with
    /// it goes on; a call with another bot ends, as calling from that bot's profile does.
    func callFromShortcut(_ conversationID: UUID, media: (any VoiceCallMedia)? = nil) throws {
        try openConversation(conversationID)
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              voiceCalls.call?.conversationID != conversationID else { return }
        startVoiceCall(in: conversation, media: media)
    }
}

private enum NoodleIntentEnvironment {
    static func repository() -> WorkspaceRepository {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundledMessenger = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/messenger")
        return WorkspaceRepository(
            rootURL: HarnessStorage.dataRoot(applicationSupport: applicationSupport),
            launcherExecutableURL: FileManager.default.isExecutableFile(atPath: bundledMessenger.path)
                ? bundledMessenger
                : Bundle.main.executableURL
        )
    }

    @MainActor
    static func store() -> NoodleStore {
        let store = NoodleStore.active ?? NoodleStore(repository: repository())
        store.startMonitoring()
        return store
    }
}
