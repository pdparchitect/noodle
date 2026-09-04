import AppIntents
import Foundation
import SuperBotCore

struct SuperBotConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "SuperBot Conversation",
        numericFormat: "\(placeholder: .int) SuperBot conversations"
    )
    static let defaultQuery = SuperBotConversationQuery()

    let id: String
    let name: String
    let kind: ConversationKind

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: kind == .direct ? "Bot" : "Group",
            image: .init(systemName: kind == .direct ? "person.crop.circle" : "person.3.fill")
        )
    }

    init(_ conversation: BotConversation) {
        id = conversation.id.uuidString
        name = conversation.displayName
        kind = conversation.kind
    }
}

struct SuperBotConversationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SuperBotConversationEntity] {
        let wanted = Set(identifiers.compactMap(UUID.init(uuidString:)))
        return try Self.loadConversations()
            .filter { wanted.contains($0.id) }
            .map(SuperBotConversationEntity.init)
    }

    func suggestedEntities() async throws -> [SuperBotConversationEntity] {
        try Self.loadConversations().map(SuperBotConversationEntity.init)
    }

    func entities(matching string: String) async throws -> [SuperBotConversationEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversations = try Self.loadConversations()
        guard !term.isEmpty else { return conversations.map(SuperBotConversationEntity.init) }
        return conversations
            .filter { $0.displayName.localizedCaseInsensitiveContains(term) }
            .map(SuperBotConversationEntity.init)
    }

    private static func loadConversations() throws -> [BotConversation] {
        let repository = SuperBotIntentEnvironment.repository()
        try repository.prepare()
        return try repository.loadConversations().sorted { $0.updatedAt > $1.updatedAt }
    }
}

struct SendSuperBotCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Send SuperBot Command"
    static let description = IntentDescription(
        "Send a command to a SuperBot bot or group without opening the app."
    )

    @Parameter(
        title: "Agent or Group",
        description: "The bot or group that should receive the command.",
        requestValueDialog: "Who should receive the command?"
    )
    var conversation: SuperBotConversationEntity

    @Parameter(
        title: "Command",
        description: "The command or message to send.",
        requestValueDialog: "What do you want to send?"
    )
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$command) to \(\.$conversation)")
    }

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let conversationID = UUID(uuidString: conversation.id) else {
            throw SuperBotIntentError.missingConversation
        }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SuperBotIntentError.emptyCommand }

        let store = SuperBotStore.active ?? SuperBotStore(
            repository: SuperBotIntentEnvironment.repository()
        )
        store.startAgents()
        try store.sendCommand(text, to: conversationID)
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

struct SuperBotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendSuperBotCommandIntent(),
            phrases: [
                "Send a command with \(.applicationName)",
                "Message \(\.$conversation) with \(.applicationName)",
                "Tell \(\.$conversation) using \(.applicationName)"
            ],
            shortTitle: "Send Command",
            systemImageName: "paperplane.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}

private enum SuperBotIntentEnvironment {
    static func repository() -> WorkspaceRepository {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundledMessenger = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/messenger")
        return WorkspaceRepository(
            rootURL: applicationSupport.appendingPathComponent("SuperBot", isDirectory: true),
            launcherExecutableURL: FileManager.default.isExecutableFile(atPath: bundledMessenger.path)
                ? bundledMessenger
                : Bundle.main.executableURL
        )
    }
}

private enum SuperBotIntentError: LocalizedError {
    case emptyCommand
    case missingConversation

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "Enter a command to send."
        case .missingConversation:
            "That SuperBot conversation is no longer available."
        }
    }
}
