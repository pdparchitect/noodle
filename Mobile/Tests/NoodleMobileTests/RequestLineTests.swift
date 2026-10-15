import Foundation
import HubLink
@testable import NoodleMobile
import Testing

@Suite struct RequestLineTests {
    @Test func eachStatusHasItsOwnWording() {
        let expected: [(LinkRequestLine.Status, String, Bool)] = [
            (.waiting, "Asking Accounts", false),
            (.answered, "Accounts answered", false),
            (.cancelled, "Cancelled asking Accounts", false),
            (.expired, "Accounts didn’t answer", true),
            (.withheld, "Accounts couldn’t help", true),
        ]
        for (status, title, failed) in expected {
            let line = LinkRequestLine(helperName: "Accounts", status: status)
            #expect(line.title == title)
            #expect(line.failed == failed)
        }
    }
}
