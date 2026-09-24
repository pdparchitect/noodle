import XCTest
import AppletBridge
import BrowserBridge
import ComputerBridge
import NoodleCore
@testable import Noodle

final class ConversationCompanionTests: XCTestCase {
    private let conversationID = UUID()

    private func attachment(_ name: String, mediaType: String = "application/octet-stream", url: URL? = nil,
                            computer: ComputerCard? = nil, browser: BrowserCard? = nil) -> ConversationAttachment {
        ConversationAttachment(conversationID: conversationID, originalFilename: name, storedFilename: name,
            mediaType: mediaType, byteCount: 1, url: url, computer: computer, browser: browser)
    }

    func testListsEachComputerBrowserPageAndNoodletOnceNewestFirst() {
        let computer = RemoteComputer(id: UUID(), name: "Build Box", kind: "vm", state: "running", symbol: "desktopcomputer")
        let browser = RemoteBrowser(id: UUID(), name: "Research")
        let noodlet = NoodletLink.url(for: UUID())
        func page(_ url: String, _ title: String) -> BrowserCard {
            BrowserCard(reference: BrowserReference(browser: browser, tabID: UUID(), url: url, title: title), agentID: UUID())
        }
        let newestFirst = [
            attachment("box.noodlecomputer", mediaType: ComputerCard.mediaType,
                       computer: ComputerCard(computer: computer, agentID: UUID(), terminalPreview: "new")),
            attachment("photo.png", mediaType: "image/png"),
            attachment("Timer", url: noodlet),
            attachment("a.noodlebrowser", mediaType: BrowserReference.mediaType, browser: page("https://a.example", "A")),
            attachment("box-old.noodlecomputer", mediaType: ComputerCard.mediaType,
                       computer: ComputerCard(computer: computer, agentID: UUID(), terminalPreview: "old")),
            attachment("Timer", url: noodlet),
            attachment("b.noodlebrowser", mediaType: BrowserReference.mediaType, browser: page("https://b.example", "B")),
            attachment("https://example.com", url: URL(string: "https://example.com")),
        ]

        let companions = ConversationAttachment.companions(newestFirst: newestFirst)

        XCTAssertEqual(companions.map(\.id), [newestFirst[0], newestFirst[2], newestFirst[3], newestFirst[6]].map(\.id))
        XCTAssertEqual(companions.map(\.companionTitle), ["Build Box", "Timer", "A", "B"])
    }

    func testEachCompanionNamesItsKindAndCarriesItsPreview() {
        let image = Data([1, 2, 3])
        let computer = ComputerCard(computer: RemoteComputer(id: UUID(), name: "Mac", kind: "host", state: "running",
            symbol: "desktopcomputer"), agentID: UUID(), terminalPreview: "", previewImage: image)
        let page = BrowserCard(reference: BrowserReference(browser: RemoteBrowser(id: UUID(), name: "Local"),
            tabID: UUID(), url: "https://example.com", title: "Example", previewImage: image), agentID: UUID())
        let items = [attachment("m.noodlecomputer", computer: computer), attachment("p.noodlebrowser", browser: page),
                     attachment("Timer", url: NoodletLink.url(for: UUID()))]
        XCTAssertEqual(items.map(\.companionKind), ["Computer", "Browser", "Noodlet"])
        XCTAssertEqual(items.map(\.companionPreviewImage), [image, image, nil])
    }
}
