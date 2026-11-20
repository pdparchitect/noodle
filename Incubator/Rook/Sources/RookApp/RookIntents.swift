import AppIntents
import AppKit
import Foundation
import NoodleCore

// Noodle's Shortcuts actions, as Rook's: send to a Mission, group or agent, open it, or call an agent.
// Shortcuts shows these words as they are written, so they are Rook's own; the files and conversations are
// read with Noodle's ConversationIntentSupport.

/// Rook, for the actions, which run inside it.
@MainActor enum RookIntentApp {
    static weak var delegate: RookDelegate?

    static func app() throws -> RookDelegate {
        guard let delegate else { throw ConversationIntentError.missingConversation }
        return delegate
    }

    /// The conversations something can be sent to, newest first: all, those with the identifiers, or those whose
    /// names contain the search.
    static func conversations(identifiers: [String]? = nil, matching string: String = "") -> [BotConversation] {
        guard let model = delegate?.model else { return [] }
        let wanted = identifiers.map { Set($0.compactMap(UUID.init(uuidString:))) }
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.conversations
            .filter(model.takesMessages)
            .filter { wanted?.contains($0.id) ?? true }
            .filter { term.isEmpty || model.title(of: $0).localizedCaseInsensitiveContains(term) }
            .sorted { model.lastActivity(of: $0) > model.lastActivity(of: $1) }
    }
}

struct RookConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Rook Conversation",
        numericFormat: "\(placeholder: .int) Rook conversations"
    )
    static let defaultQuery = RookConversationQuery()

    let id: String
    let name: String
    /// Mission, Group or Agent.
    let kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)", image: .init(systemName: kind == "Agent" ? "person.crop.circle"
            : kind == "Group" ? "person.3.fill" : "shield.lefthalf.filled"))
    }

    @MainActor init(_ conversation: BotConversation) {
        let model = RookIntentApp.delegate?.model
        id = conversation.id.uuidString
        name = model?.title(of: conversation) ?? conversation.displayName
        kind = model?.mission(conversation.id) != nil ? "Mission" : conversation.kind == .direct ? "Agent" : "Group"
    }
}

struct RookConversationQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [RookConversationEntity] {
        RookIntentApp.conversations(identifiers: identifiers).map(RookConversationEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [RookConversationEntity] {
        RookIntentApp.conversations().map(RookConversationEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [RookConversationEntity] {
        RookIntentApp.conversations(matching: string).map(RookConversationEntity.init)
    }
}

/// An agent, by its own conversation, for what only an agent can do, such as taking a call.
struct RookAgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Rook Agent",
        numericFormat: "\(placeholder: .int) Rook agents"
    )
    static let defaultQuery = RookAgentQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "person.crop.circle"))
    }

    @MainActor init(_ conversation: BotConversation) {
        id = conversation.id.uuidString
        name = RookIntentApp.delegate?.model.title(of: conversation) ?? conversation.displayName
    }
}

struct RookAgentQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [RookAgentEntity] {
        Self.agents(RookIntentApp.conversations(identifiers: identifiers))
    }

    @MainActor func suggestedEntities() async throws -> [RookAgentEntity] { Self.agents(RookIntentApp.conversations()) }

    @MainActor func entities(matching string: String) async throws -> [RookAgentEntity] {
        Self.agents(RookIntentApp.conversations(matching: string))
    }

    @MainActor private static func agents(_ conversations: [BotConversation]) -> [RookAgentEntity] {
        conversations.filter { $0.kind == .direct }.map(RookAgentEntity.init)
    }
}

struct SendToRookIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Agent"
    static let description = IntentDescription(
        "Send a message or files to a Rook Mission, group or agent. Replies appear in the conversation in Rook.",
        searchKeywords: ["Send to Mission", "Mission", "Send File", "Send and Open"]
    )

    @Parameter(title: "Conversation", description: "The Mission, group or agent that should receive the message.",
               requestValueDialog: "Who should receive the message?")
    var conversation: RookConversationEntity

    @Parameter(title: "Message", description: "The question, instruction, or message to send.",
               requestValueDialog: "What would you like to send?")
    var command: String?

    @Parameter(title: "Files", description: "Files to send with the message.")
    var files: [IntentFile]?

    @Parameter(title: "Open Conversation", description: "Open the conversation in Rook after sending.", default: false)
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
        let id = try ConversationIntentSupport.id(of: conversation.id)
        let text = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = files ?? []
        guard !text.isEmpty || !files.isEmpty else { throw $command.needsValueError("What would you like to send?") }
        let app = try RookIntentApp.app()
        try app.model.sendFromShortcut(text, files: files.map(ConversationIntentSupport.payload), to: id)
        if opensConversation {
            try await continueInForeground(alwaysConfirm: false)
            app.showConversation(id)
            NSApp.activate()
        }
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

/// Opens a Mission, group or agent, as clicking its notification does.
struct OpenRookConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription(
        "Open a Rook Mission, group or agent.",
        searchKeywords: ["Open Mission", "Mission", "Open Chat", "Conversation", "Agent", "Group"]
    )

    @Parameter(title: "Conversation", requestValueDialog: "Which conversation should Rook open?")
    var conversation: RookConversationEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$conversation)") }

    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = try ConversationIntentSupport.id(of: conversation.id)
        let app = try RookIntentApp.app()
        guard app.model.conversation(id) != nil else { throw ConversationIntentError.missingConversation }
        app.showConversation(id)
        NSApp.activate()
        return .result()
    }
}

/// Calls an agent, opening its conversation; one that can't take calls just has its conversation opened.
struct CallRookAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Agent"
    static let description = IntentDescription(
        "Call a Rook agent. If it can't take calls, its conversation opens instead.",
        searchKeywords: ["Call", "Agent"]
    )

    @Parameter(title: "Agent", requestValueDialog: "Which agent should Rook call?")
    var agent: RookAgentEntity

    static var parameterSummary: some ParameterSummary { Summary("Call \(\.$agent)") }

    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = try ConversationIntentSupport.id(of: agent.id)
        let app = try RookIntentApp.app()
        guard let conversation = app.model.conversation(id) else { throw ConversationIntentError.missingConversation }
        app.showConversation(id)
        // As in Noodle: a call already with this agent goes on, and one with another agent ends.
        if app.calls.voiceCalls.call?.conversationID != id, app.calls.canCallNow(in: conversation) { app.calls.startCall(in: conversation) }
        NSApp.activate()
        return .result()
    }
}

struct RookAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToRookIntent(),
            phrases: [
                "Send to an agent with \(.applicationName)",
                "Send to \(\.$conversation) with \(.applicationName)",
                "Message \(\.$conversation) with \(.applicationName)",
                "Tell \(\.$conversation) using \(.applicationName)"
            ],
            shortTitle: "Send to Agent",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: OpenRookConversationIntent(),
            phrases: [
                "Open a conversation in \(.applicationName)",
                "Open \(\.$conversation) in \(.applicationName)"
            ],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: CallRookAgentIntent(),
            phrases: [
                "Call an agent with \(.applicationName)",
                "Call \(\.$agent) with \(.applicationName)"
            ],
            shortTitle: "Call Agent",
            systemImageName: "phone.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
