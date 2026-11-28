import Foundation
import NoodleCore

/// The person's message, in every app: written to the conversation, then the conversation's bots are woken, its
/// lead and anyone it names first. The app shows it, reads the conversation and passes it to a call itself.
public enum PersonMessage {
    /// What the message says: the words, or how many files went without any.
    public static func body(_ text: String, files: Int) -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty && files > 0 ? "Sent \(files) attachment\(files == 1 ? "" : "s")" : words
    }

    /// Sends the words and files, or a voice message whose recording is among the files. Without a runtime, as in a
    /// scenario, nothing is woken.
    @MainActor @discardableResult
    public static func send(_ text: String, files: [ConversationAttachment] = [], voice: VoiceMessage? = nil,
                            to conversation: BotConversation, members: [AgentRecord], runtime: AgentRuntimeCoordinator?,
                            repository: WorkspaceRepository, now: Date = Date(), interrupt: Bool = false) throws -> ChatMessage {
        let message = try repository.sendUserMessage(
            conversationID: conversation.id,
            body: voice == nil ? body(text, files: files.count) : VoiceMessage.messageBody,
            attachmentIDs: files.map(\.id),
            now: now,
            interrupt: interrupt
        )
        let words = voice.map { $0.transcript ?? "" } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        runtime?.notify(members, in: conversation, body: words, repository: repository, interrupt: interrupt)
        return message
    }
}
