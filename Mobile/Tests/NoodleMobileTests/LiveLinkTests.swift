import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// Links a bot shares to something live open live; web links and files do not.
struct LiveLinkTests {
    private func attachment(_ url: String?) -> LinkAttachment {
        LinkAttachment(id: UUID(), filename: "Link.webloc", mediaType: "application/x-webloc", byteCount: 1, url: url.flatMap(URL.init(string:)))
    }

    @Test func browserComputerAndNoodletLinksOpenLiveInEveryBuild() {
        let id = UUID().uuidString.lowercased()
        for (url, kind) in [("noodlebrowser://\(id)?tab=\(id)", LinkAttachment.LiveKind.browser), ("noodlebrowser-dev://\(id)", .browser),
                            ("noodlecomputer://\(id)?view=web", .computer), ("noodlecomputer-dev://\(id)", .computer),
                            ("noodlet://\(id)", .noodlet), ("noodlet-dev://\(id)", .noodlet)] {
            #expect(attachment(url).isLive, "\(url)")
            #expect(attachment(url).liveKind == kind, "\(url)")
        }
        for url in ["https://example.com", "noodle://join-hub", nil] {
            #expect(!attachment(url).isLive, "\(url ?? "a file")")
        }
    }

    @Test func sharedNoodletResolvesItsTitleAndPreviewWithoutOpening() async {
        let link = LinkAttachment(id: UUID(), filename: "Noodlet.webloc", mediaType: "application/x-webloc",
                                  byteCount: 1, url: URL(string: "noodlet://\(UUID())"))
        let conversation = UUID()
        let card = LinkCardInfo(title: "Counter", image: Data([1, 2, 3]))
        let resolved = await link.resolvingCard(in: conversation) { request in
            #expect(request == .linkCard(conversationID: conversation, attachmentID: link.id))
            return .linkCard(card)
        }
        #expect(resolved.liveTitle == "Counter")
        #expect(resolved.card?.image == card.image)
        #expect(resolved.id == link.id)
        let unavailable = await link.resolvingCard(in: conversation) { _ in throw LinkError("Unsupported request.") }
        #expect(unavailable == link)
    }

    @Test func sharedListsEachComputerBrowserTabAndNoodletOnceNewestFirst() {
        let computer = UUID().uuidString, browser = UUID().uuidString, tab = UUID().uuidString, other = UUID().uuidString
        let noodlet = UUID().uuidString
        let newestFirst = [attachment("noodlecomputer://\(computer)?view=web"), attachment("https://example.com"),
                           attachment("noodlebrowser://\(browser)?tab=\(tab)"), attachment(nil),
                           attachment("noodlecomputer://\(computer)"), attachment("noodlebrowser://\(browser)?tab=\(other)"),
                           attachment("noodlet://\(noodlet)"), attachment("noodlebrowser://\(browser)?tab=\(tab)"),
                           attachment("noodlet-dev://\(noodlet)")]
        #expect(LinkAttachment.shared(newestFirst: newestFirst).map(\.id) == [0, 2, 5, 6].map { newestFirst[$0].id })
    }
}
