import BrowserBridge
import ComputerBridge
import Foundation

extension ToolHostServices {
    /// The app's services, backed by its own stores. `assignments` is the same live picture
    /// the broker enforces, so a card can only describe a browser the bot may use.
    public static func repository(_ repository: WorkspaceRepository, revoked: @escaping @Sendable (String, String, UUID) -> Void = { _, _, _ in },
                                  assignments: @escaping @Sendable (UUID) -> ToolAssignments) -> ToolHostServices {
        ToolHostServices(isMember: { agent, conversation in
            (try? repository.participantRoster(for: agent, conversationID: conversation)) != nil
        }, post: { post, agent, conversation in
            _ = try repository.participantRoster(for: agent, conversationID: conversation)
            var card: BrowserCard?
            var computerCard: ComputerCard?
            var data = post.data
            if post.mediaType == BrowserReference.mediaType {
                let reference = try BrowserReference.decode(post.data)
                guard assignments(agent).assigned(reference.browser.id.uuidString, kind: "browser") != nil,
                      reference.browser.description == nil else { throw ToolProviderError("This browser is not assigned to you.") }
                card = BrowserCard(reference: reference, agentID: agent)
            } else if post.mediaType == ComputerCard.mediaType {
                let reference = try JSONDecoder().decode(ComputerReference.self, from: post.data)
                guard reference.version == 1, assignments(agent).assigned(reference.computer.id.uuidString, kind: "computer") != nil else {
                    throw ToolProviderError("This computer is not assigned to you.")
                }
                var presented = ComputerCard(computer: reference.computer, agentID: agent, terminalID: reference.terminalID,
                                             terminalPreview: reference.terminalPreview, view: reference.view, previewImage: reference.previewImage)
                presented.capturedAt = reference.capturedAt
                computerCard = presented
                // Store exactly what the card describes, not whatever else the tool sent.
                data = try JSONEncoder().encode(presented.reference)
            } else if post.mediaType.lowercased().hasPrefix("application/vnd.noodle.") {
                // Noodle's own card types carry authority in chat; a tool cannot mint them.
                throw ToolProviderError("Tools cannot post this kind of attachment.")
            }
            let attachment = try repository.importAttachment(data: data, originalFilename: post.filename, into: conversation,
                                                             mediaType: post.mediaType, computer: computerCard, browser: card)
            do {
                _ = try repository.sendAgentMessage(agentID: agent, conversationID: conversation,
                                                    body: post.message ?? post.filename, attachmentIDs: [attachment.id])
            } catch { try? repository.removeAttachment(attachment); throw error }
            return attachment.id
        }, revoked: revoked)
    }
}
