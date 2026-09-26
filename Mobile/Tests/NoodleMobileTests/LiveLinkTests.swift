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
        for url in ["noodlebrowser://\(id)?tab=\(id)", "noodlebrowser-dev://\(id)", "noodlecomputer://\(id)?view=web",
                    "noodlecomputer-dev://\(id)", "noodlet://\(id)", "noodlet-dev://\(id)"] {
            #expect(attachment(url).isLive, "\(url)")
        }
        for url in ["https://example.com", "noodle://join-hub", nil] {
            #expect(!attachment(url).isLive, "\(url ?? "a file")")
        }
    }
}
