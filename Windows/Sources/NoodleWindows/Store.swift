import Foundation
import HubLink
import NoodleCore
import NoodleRuntime

/// What the window shows of Noodle's store, read through NoodleCore. The person's messages are saved to it; no bot
/// runs here, so nothing is woken by them yet.
struct Store {
    let folder: URL
    let repository: WorkspaceRepository
    let agents: [AgentRecord]
    /// The sidebar's sections, ordered as the Mac app orders them by default.
    let pinned: [BotConversation], bots: [BotConversation], groups: [BotConversation]
    let unread: Set<UUID>
    private let messagesByConversation: [UUID: [ChatMessage]]

    /// NOODLE_DATA when set, else %LOCALAPPDATA%\Noodle.
    static var defaultFolder: URL {
        let environment = ProcessInfo.processInfo.environment
        if let data = environment["NOODLE_DATA"], !data.isEmpty { return URL(fileURLWithPath: data, isDirectory: true) }
        let local = environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("Noodle", isDirectory: true)
    }

    init(folder: URL = Store.defaultFolder) throws {
        self.folder = folder
        let repository = WorkspaceRepository(rootURL: folder)
        self.repository = repository
        let agents = try repository.loadAgents()
        self.agents = agents
        let unread = try repository.loadUnreadConversationIDs()
        self.unread = unread
        let shown = try repository.loadConversations().filter { $0.isShownHere && !$0.isArchived(among: agents) }
        let messages = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, (try? repository.loadMessages(conversationID: $0.id)) ?? []) })
        messagesByConversation = messages
        let sections = ConversationOrder.standard.sections(shown, pinned: try repository.loadPinnedConversationIDs(),
                                                           lastActivity: { $0.lastMessageDate(in: messages[$0.id] ?? []) },
                                                           isUnread: { unread.contains($0.id) })
        pinned = sections.pinned
        bots = sections.rest.filter { $0.kind == .direct }
        groups = sections.rest.filter { $0.kind == .group }
    }

    func conversation(withID id: UUID) -> BotConversation? {
        (pinned + bots + groups).first { $0.id == id }
    }

    func agent(_ id: UUID) -> AgentRecord? { agents.first { $0.id == id } }

    func messages(in conversation: BotConversation) -> [ChatMessage] { messagesByConversation[conversation.id] ?? [] }

    func lastMessageDate(of conversation: BotConversation) -> Date { conversation.lastMessageDate(in: messages(in: conversation)) }

    /// What the bot or group is for.
    func about(_ conversation: BotConversation) -> String? {
        conversation.kind == .direct ? conversation.participants(among: agents).first?.publicDescription : conversation.publicDescription
    }

    /// What the bot is for, or which bots are in the group.
    func detail(of conversation: BotConversation) -> String? {
        conversation.kind == .direct
            ? conversation.participants(among: agents).first?.publicDescription
            : conversation.shownParticipants(among: agents).map(\.displayName).joined(separator: ", ")
    }

    func composerUnavailableReason(for conversation: BotConversation) -> String? {
        ComposerAvailability.unavailableReason(for: conversation, members: conversation.participants(among: agents), member: "bot")
    }

    /// Saves the person's message to the conversation, as the Mac sends it, with no bot to wake.
    @MainActor func send(_ text: String, to conversation: BotConversation) throws -> ChatMessage {
        try PersonMessage.send(text, to: conversation, members: conversation.participants(among: agents), runtime: nil,
                               repository: repository)
    }

    func authorName(_ author: MessageAuthor) -> String {
        switch author {
        case .user: "You"
        case .agent(let id): agent(id)?.displayName ?? "Bot"
        case .system: "Noodle"
        }
    }
}
