import Foundation
import HubWire
@testable import ServerCore
import XCTest
#if canImport(HubLink)
import CoreGraphics
import HubLink
import ImageIO
#endif

/// An invitation's QR code, drawn in the terminal or saved as a PNG, for a phone to scan.
final class InvitationCodeTests: XCTestCase {
    private let link = LinkInvitation(hubName: "Test Server", hubKey: LinkIdentity().publicKey,
                                      endpoints: [LinkEndpoint(host: "noodle.example.com", port: 38_415)], userName: "Ada",
                                      joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date(timeIntervalSince1970: 2_000_000_000))
        .url().absoluteString

    /// Two rows of modules a line, dark on light whatever the terminal's colours, with the quiet zone around it.
    func testTheTerminalDrawingIsTheCodeWithItsMargin() throws {
        let code = try InvitationCode(link: link)
        let lines = code.terminal.split(separator: "\n").map(String.init)
        let side = code.size + 2 * InvitationCode.margin
        XCTAssertEqual(lines.count, (side + 1) / 2)
        for line in lines {
            XCTAssertTrue(line.hasPrefix(InvitationCode.darkOnLight), line)
            XCTAssertTrue(line.hasSuffix(InvitationCode.reset), line)
            let drawn = line.dropFirst(InvitationCode.darkOnLight.count).dropLast(InvitationCode.reset.count)
            XCTAssertEqual(drawn.count, side)
        }
        XCTAssertEqual(lines.first?.dropFirst(InvitationCode.darkOnLight.count).dropLast(InvitationCode.reset.count),
                       Substring(String(repeating: " ", count: side)), "the quiet zone is light")
    }

    func testThePictureIsAPNGOfTheWholeCode() throws {
        let code = try InvitationCode(link: link)
        let png = code.png(scale: 4)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let width = png[16..<20].reduce(0) { $0 << 8 | Int($1) }, height = png[20..<24].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(width, (code.size + 2 * InvitationCode.margin) * 4)
        XCTAssertEqual(height, width)
    }

    #if canImport(HubLink)
    /// What a phone reads from the picture is the invitation itself.
    func testThePictureScansAsTheInvitation() throws {
        let png = try InvitationCode(link: link).png(scale: 4)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(try LinkInvitation(image: image), try LinkInvitation(text: link))
    }
    #endif
}
