import NoodletFormat
import XCTest

final class ManifestTests: XCTestCase {
    private func manifest(_ fields: String) throws -> NoodletManifest {
        let manifest = try JSONDecoder().decode(NoodletManifest.self, from: Data(
            #"{"title":"Fixture","runtime":"html","entry":"index.html"\#(fields)}"#.utf8))
        try manifest.validate()
        return manifest
    }

    /// What the page is laid out for, and where it works best from another device, are hints a bot
    /// gives; a noodlet without them is laid out for a desktop window and runs anywhere.
    func testLayoutAndPlacementAreKnownHints() throws {
        let plain = try manifest("")
        XCTAssertNil(plain.layout)
        XCTAssertNil(plain.runs)
        XCTAssertEqual(try manifest(#","layout":"phone""#).layout, .phone)
        XCTAssertEqual(try manifest(#","layout":"adaptive","runs":"device""#).runs, .device)
        XCTAssertEqual(try manifest(#","runs":"hub""#).runs, .hub)
        XCTAssertThrowsError(try manifest(#","layout":"tablet""#)) {
            XCTAssertEqual($0.localizedDescription, "Unknown layout tablet. Use desktop, phone or adaptive.")
        }
        XCTAssertNil(plain.display)
        XCTAssertNil(plain.orientation)
        XCTAssertNil(plain.backgroundColor)
        let game = try manifest(##","display":"fullscreen","orientation":"landscape","backgroundColor":"#1D1d1f""##)
        XCTAssertEqual(game.display, .fullscreen)
        XCTAssertEqual(game.orientation, .landscape)
        XCTAssertEqual(game.backgroundColor, "#1D1d1f")
        XCTAssertEqual(try manifest(##","display":"standalone","orientation":"portrait","backgroundColor":"#000""##).display, .standalone)
        XCTAssertThrowsError(try manifest(#","display":"kiosk""#)) {
            XCTAssertEqual($0.localizedDescription, "Unknown display kiosk. Use browser, standalone or fullscreen.")
        }
        XCTAssertThrowsError(try manifest(#","orientation":"upside""#)) {
            XCTAssertEqual($0.localizedDescription, "Unknown orientation upside. Use any, portrait or landscape.")
        }
        for colour in ["black", "#12345", "#1d1d1f;}", "rgb(0,0,0)"] {
            XCTAssertThrowsError(try manifest(#","backgroundColor":"\#(colour)""#), colour) {
                XCTAssertEqual($0.localizedDescription, "Unknown backgroundColor \(colour). Use a hex colour such as #1d1d1f.")
            }
        }
        XCTAssertNil(plain.theme)
        XCTAssertEqual(try manifest(#","theme":"dark""#).theme, .dark)
        XCTAssertThrowsError(try manifest(#","theme":"sepia""#)) {
            XCTAssertEqual($0.localizedDescription, "Unknown theme sepia. Use system, light or dark.")
        }
        XCTAssertThrowsError(try manifest(#","runs":"cloud""#)) {
            XCTAssertEqual($0.localizedDescription, "Unknown runs cloud. Use device or hub.")
        }
    }

    /// Opened from another device, a noodlet runs where the person last chose, else where its bot
    /// said, else on the device. One that uses the camera, microphone or screen runs on the device
    /// whatever was chosen: streamed from the Hub it would get the Hub's.
    func testWhereANoodletRuns() throws {
        let plain = try manifest("")
        XCTAssertTrue(plain.streams)
        XCTAssertEqual(plain.placement(chosen: nil), .device)
        XCTAssertEqual(plain.placement(chosen: .hub), .hub)
        let hinted = try manifest(#","runs":"hub""#)
        XCTAssertEqual(hinted.placement(chosen: nil), .hub)
        XCTAssertEqual(hinted.placement(chosen: .device), .device)
        for permission in NoodletManifest.knownPermissions {
            let sensing = try manifest(#","runs":"hub","permissions":["\#(permission)"]"#)
            XCTAssertFalse(sensing.streams, permission)
            XCTAssertEqual(sensing.placement(chosen: .hub), .device, permission)
        }
    }

    /// The sites a noodlet may show in a frame are whole https sites, written as their origin.
    func testEmbedsAreHttpsSites() throws {
        XCTAssertNil(try manifest("").embeds)
        let linked = try manifest(#","embeds":["https://www.youtube-nocookie.com","https://Player.Vimeo.com/","https://example.com:8443"]"#)
        XCTAssertEqual(linked.embeds, ["https://www.youtube-nocookie.com", "https://Player.Vimeo.com/", "https://example.com:8443"])
        XCTAssertEqual(linked.embeddedSites, ["www.youtube-nocookie.com", "player.vimeo.com", "example.com:8443"])

        // A frame's address belongs to a listed site by scheme, host and port, whatever its path.
        for url in ["https://www.youtube-nocookie.com/embed/aircAruvnKk?autoplay=1", "https://player.vimeo.com/video/76979871",
                    "https://PLAYER.vimeo.com:443/video/1", "https://example.com:8443/"] {
            XCTAssertTrue(linked.mayEmbed(URL(string: url)!), url)
        }
        for url in ["http://player.vimeo.com/video/1", "https://vimeo.com/76979871", "https://www.youtube.com/embed/aircAruvnKk",
                    "https://example.com/", "https://evil.player.vimeo.com/", "https://player.vimeo.com.evil.com/",
                    "wss://player.vimeo.com/", "noodlet-package://noodlet/index.html"] {
            XCTAssertFalse(linked.mayEmbed(URL(string: url)!), url)
        }
        XCTAssertFalse(try manifest("").mayEmbed(URL(string: "https://player.vimeo.com/video/1")!))

        // validate says what is wrong with each kind of entry.
        let refusals = [
            "http://player.vimeo.com": "Embed http://player.vimeo.com must use https, such as https://player.vimeo.com.",
            "player.vimeo.com": "Embed player.vimeo.com must use https, such as https://player.vimeo.com.",
            "https://www.youtube.com/embed": "Embed https://www.youtube.com/embed is not a whole site. List only https://www.youtube.com.",
            "https://www.youtube.com/?x=1": "Embed https://www.youtube.com/?x=1 is not a whole site. List only https://www.youtube.com.",
            "https://*.vimeo.com": "Embed https://*.vimeo.com cannot use a wildcard. List each site, such as https://player.vimeo.com.",
            "https://user@player.vimeo.com": "Embed https://user@player.vimeo.com is not a whole site. List only https://player.vimeo.com.",
            "https://": "Embed https:// is not a site. Use one such as https://player.vimeo.com.",
            " ": "An embed is empty. Use a site such as https://player.vimeo.com.",
        ]
        for (entry, message) in refusals {
            XCTAssertThrowsError(try manifest(#","embeds":["\#(entry)"]"#), entry) {
                XCTAssertEqual($0.localizedDescription, message)
            }
        }

        // Written back, the list stays as the bot wrote it.
        let again = try JSONDecoder().decode(NoodletManifest.self, from: try JSONEncoder().encode(linked))
        XCTAssertEqual(again.embeds, linked.embeds)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(try manifest("")), as: UTF8.self).contains("embeds"))
    }

    /// Written back, a noodlet keeps only the hints it gave.
    func testHintsRoundTrip() throws {
        let data = try JSONEncoder().encode(try manifest(#","layout":"adaptive","runs":"hub""#))
        let again = try JSONDecoder().decode(NoodletManifest.self, from: data)
        XCTAssertEqual(again.layout, .adaptive)
        XCTAssertEqual(again.runs, .hub)
        let plain = String(decoding: try JSONEncoder().encode(try manifest("")), as: UTF8.self)
        XCTAssertFalse(plain.contains("layout"))
        XCTAssertFalse(plain.contains("runs"))
    }
}
