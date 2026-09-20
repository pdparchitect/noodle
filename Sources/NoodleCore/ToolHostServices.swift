import BrowserBridge
import Foundation

extension ToolHostServices {
    /// The app's services, backed by its own stores. `assignments` is the same live picture
    /// the broker enforces, so a card can only describe a browser the bot may use.
    public static func repository(_ repository: WorkspaceRepository,
                                  assignments: @escaping @Sendable (UUID) -> ToolAssignments) -> ToolHostServices {
        ToolHostServices(isMember: { agent, conversation in
            (try? repository.participantRoster(for: agent, conversationID: conversation)) != nil
        }, post: { post, agent, conversation in
            _ = try repository.participantRoster(for: agent, conversationID: conversation)
            var card: BrowserCard?
            if post.mediaType == BrowserReference.mediaType {
                let reference = try BrowserReference.decode(post.data)
                guard assignments(agent).assigned(reference.browser.id.uuidString, kind: "browser") != nil,
                      reference.browser.description == nil else { throw ToolProviderError("This browser is not assigned to you.") }
                card = BrowserCard(reference: reference, agentID: agent)
            } else if post.mediaType.lowercased().hasPrefix("application/vnd.noodle.") {
                // Noodle's own card types carry authority in chat; a tool cannot mint them.
                throw ToolProviderError("Tools cannot post this kind of attachment.")
            }
            let attachment = try repository.importAttachment(data: post.data, originalFilename: post.filename, into: conversation,
                                                             mediaType: post.mediaType, browser: card)
            do {
                _ = try repository.sendAgentMessage(agentID: agent, conversationID: conversation,
                                                    body: post.message ?? post.filename, attachmentIDs: [attachment.id])
            } catch { try? repository.removeAttachment(attachment); throw error }
            return attachment.id
        })
    }
}
