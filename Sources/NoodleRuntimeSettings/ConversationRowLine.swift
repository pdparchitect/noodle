import Foundation
import HubLink
import HubWire
import NoodleCore

extension ConversationRowDetail {
    /// The plain start of the latest message anyone but the system said, for the line under a row's name.
    public static func latestMessage(in messages: [ChatMessage]) -> String {
        guard let message = messages.last(where: { $0.author != .system }) else { return "No messages yet" }
        return MarkdownPlainText.convert(MessageSegment.previewText(message.body))
    }

    /// The line under a conversation's name: a bot's own conversation speaks for the bot, with its description and
    /// status, or else the start of its latest reply; a group uses its own description.
    public func line(for conversation: BotConversation, agent: AgentRecord?, messages: [ChatMessage],
                     latestMessage: String) -> String {
        line(isGroup: conversation.kind == .group,
             description: agent?.publicDescription ?? conversation.publicDescription,
             status: agent?.status,
             latestReply: {
                 agent.flatMap { agent in
                     WidgetBots.statusLine(status: nil, messages: messages, agentID: agent.id) {
                         MarkdownPlainText.convert(MessageSegment.previewText($0))
                     }
                 }
             },
             latestMessage: latestMessage)
    }
}

extension ConversationSearch {
    /// Each message that says the term, newest first, read as its row shows it, without markdown; the app's own
    /// notices are left out.
    public func messageMatches(in conversations: [(id: UUID, messages: [ChatMessage])],
                               limit: Int = LinkMessageSearch.maximumLimit) -> [LinkMessageMatch] {
        messageMatches(in: conversations, limit: limit) { message in
            (message.id, message.createdAt,
             message.author == .system ? nil : MarkdownPlainText.convert(MessageSegment.previewText(message.body)))
        }
    }
}
