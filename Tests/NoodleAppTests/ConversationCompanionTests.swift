import XCTest
import AppletBridge
import BrowserBridge
import ComputerBridge
import NoodleCore
@testable import Noodle

final class ConversationCompanionTests: XCTestCase {
    private let conversationID = UUID()

    private func attachment(_ name: String, mediaType: String = "application/x-webloc", url: URL? = nil,
                            card: LinkCard? = nil) -> ConversationAttachment {
        ConversationAttachment(conversationID: conversationID, originalFilename: name, storedFilename: name,
            mediaType: mediaType, byteCount: 1, url: url, card: card)
    }

    func testListsEachComputerBrowserTabAndNoodletOnceNewestFirst() {
        let computer = ComputerLink.url(computer: UUID(), terminal: nil, view: "web")
        let browser = UUID(), tabA = UUID(), tabB = UUID()
        let noodlet = NoodletLink.url(for: UUID())
        let newestFirst = [
            attachment("Build Box.webloc", url: computer, card: LinkCard(title: "Build Box", detail: "new")),
            attachment("photo.png", mediaType: "image/png"),
            attachment("Timer.webloc", url: noodlet),
            attachment("A.webloc", url: BrowserLink.url(browser: browser, tab: tabA), card: LinkCard(title: "A")),
            attachment("Build Box.webloc", url: computer, card: LinkCard(title: "Build Box", detail: "old")),
            attachment("Timer.webloc", url: noodlet),
            attachment("B.webloc", url: BrowserLink.url(browser: browser, tab: tabB), card: LinkCard(title: "B")),
            attachment("example.com.webloc", url: URL(string: "https://example.com")),
        ]

        let companions = ConversationAttachment.companions(newestFirst: newestFirst)

        XCTAssertEqual(companions.map(\.id), [newestFirst[0], newestFirst[2], newestFirst[3], newestFirst[6]].map(\.id))
        XCTAssertEqual(companions.map(\.companionTitle), ["Build Box", "Timer", "A", "B"])
    }

    func testEachCompanionNamesItsKindAndCarriesItsPreview() {
        let image = Data([1, 2, 3])
        let items = [attachment("Mac.webloc", url: ComputerLink.url(computer: UUID(), terminal: nil, view: "web"),
                                card: LinkCard(title: "Mac", image: image)),
                     attachment("Example.webloc", url: BrowserLink.url(browser: UUID(), tab: UUID()), card: LinkCard(title: "Example", image: image)),
                     attachment("Timer.webloc", url: NoodletLink.url(for: UUID()))]
        XCTAssertEqual(items.map(\.companionKind), ["Computer", "Browser", "Noodlet"])
        XCTAssertEqual(items.map(\.companionPreviewImage), [image, image, nil])
    }

    func testNoodletTitleBeforeItsPreviewResolvesIsNotTheBookmarkFilename() {
        XCTAssertEqual(attachment("Noodlet.webloc", url: NoodletLink.url(for: UUID())).companionTitle, "Noodlet")
    }

    /// Every kind is recognised from its link alone, in either build, and nothing else is.
    func testCompanionLinksRoundTrip() {
        let browser = UUID(), tab = UUID(), computer = UUID(), terminal = UUID(), noodlet = UUID()
        for link in [CompanionLink.browser(browser, tab: tab), .browser(browser, tab: nil),
                     .computer(computer, terminal: terminal, view: "terminal"), .computer(computer, terminal: nil, view: "web"),
                     .noodlet(noodlet)] {
            XCTAssertEqual(CompanionLink(link.url), link)
            XCTAssertEqual(CompanionLink.canonical(link.url), link.url)
        }
        XCTAssertEqual(CompanionLink(BrowserLink.url(browser: browser, tab: tab, build: .development)), .browser(browser, tab: tab))
        for foreign in ["https://example.com", "noodlebrowser://not-a-uuid", "noodlecomputer://\(computer)?view=shell",
                        "noodlebrowser://\(browser)?tab=\(tab)&extra=1", "noodlecomputer://\(computer)/path"] {
            XCTAssertNil(CompanionLink(URL(string: foreign)!), foreign)
        }
    }
}
