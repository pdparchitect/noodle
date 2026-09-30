import Foundation
import HubLink
import XCTest

/// A Hub forgets which noodlets it readied when it restarts. A device with one open readies it
/// again and carries on, so the person never sees it.
final class LinkNoodletSessionTests: XCTestCase {
    private actor Hub {
        var grant = UUID()
        var readied = 0
        func forget() { grant = UUID() }
        func answer(_ request: LinkRequest) throws -> LinkResponse {
            switch request {
            case .noodlet:
                readied += 1
                return .noodlet(LinkNoodlet(grant: grant, noodletID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
                                            revision: "r1", byteCount: 5, manifest: Data("{}".utf8)))
            case .noodletArchive(let grant, _):
                guard grant == self.grant else { throw LinkError(LinkProtocol.noodletForgotten) }
                return .chunk(data: Data("files".utf8), total: 5)
            case .noodletCall(let piece):
                guard piece.grant == grant else { throw LinkError(LinkProtocol.noodletForgotten) }
                return .noodletAnswer(piece.data)
            default:
                throw LinkError(LinkProtocol.unknownRequest)
            }
        }
    }

    func testAForgottenNoodletIsReadiedAgain() async throws {
        let hub = Hub()
        let session = try await LinkNoodletSession.open(conversationID: UUID(), attachmentID: UUID()) { try await hub.answer($0) }
        let first = await session.noodlet.grant
        await hub.forget()
        let files = try await session.archive(from: 0)
        XCTAssertEqual(files, Data("files".utf8))
        let second = await session.noodlet.grant
        XCTAssertNotEqual(second, first)

        // A call in pieces starts over once readied again, as the Hub forgot its pieces too.
        await hub.forget()
        do {
            _ = try await session.call(id: UUID(), offset: 0, total: 2, data: Data("{}".utf8))
            XCTFail("the Hub answered a grant it forgot")
        } catch {
            let renewed = try await session.renew(after: error)
            XCTAssertTrue(renewed)
        }
        let answer = try await session.call(id: UUID(), offset: 0, total: 2, data: Data("{}".utf8))
        XCTAssertEqual(answer, Data("{}".utf8))
        let other = try await session.renew(after: LinkError("That noodlet is not this bot's."))
        XCTAssertFalse(other, "readied again for a failure that was not the Hub forgetting")
        let readied = await hub.readied
        XCTAssertEqual(readied, 3)
    }
}
