import Foundation
import ImageIO
@testable import HubLink
import XCTest

final class LinkProtocolTests: XCTestCase {
    private let invitation = LinkInvitation(
        hubName: "Mac mini", hubKey: LinkIdentity().publicKey,
        endpoints: [LinkEndpoint(host: "Mac-mini.local", port: 38_415), LinkEndpoint(host: "fd00::1", port: 38_415)],
        userName: "Ada", joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date(timeIntervalSince1970: 1_790_000_000))

    func testInvitationsSurviveTheirLinkFromAnyNoodleBuild() throws {
        XCTAssertEqual(try LinkInvitation(text: invitation.url().absoluteString), invitation)
        XCTAssertEqual(try LinkInvitation(text: " \(invitation.url(scheme: "noodle-dev").absoluteString)\n"), invitation)
        let code = try XCTUnwrap(URLComponents(url: invitation.url(), resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        XCTAssertEqual(try LinkInvitation(text: code), invitation)
    }

    /// A background's name comes from the Hub, so a device uses only the Hub's own kind of name for a
    /// file: never a path, nor anything that leaves the folder it is kept in.
    func testBackgroundNamesNeverLeaveTheirFolder() {
        let id = UUID().uuidString.lowercased()
        XCTAssertEqual(LinkBackground(media: "\(id).mov", mediaKind: "video").mediaFilename, "\(id).mov")
        XCTAssertEqual(LinkBackground(media: "\(id).mov", mediaKind: "video").compactFilename, "\(id).mp4")
        XCTAssertEqual(LinkBackground(media: "\(id).heic", mediaKind: "dynamicImage").compactFilename, "\(id).jpg")
        for hostile in ["..", ".", "", "../\(id).jpg", "\(id).jpg/..", "/etc/passwd", "\(id)/../\(id).jpg", "~/\(id).jpg",
                        "secret.jpg", "\(id).sh", "\(id)", "\(id).jpg.mov", ".\(id).jpg", "\(id).jpg/", "\(id).jpg\u{0}"] {
            let background = LinkBackground(media: hostile, mediaKind: "image")
            XCTAssertNil(background.mediaFilename, hostile)
            XCTAssertNil(background.compactFilename, hostile)
        }
    }

    /// Devices that fetch pictures on their own say so with every request; older ones get them in lists.
    func testListsLeavePicturesOutOnlyForDevicesThatFetchThem() throws {
        XCTAssertTrue(LinkProtocol.fetchesPictures(try LinkProtocol.encode(.bots)))
        XCTAssertFalse(LinkProtocol.fetchesPictures(Data(#"{"version":1,"request":{"bots":{}}}"#.utf8)))
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        XCTAssertEqual(try LinkProtocol.decode(Data(#"{"version":1,"fetchesPictures":true,"request":{"picture":{"_0":{"bot":{"_0":"00000000-0000-0000-0000-00000000000A"}}}}}"#.utf8)).get(),
                       .picture(.bot(id)))

        let picture = Data([1, 2, 3])
        let browser = LinkBrowser(id: id, name: "Work", icon: picture).withoutPicture
        XCTAssertNil(browser.icon)
        XCTAssertEqual(browser.iconDigest, LinkPicture.digest(picture))
        XCTAssertEqual(LinkBrowser(id: id, name: "Work").withoutPicture, LinkBrowser(id: id, name: "Work"))
    }

    /// An edit sends a bot's picture only when it changed, and a removed one stays removed.
    func testAnEditLeavesOutOnlyThePictureTheHubHas() {
        let picture = Data([1, 2, 3])
        var draft = LinkBotDraft(name: "Alfred", provider: "claude-code", avatarImageData: picture)
        draft.avatarImageDigest = LinkPicture.digest(picture)
        XCTAssertNil(draft.leavingOutKnownPicture.avatarImageData)
        XCTAssertEqual(draft.leavingOutKnownPicture.avatarImageDigest, LinkPicture.digest(picture))

        var changed = draft
        changed.avatarImageData = Data([4])
        XCTAssertEqual(changed.leavingOutKnownPicture.avatarImageData, Data([4]))
        XCTAssertNil(changed.leavingOutKnownPicture.avatarImageDigest)

        var removed = draft
        removed.removePicture()
        XCTAssertNil(removed.leavingOutKnownPicture.avatarImageData)
        XCTAssertNil(removed.leavingOutKnownPicture.avatarImageDigest)
    }

    func testOtherTextIsNotAnInvitation() {
        XCTAssertThrowsError(try LinkInvitation(text: "https://example.com"))
        XCTAssertThrowsError(try LinkInvitation(text: "noodle://join-hub?i=bm90IGpzb24"))
    }

    /// A device proves it holds the key it pairs, for one invitation only.
    func testAJoinProofHoldsForItsKeyAndInvitationOnly() throws {
        let device = LinkIdentity(), invitation = LinkIdentity().publicKey
        let proof = try device.joinProof(for: invitation)
        XCTAssertTrue(device.publicKey.isJoinProof(proof, for: invitation))
        XCTAssertFalse(device.publicKey.isJoinProof(proof, for: LinkIdentity().publicKey))
        XCTAssertFalse(LinkIdentity().publicKey.isJoinProof(proof, for: invitation))
        XCTAssertFalse(device.publicKey.isJoinProof(Data([1, 2, 3]), for: invitation))
    }

    func testAnInvitationWithoutAUsableJoinKeyIsNotAnInvitation() {
        var broken = invitation
        broken.joinKey = Data([1, 2, 3])
        XCTAssertThrowsError(try LinkInvitation(text: broken.url().absoluteString))
    }

    func testTypedAddressesTakeAnOptionalPort() {
        XCTAssertEqual(LinkEndpoint(text: "hub.example.com", defaultPort: 1), LinkEndpoint(host: "hub.example.com", port: 1))
        XCTAssertEqual(LinkEndpoint(text: "203.0.113.5:4000", defaultPort: 1), LinkEndpoint(host: "203.0.113.5", port: 4000))
        XCTAssertEqual(LinkEndpoint(text: "[2001:db8::1]:4000", defaultPort: 1), LinkEndpoint(host: "2001:db8::1", port: 4000))
        XCTAssertEqual(LinkEndpoint(text: "2001:db8::1", defaultPort: 1), LinkEndpoint(host: "2001:db8::1", port: 1))
        XCTAssertNil(LinkEndpoint(text: "host:notaport", defaultPort: 1))
        XCTAssertNil(LinkEndpoint(text: " ", defaultPort: 1))
    }

    func testLocalAddressesNeverIncludeLoopbackOrLinkLocal() {
        let hosts = LinkEndpoint.local(port: 5).map(\.host)
        XCTAssertFalse(hosts.contains { $0 == "127.0.0.1" || $0 == "::1" || $0.lowercased().hasPrefix("fe80") })
        XCTAssertTrue(LinkEndpoint.local(port: 5).allSatisfy { $0.port == 5 })
    }

    func testTailscaleAddressesAreNamedByTheirMagicDNSName() {
        XCTAssertEqual(LinkEndpoint.tailnetName(of: "100.101.102.103") { _ in "mac.tail1234.ts.net." }, "mac.tail1234.ts.net")
        XCTAssertNil(LinkEndpoint.tailnetName(of: "100.101.102.103") { _ in nil })
        for outside in ["192.168.1.5", "100.63.255.255", "100.128.0.1", "10.0.0.1"] {
            XCTAssertNil(LinkEndpoint.tailnetName(of: outside) { _ in XCTFail(outside); return "x" }, outside)
        }
    }

    func testTailscaleNamesAreLookedUpInTheBackgroundAndAMissIsAskedAgainLater() {
        final class Answers { var name: String?; var clock = Date(timeIntervalSince1970: 0); var pending: [() -> Void] = []; var found = 0 }
        let answers = Answers()
        let lookups = ReverseLookups(now: { answers.clock }, run: { answers.pending.append($0) },
                                     found: { answers.found += 1 }) { _ in answers.name }
        func settle() { while !answers.pending.isEmpty { answers.pending.removeFirst()() } }
        XCTAssertNil(lookups.name(of: "100.101.102.103"))
        XCTAssertNil(lookups.name(of: "100.101.102.103"))
        XCTAssertEqual(answers.pending.count, 1, "one lookup at a time, off the caller")
        settle()
        answers.name = "mac.tail1234.ts.net"
        XCTAssertNil(lookups.name(of: "100.101.102.103"), "a miss is remembered for a while")
        XCTAssertTrue(answers.pending.isEmpty)
        answers.clock += ReverseLookups.missLifetime + 1
        XCTAssertNil(lookups.name(of: "100.101.102.103"))
        settle()
        XCTAssertEqual(answers.found, 1)
        XCTAssertEqual(lookups.name(of: "100.101.102.103"), "mac.tail1234.ts.net")
        answers.name = nil
        answers.clock += 3600
        XCTAssertEqual(lookups.name(of: "100.101.102.103"), "mac.tail1234.ts.net", "a found name is kept")
        XCTAssertTrue(answers.pending.isEmpty)
    }

    func testTailscalesResolverIsAskedForTheNameOfAnAddress() throws {
        let query = try XCTUnwrap(TailnetDNS.query(for: "100.90.231.122", id: 0x1234))
        var expected = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in ["122", "231", "90", "100", "in-addr", "arpa"] { expected.append(UInt8(label.utf8.count)); expected.append(contentsOf: label.utf8) }
        expected.append(contentsOf: [0, 0, 12, 0, 1])
        XCTAssertEqual(query, expected)
        // The reply 100.100.100.100 gave for this Mac: the question again, then a PTR answer pointing back at it.
        var reply = Data([0x12, 0x34, 0x85, 0x00, 0, 1, 0, 1, 0, 0, 0, 0])
        reply.append(query.dropFirst(12))
        reply.append(contentsOf: [0xC0, 0x0C, 0, 12, 0, 1, 0, 0, 2, 0x58, 0, 38])
        for label in ["petkos-macbook-pro", "tail325532", "ts", "net"] { reply.append(UInt8(label.utf8.count)); reply.append(contentsOf: label.utf8) }
        reply.append(0)
        XCTAssertEqual(TailnetDNS.name(inReply: reply, id: 0x1234), "petkos-macbook-pro.tail325532.ts.net")
        XCTAssertNil(TailnetDNS.name(inReply: reply, id: 0x4321), "another query's reply")
        var refused = reply
        refused[3] = 0x83
        XCTAssertNil(TailnetDNS.name(inReply: refused, id: 0x1234))
        XCTAssertNil(TailnetDNS.name(inReply: reply.prefix(40), id: 0x1234))
    }

    func testTheKeySurvivesARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hub-link-\(UUID())/device.key")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try LinkIdentity.loadOrCreate(at: url)
        XCTAssertEqual(try LinkIdentity.loadOrCreate(at: url).publicKey, first.publicKey)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    /// As on the Mac, a bot keeps its effort only while its model offers it, and otherwise takes the model's default.
    func testChangingTheModelResetsAnEffortTheModelDoesNotOffer() {
        let efforts = ["low", "high", "xhigh"].map { LinkEffort(id: $0, name: $0) }
        let codex = LinkHarness(provider: "codex", providerName: "Codex", profileName: nil, models: [
            LinkModel(id: "big", name: "Big", efforts: efforts, defaultEffort: "high"),
            LinkModel(id: "small", name: "Small", efforts: Array(efforts.prefix(2)), defaultEffort: "low"),
            LinkModel(id: "plain", name: "Plain"),
        ])
        var draft = LinkBotDraft(name: "Alfred", provider: "codex", model: "big", reasoningEffort: "high")
        draft.setModel("small", on: codex)
        XCTAssertEqual(draft.model, "small")
        XCTAssertEqual(draft.reasoningEffort, "high", "offered by both models")
        draft.reasoningEffort = nil
        draft.setModel("big", on: codex)
        XCTAssertNil(draft.reasoningEffort, "Default stays Default")
        draft.reasoningEffort = "xhigh"
        draft.setModel("small", on: codex)
        XCTAssertEqual(draft.reasoningEffort, "low")
        draft.setModel("plain", on: codex)
        XCTAssertNil(draft.reasoningEffort)
        draft.reasoningEffort = "xhigh"
        draft.setModel(nil, on: codex)
        XCTAssertNil(draft.reasoningEffort, "the harness default model")
    }
}

/// A picture's size travels with it, so devices hold its place before the file arrives.
final class LinkPixelSizeTests: XCTestCase {
    private func picture(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testReadsAPicturesSizeAsItIsShown() throws {
        XCTAssertEqual(LinkPixelSize(pictureAt: try picture(width: 30, height: 20)), LinkPixelSize(width: 30, height: 20))
        // Turned a quarter, as phone photos often are.
        XCTAssertEqual(LinkPixelSize(pictureAt: try picture(width: 30, height: 20, orientation: 6)), LinkPixelSize(width: 20, height: 30))
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        try Data("not a picture".utf8).write(to: text)
        addTeardownBlock { try? FileManager.default.removeItem(at: text) }
        XCTAssertNil(LinkPixelSize(pictureAt: text))
    }

    func testImplausibleSizesAreIgnored() throws {
        XCTAssertNil(LinkPixelSize(width: 0, height: 20))
        XCTAssertNil(LinkPixelSize(width: 20, height: 1_000_000))
        let id = UUID()
        let file = try LinkProtocol.decoder.decode(LinkAttachment.self, from: Data(
            #"{"id":"\#(id)","filename":"a.png","mediaType":"image/png","byteCount":3,"pixelSize":{"width":-4,"height":20}}"#.utf8))
        XCTAssertNil(file.pixelSize)
    }

    func testTravelsWithTheAttachment() throws {
        let sized = LinkAttachment(id: UUID(), filename: "a.png", mediaType: "image/png", byteCount: 3,
                                   pixelSize: LinkPixelSize(width: 1200, height: 900))
        XCTAssertEqual(try LinkProtocol.decoder.decode(LinkAttachment.self, from: LinkProtocol.encoder.encode(sized)), sized)
        let unsized = try LinkProtocol.decoder.decode(LinkAttachment.self, from: Data(
            #"{"id":"\#(UUID())","filename":"a.png","mediaType":"image/png","byteCount":3}"#.utf8))
        XCTAssertNil(unsized.pixelSize)
    }
}
