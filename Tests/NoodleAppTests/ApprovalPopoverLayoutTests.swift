import AppKit
import NoodleCore
import SwiftUI
import XCTest
@testable import Noodle

@MainActor final class ApprovalPopoverLayoutTests: XCTestCase {
    private final class Host: AgentApprovalHost {
        let approvals = AgentApprovalDesk()
        func taskAvatar(_ agent: AgentRecord) -> AnyView { AnyView(Color.gray.frame(width: 22, height: 22)) }
        func openConversation(for approval: AgentApproval, of agentID: UUID) {}
    }

    private func height(description: String, input: [String: String]) throws -> CGFloat {
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let approval = AgentApproval(conversationID: nil, provider: "cloudflare", providerTitle: "Cloudflare", tool: "execute",
                                     toolDescription: description, input: String(decoding: data, as: UTF8.self),
                                     reason: "Reads every zone's TLS and WAF settings for the audit.", createdAt: Date())
        let popover = ApprovalPopover(store: Host(), agent: AgentRecord(displayName: "Daring Zinnia"), approval: approval) {}
        return NSHostingView(rootView: popover).fittingSize.height
    }

    /// A server whose tool comes with a manual and takes a whole script still fits on screen with its buttons:
    /// the call scrolls, the popover does not grow past it.
    func testALongCallScrollsInsteadOfPushingTheButtonsOffScreen() throws {
        let manual = Array(repeating: "Example: return cloudflare.request({ method: \"GET\", path: \"/zones\" });", count: 80).joined(separator: "\n")
        let script = Array(repeating: "const all = (await cloudflare.request({ method: \"GET\", path: `/zones/${z.id}/settings` })).result;",
                           count: 80).joined(separator: "\n")
        XCTAssertLessThanOrEqual(try height(description: manual, input: ["code": script]), 520)
    }

    /// A short call keeps its own height rather than the longest one's.
    func testAShortCallIsNotPaddedToTheLimit() throws {
        XCTAssertLessThan(try height(description: "Block an IP address.", input: ["ip": "198.51.100.23"]), 300)
    }
}
