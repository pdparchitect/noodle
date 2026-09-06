import AppIntents
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

struct NoodleConversationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoodleConversationEntity] {
        let wanted = Set(identifiers.compactMap(UUID.init(uuidString:)))
        return try Self.loadConversations()
            .filter { wanted.contains($0.id) }
            .map(NoodleConversationEntity.init)
    }

    func suggestedEntities() async throws -> [NoodleConversationEntity] {
        try Self.loadConversations().map(NoodleConversationEntity.init)
    }

    func entities(matching string: String) async throws -> [NoodleConversationEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversations = try Self.loadConversations()
        guard !term.isEmpty else { return conversations.map(NoodleConversationEntity.init) }
        return conversations
            .filter { $0.displayName.localizedCaseInsensitiveContains(term) }
            .map(NoodleConversationEntity.init)
    }

    private static func loadConversations() throws -> [BotConversation] {
        let repository = NoodleIntentEnvironment.repository()
        try repository.prepare()
        return try repository.loadConversations().sorted { $0.updatedAt > $1.updatedAt }
    }
}

struct SendNoodleCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Noodle Command"
    static let description = IntentDescription(
        "Send a command to a Noodle bot or group without opening the app."
    )

    @Parameter(
        title: "Agent or Group",
        description: "The bot or group that should receive the command.",
        requestValueDialog: "Who should receive the command?"
    )
    var conversation: NoodleConversationEntity

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
            throw NoodleIntentError.missingConversation
        }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NoodleIntentError.emptyCommand }

        let store = NoodleStore.active ?? NoodleStore(
            repository: NoodleIntentEnvironment.repository()
        )
        store.startMonitoring()
        try store.sendCommand(text, to: conversationID)
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

struct NoodleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendNoodleCommandIntent(),
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

private enum NoodleIntentEnvironment {
    static func repository() -> WorkspaceRepository {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundledMessenger = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/messenger")
        return WorkspaceRepository(
            rootURL: applicationSupport.appendingPathComponent("Noodle", isDirectory: true),
            launcherExecutableURL: FileManager.default.isExecutableFile(atPath: bundledMessenger.path)
                ? bundledMessenger
                : Bundle.main.executableURL
        )
    }
}

private enum NoodleIntentError: LocalizedError {
    case emptyCommand
    case missingConversation

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "Enter a command to send."
        case .missingConversation:
            "That Noodle conversation is no longer available."
        }
    }
}
