import XCTest
@testable import NoodletRuntime

final class WebNetworkTests: XCTestCase {
    @MainActor func testNativeRequestBoundaryAndExplicitCredentials() async throws {
        for url in ["file:///etc/hosts", "ftp://example.com/file", "https://user:secret@example.com", "data:text/plain,hello"] {
            XCTAssertThrowsError(try WebNetwork.request(["url": url]))
        }
        XCTAssertThrowsError(try WebNetwork.request(["url":"https://example.com", "headers":["X-Test":"ok\r\nInjected: bad"]]))
        XCTAssertThrowsError(try WebNetwork.request(["url":"https://example.com", "method":"CONNECT"]))
        XCTAssertThrowsError(try WebNetwork.request(["url":"https://example.com", "body":"aGVsbG8="]))
        let request = try WebNetwork.request(["url":"https://example.com/api", "method":"POST", "body":"aGVsbG8=", "headers":["Authorization":"Bearer test", "Content-Type":"text/plain", "Content-Length":"999"]])
        XCTAssertEqual(request.httpBody, Data("hello".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"), "Bearer test")
        XCTAssertNil(request.value(forHTTPHeaderField:"Content-Length"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }
}
