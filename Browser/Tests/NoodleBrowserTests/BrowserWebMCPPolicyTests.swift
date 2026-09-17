import Foundation
@testable import NoodleBrowser
import XCTest

final class BrowserWebMCPPolicyTests: XCTestCase {
    @MainActor func testResponseOptOutAndOriginIsolation() throws {
        func permitted(_ headers: [String: String]) -> Bool {
            BrowserWebMCP.permits(HTTPURLResponse(url: URL(string: "https://example.com/page")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        XCTAssertTrue(permitted([:]))
        XCTAssertTrue(permitted(["Permissions-Policy": "camera=(), tools=(self)"]))
        XCTAssertTrue(permitted(["Permissions-Policy": "tools=*"]))
        XCTAssertTrue(permitted(["Permissions-Policy": "tools=(\"https://example.com\")"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=()", "Origin-Agent-Cluster": "?1"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=(\"https://elsewhere.example\")"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=garbage"]))
        XCTAssertFalse(permitted(["Permissions-Policy": "tools=*, tools=()"] ))
        XCTAssertFalse(permitted(["Origin-Agent-Cluster": "?0"]))
    }
}
