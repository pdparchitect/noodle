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
}
