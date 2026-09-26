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
            let attachment: ConversationAttachment
            // A browser or computer the bot shares becomes a link to it, labelled with what the tool captured.
            if post.mediaType == BrowserReference.mediaType {
                let reference = try BrowserReference.decode(post.data)
                guard assignments(agent).assigned(reference.browser.id.uuidString, kind: "browser") != nil,
                      reference.browser.description == nil else { throw ToolProviderError("This browser is not assigned to you.") }
                attachment = try repository.importLinkAttachment(BrowserLink.url(browser: reference.browser.id, tab: reference.tabID),
                                                                 into: conversation, card: LinkCard(reference))
            } else if post.mediaType == ComputerCard.mediaType {
                let reference = try JSONDecoder().decode(ComputerReference.self, from: post.data)
                guard reference.version == 1, assignments(agent).assigned(reference.computer.id.uuidString, kind: "computer") != nil else {
                    throw ToolProviderError("This computer is not assigned to you.")
                }
                attachment = try repository.importLinkAttachment(
                    ComputerLink.url(computer: reference.computer.id, terminal: reference.terminalID, view: reference.view),
                    into: conversation, card: LinkCard(reference))
            } else if post.mediaType.lowercased().hasPrefix("application/vnd.noodle.") {
                // Noodle's own card types carry authority in chat; a tool cannot mint them.
                throw ToolProviderError("Tools cannot post this kind of attachment.")
            } else {
                attachment = try repository.importAttachment(data: post.data, originalFilename: post.filename, into: conversation,
                                                             mediaType: post.mediaType)
            }
            do {
                _ = try repository.sendAgentMessage(agentID: agent, conversationID: conversation,
                                                    body: post.message ?? post.filename, attachmentIDs: [attachment.id])
            } catch { try? repository.removeAttachment(attachment); throw error }
            return attachment.id
        }, revoked: revoked)
    }
}

extension LinkCard {
    public init(_ reference: BrowserReference) {
        self.init(title: reference.title.isEmpty ? reference.browser.name : reference.title, detail: reference.url,
                  image: reference.previewImage, symbol: reference.browser.symbol, colour: reference.browser.colour,
                  icon: reference.browser.icon, capturedAt: reference.capturedAt)
    }

    public init(_ reference: ComputerReference) {
        self.init(title: reference.computer.name, detail: reference.terminalPreview.isEmpty ? nil : reference.terminalPreview,
                  image: reference.previewImage, symbol: reference.computer.symbol, colour: reference.computer.colour,
                  icon: reference.computer.icon, capturedAt: reference.capturedAt)
    }
}
