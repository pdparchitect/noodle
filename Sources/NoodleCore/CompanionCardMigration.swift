import BrowserBridge
import ComputerBridge
import Foundation

// TODO(0.29.0): Remove CompanionCardMigration, its calls in NoodleStore.reload and HubBots.start, and
// CompanionCardMigrationTests.
/// Turns the browser and computer cards earlier versions saved as files into links, keeping each
/// attachment's ID, date and picture, so messages still point at them and they open as before.
public enum CompanionCardMigration {
    private struct Legacy: Decodable {
        let browser: BrowserCard?
        let computer: ComputerCard?
    }

    public static func run(_ repository: WorkspaceRepository) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for conversation in (try? repository.loadConversations()) ?? [] {
            let directory = repository.attachmentsDirectory(conversationID: conversation.id)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let current = Dictionary(((try? repository.loadAttachments(conversationID: conversation.id)) ?? []).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let legacy = try? decoder.decode(Legacy.self, from: data),
                      let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let old = current[id],
                      old.url == nil else { continue }
                let link: URL, card: LinkCard
                if let browser = legacy.browser {
                    link = BrowserLink.url(browser: browser.reference.browser.id, tab: browser.reference.tabID)
                    card = LinkCard(browser.reference)
                } else if let computer = legacy.computer {
                    link = ComputerLink.url(computer: computer.computer.id, terminal: computer.terminalID, view: computer.view)
                    card = LinkCard(computer.reference)
                } else { continue }
                do {
                    _ = try repository.importLinkAttachment(link, into: conversation.id, now: old.createdAt, card: card, id: id)
                    try? FileManager.default.removeItem(at: repository.attachmentFileURL(old))
                } catch {
                    // A card that cannot become a link stays as it was; it no longer opens, but nothing is lost.
                    continue
                }
            }
        }
    }
}
