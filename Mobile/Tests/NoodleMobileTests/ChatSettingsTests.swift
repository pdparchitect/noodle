import CoreGraphics
import Foundation
import HubLink
@testable import NoodleMobile
import Testing

@Suite struct ChatSettingsTests {
    private let picture = CGSize(width: 144, height: 192)

    @Test func verticalPutsEachFileOnItsOwnRow() {
        let plan = AttachmentRows.plan(sizes: [picture, picture], width: 313, mode: .vertical, trailing: false)
        #expect(plan.frames.map(\.origin) == [.zero, CGPoint(x: 0, y: 196)])
    }

    @Test func wrapSharesARowUntilItIsFull() {
        let plan = AttachmentRows.plan(sizes: [picture, picture, picture], width: 313, mode: .wrap, trailing: false)
        #expect(plan.frames.map(\.origin) == [.zero, CGPoint(x: 152, y: 0), CGPoint(x: 0, y: 200)])
        #expect(plan.size == CGSize(width: 296, height: 392))
    }

    @Test func stackOverlapsEachFileAndStaggersItsTop() {
        let plan = AttachmentRows.plan(sizes: [picture, picture], width: 313, mode: .stack, trailing: false)
        #expect(plan.frames[1].minY == 12 && plan.frames[1].minX > 0 && plan.frames[1].minX < picture.width)
    }

    @Test func yourFilesLineUpOnTheRight() {
        let plan = AttachmentRows.plan(sizes: [picture, CGSize(width: 300, height: 50)], width: 313, mode: .vertical, trailing: true)
        #expect(plan.frames[0].maxX == plan.frames[1].maxX)
    }

    @Test func picturesSharingARowAreSmaller() throws {
        let size = try #require(LinkPixelSize(width: 1200, height: 1600))
        let full = try #require(AttachmentView.pictureFrame(for: size))
        let compact = try #require(AttachmentView.pictureFrame(for: size, compact: true))
        #expect(compact.width * 2 + 8 <= 313 && compact.width < full.width)
    }

    @Test func theLayoutStartsAsItWas() {
        #expect(AttachmentLayout.standard == .vertical)
    }

    @Test func onlyWebLinksOpenInAPreview() throws {
        let web = try #require(URL(string: "https://example.com/page"))
        #expect(WebLinkPreview.previewed(web, enabled: true) == web)
        #expect(WebLinkPreview.previewed(web, enabled: false) == nil)
        #expect(WebLinkPreview.previewed(try #require(URL(string: "mailto:a@example.com")), enabled: true) == nil)
    }

    @Test func attachedWebLinksShowAsLinkCards() throws {
        func link(_ address: String) throws -> LinkAttachment {
            LinkAttachment(id: UUID(), filename: "Link.webloc", mediaType: "application/x-webloc", byteCount: 7,
                           url: try #require(URL(string: address)))
        }
        let web = try #require(URL(string: "https://www.example.com/page"))
        #expect(try link(web.absoluteString).webLink == web)
        #expect(try link("http://192.168.1.2/page").webLink == nil)
        #expect(try link("noodlet://00000000-0000-0000-0000-00000000000a").webLink == nil)
        #expect(LinkAttachment(id: UUID(), filename: "Notes.pdf", mediaType: "application/pdf", byteCount: 7).webLink == nil)
    }
}
