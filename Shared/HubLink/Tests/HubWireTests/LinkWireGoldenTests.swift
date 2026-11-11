import Foundation
@testable import HubWire
import XCTest

/// Every message the link carries, held to the JSON recorded in Fixtures/wire-golden.json, so moving or
/// porting the protocol types cannot change the wire unnoticed. Compared as JSON values rather than bytes,
/// since key order and number formatting differ between Foundations. Run with HUBLINK_RECORD_WIRE=1 to
/// record the fixture again after a deliberate change.
final class LinkWireGoldenTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/wire-golden.json")

    func testEveryMessageMatchesTheGolden() throws {
        let samples = LinkWireSamples.all
        XCTAssertEqual(Set(samples.map(\.label)).count, samples.count, "Sample labels must be unique")

        if ProcessInfo.processInfo.environment["HUBLINK_RECORD_WIRE"] == "1" {
            var recorded: [String: Any] = [:]
            for sample in samples {
                recorded[sample.label] = try JSONSerialization.jsonObject(with: try sample.encode(), options: .fragmentsAllowed)
            }
            let data = try JSONSerialization.data(withJSONObject: recorded, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: Self.fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: Self.fixture)
            XCTFail("Recorded \(samples.count) samples to \(Self.fixture.path). Run again without HUBLINK_RECORD_WIRE to compare.")
            return
        }

        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        XCTAssertEqual(Set(golden.keys).subtracting(samples.map(\.label)).sorted(), [], "Golden entries without a sample")
        for sample in samples {
            guard let expected = golden[sample.label] else {
                XCTFail("\(sample.label): no golden JSON; record it with HUBLINK_RECORD_WIRE=1")
                continue
            }
            let expectedData = try JSONSerialization.data(withJSONObject: expected, options: .fragmentsAllowed)
            let encoded = try JSONValue.parse(sample.encode())
            let wanted = try JSONValue.parse(expectedData)
            XCTAssertEqual(encoded, wanted, "\(sample.label) encodes differently.\nencoded: \(encoded)\ngolden:  \(wanted)")
            do {
                if let mismatch = try sample.mismatch(expectedData) {
                    XCTFail("\(sample.label): the golden JSON decodes to something else: \(mismatch)")
                }
            } catch {
                XCTFail("\(sample.label): the golden JSON does not decode: \(error)")
            }
        }
    }

    /// Fields a sender leaves out, or values from a newer app, read as these defaults. Encoding always writes
    /// them, so the golden fixture cannot show these branches.
    func testMissingAndUnknownFieldsReadAsDefaults() throws {
        func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
            try LinkProtocol.decoder.decode(type, from: Data(json.utf8))
        }
        let a = "00000000-0000-0000-0000-00000000000A", b = "00000000-0000-0000-0000-00000000000B"
        let ida = UUID(uuidString: a)!, idb = UUID(uuidString: b)!

        let status = try decode(LinkStatus.self, #"{"hubName":"Hub"}"#)
        XCTAssertEqual(status, LinkStatus(hubName: "Hub", userName: "", planName: "", harnesses: [], endpoints: [], protocolVersion: 1))

        XCTAssertEqual(try decode(LinkHarness.self, #"{"provider":"claude"}"#),
                       LinkHarness(provider: "claude", providerName: "claude", profileName: nil))
        XCTAssertEqual(try decode(LinkModel.self, #"{"id":"m","name":"M"}"#), LinkModel(id: "m", name: "M"))
        XCTAssertEqual(try decode(LinkAvatar.self, #"{}"#), LinkAvatar())
        XCTAssertEqual(try decode(LinkBotPause.self, #"{}"#), LinkBotPause(summary: "Paused"))
        XCTAssertEqual(try decode(LinkBotDraft.self, #"{"name":"Ada","provider":"claude"}"#), LinkBotDraft(name: "Ada", provider: "claude"))

        let bot = try decode(LinkBot.self, #"""
            {"id":"\#(a)","conversationID":"\#(b)","draft":{"name":"Ada","provider":"claude"},"createdAt":1700000000,
             "phase":"dreaming","pause":{"summary":5}}
            """#)
        XCTAssertNil(bot.phase)
        XCTAssertNil(bot.pause)
        XCTAssertEqual(bot.sharedWith, [])
        XCTAssertEqual(bot.tasks, [])
        XCTAssertFalse(bot.canCall)

        let user = try decode(LinkUser.self, #"{"id":"\#(a)","name":"Bo","plan":"\#(b)","canPairDevices":false,"isAdmin":false,"devices":[]}"#)
        XCTAssertFalse(user.isSuspended)

        XCTAssertEqual(try decode(LinkMessage.self, #"{"id":"\#(a)","conversationID":"\#(b)","author":{"you":{}},"createdAt":1700000000}"#),
                       LinkMessage(id: ida, conversationID: idb, author: .you, body: "", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   delivered: false))
        let attachment = try decode(LinkAttachment.self, #"""
            {"id":"\#(a)","byteCount":3,"annotation":{"version":"x"},"pixelSize":{"width":0,"height":5}}
            """#)
        XCTAssertEqual(attachment, LinkAttachment(id: ida, filename: "Attachment", mediaType: "application/octet-stream", byteCount: 3))
        XCTAssertEqual(try decode(LinkOutgoingMessage.self, #"{"conversationID":"\#(a)","id":"\#(b)","body":"Hi"}"#),
                       LinkOutgoingMessage(conversationID: ida, id: idb, body: "Hi"))
        XCTAssertEqual(try decode(LinkHostedReply.self, #"{"conversationID":"\#(a)","id":"\#(b)"}"#),
                       LinkHostedReply(conversationID: ida, id: idb, body: ""))

        XCTAssertEqual(try decode(LinkCallRecord.self, #"{"botID":"\#(a)","unanswered":"busy"}"#),
                       LinkCallRecord(botID: ida, unanswered: .missed))
        XCTAssertEqual(try decode(LinkIncomingCall.self, #"{"id":"\#(a)","botID":"\#(b)","conversationID":"\#(b)"}"#),
                       LinkIncomingCall(id: ida, botID: idb, conversationID: idb, reason: "", secondsLeft: 45))
        // A Hub that sent the end as a time rings for however long is left by this device's clock.
        let expiring = try decode(LinkIncomingCall.self, #"""
            {"id":"\#(a)","botID":"\#(b)","conversationID":"\#(b)","expiresAt":\#(Date().timeIntervalSince1970 + 3600)}
            """#)
        XCTAssertEqual(expiring.secondsLeft, 3600, accuracy: 60)

        let form = try decode(LinkSignInForm.self, #"{"token":"\#(a)","fields":[{"kind":"password"},{"kind":"passkey"}]}"#)
        XCTAssertEqual(form, LinkSignInForm(token: ida, host: "", pageHost: "", secure: false, crossOrigin: true,
                                            fields: [LinkSignInField(kind: .password)]))
        XCTAssertEqual(try decode(LinkSignInFill.self, #"{"conversationID":"\#(a)","attachmentID":"\#(b)","token":"\#(a)"}"#),
                       LinkSignInFill(conversationID: ida, attachmentID: idb, token: ida))

        let invitation = try decode(LinkInvitation.self, #"""
            {"hubKey":"\#(LinkWireSamples.hubKey.x963.base64EncodedString())","joinKey":"\#(LinkWireSamples.joinKey.base64EncodedString())",
             "expires":1700000900}
            """#)
        XCTAssertEqual(invitation, LinkInvitation(hubName: "Noodle Hub", hubKey: LinkWireSamples.hubKey, endpoints: [], userName: "",
                                                  joinKey: LinkWireSamples.joinKey, expires: Date(timeIntervalSince1970: 1_700_000_900),
                                                  version: 1))
        XCTAssertEqual(try decode(Gamepad.self, #"{"pads":[{"left":"a"}]}"#), Gamepad(pads: [Gamepad.Pad(left: "a")]))
        XCTAssertNil(try? decode(LinkPublicKey.self, #""AAEC""#), "A key that is not a P-256 point does not read")
    }
}

/// A JSON value compared by meaning: object key order and how a number is written do not matter,
/// but a boolean never equals a number.
private indirect enum JSONValue: Decodable, Equatable, CustomStringConvertible {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var description: String {
        switch self {
        case .null: "null"
        case .bool(let value): "\(value)"
        case .number(let value): "\(value)"
        case .string(let value): "\"\(value)\""
        case .array(let values): "[\(values.map(\.description).joined(separator: ","))]"
        case .object(let fields): "{\(fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ","))}"
        }
    }
}
