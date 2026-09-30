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
        XCTAssertThrowsError(try manifest(#","runs":"cloud""#)) {
            XCTAssertEqual($0.localizedDescription, "Unknown runs cloud. Use device or hub.")
        }
    }

    /// Opened from another device, a noodlet runs where the person last chose, else where its bot
    /// said, else on the device; one that captures the screen needs the Hub's Mac whatever was chosen.
    func testWhereANoodletRuns() throws {
        let plain = try manifest("")
        XCTAssertEqual(plain.placement(chosen: nil), .device)
        XCTAssertEqual(plain.placement(chosen: .hub), .hub)
        let hinted = try manifest(#","runs":"hub""#)
        XCTAssertEqual(hinted.placement(chosen: nil), .hub)
        XCTAssertEqual(hinted.placement(chosen: .device), .device)
        let capturing = try manifest(#","permissions":["screen-capture"]"#)
        XCTAssertFalse(capturing.runsOnDevices)
        XCTAssertEqual(capturing.placement(chosen: .device), .hub)
        XCTAssertTrue(try manifest(#","permissions":["microphone"]"#).runsOnDevices)
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
