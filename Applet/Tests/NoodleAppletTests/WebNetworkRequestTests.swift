import XCTest

@testable import NoodleApplet

/// Pins the request boundary a noodlet's `fetch` goes through. These are pure
/// validation checks; none of them opens a connection.
@MainActor final class WebNetworkRequestTests: XCTestCase {
    private func request(_ body: [String: Any]) throws -> URLRequest {
        try WebNetwork.request(body)
    }

    private func rejects(_ body: [String: Any], _ message: String) {
        XCTAssertThrowsError(try request(body), message)
    }

    // MARK: - URL

    func testOnlyHTTPAndHTTPSURLsAreAccepted() throws {
        XCTAssertEqual(try request(["url": "https://example.com/a"]).url?.scheme, "https")
        XCTAssertEqual(try request(["url": "http://example.com/a"]).url?.scheme, "http")
        // Mixed case schemes are still recognized.
        XCTAssertNotNil(try request(["url": "HTTPS://example.com/a"]).url)

        for address in [
            "file:///etc/passwd",
            "ftp://example.com/a",
            "data:text/plain;base64,AA==",
            "javascript:alert(1)",
            "https://",
            "not a url at all",
        ] {
            rejects(["url": address], "accepted \(address)")
        }
    }

    func testEmbeddedCredentialsAreRejected() {
        rejects(["url": "https://user@example.com/a"], "accepted a user")
        rejects(["url": "https://user:secret@example.com/a"], "accepted a password")
    }

    func testOverlongURLsAreRejected() {
        let long = "https://example.com/" + String(repeating: "a", count: 8193)
        rejects(["url": long], "accepted an 8 KiB+ URL")
    }

    func testAMissingURLIsRejected() {
        rejects([:], "accepted a missing URL")
        rejects(["url": 42], "accepted a non-string URL")
    }

    // MARK: - Method

    func testMethodDefaultsToGETAndIsUppercased() throws {
        XCTAssertEqual(try request(["url": "https://example.com"]).httpMethod, "GET")
        XCTAssertEqual(try request(["url": "https://example.com", "method": "post"]).httpMethod, "POST")
    }

    func testTunnellingAndTracingMethodsAreRejected() {
        for method in ["CONNECT", "TRACE", "TRACK"] {
            rejects(["url": "https://example.com", "method": method], "accepted \(method)")
        }
    }

    func testMalformedMethodsAreRejected() {
        for method in ["", "GE T", "GET\r\nX", "gét", "G3T", String(repeating: "A", count: 33)] {
            rejects(["url": "https://example.com", "method": method], "accepted \(method.debugDescription)")
        }
    }

    // MARK: - Headers

    func testHeadersArePassedThroughExceptFramingHeaders() throws {
        let built = try request([
            "url": "https://example.com",
            "headers": [
                "Authorization": "Bearer token", "Accept": "application/json",
                // Framing is URLSession's to decide.
                "Host": "evil.example", "Content-Length": "99",
                "Connection": "close", "Transfer-Encoding": "chunked",
            ],
        ])
        XCTAssertEqual(built.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(built.value(forHTTPHeaderField: "Accept"), "application/json")
        for dropped in ["Host", "Content-Length", "Connection", "Transfer-Encoding"] {
            XCTAssertNil(built.value(forHTTPHeaderField: dropped), dropped)
        }
        XCTAssertEqual(built.httpShouldHandleCookies, false)
    }

    func testHeaderInjectionIsRejected() {
        for (key, value) in [
            ("X-Bad\r\nInjected", "ok"), ("X-Bad", "value\r\nInjected: 1"),
            ("X-Bad", "value\nInjected: 1"), ("Has Space", "ok"), ("Has:Colon", "ok"), ("", "ok"),
        ] {
            rejects(["url": "https://example.com", "headers": [key: value]],
                    "accepted header \(key.debugDescription): \(value.debugDescription)")
        }
    }

    func testTooManyOrTooLargeHeadersAreRejected() {
        var many: [String: String] = [:]
        for index in 0...100 { many["X-Key-\(index)"] = "v" }
        rejects(["url": "https://example.com", "headers": many], "accepted 101 headers")

        let huge = ["X-Big": String(repeating: "a", count: 65_537)]
        rejects(["url": "https://example.com", "headers": huge], "accepted a 64 KiB+ header set")
    }

    // MARK: - Body

    func testBodyIsBase64DecodedAndRejectedOnSafeMethods() throws {
        let encoded = Data("hello".utf8).base64EncodedString()
        let built = try request(["url": "https://example.com", "method": "POST", "body": encoded])
        XCTAssertEqual(built.httpBody.map { String(decoding: $0, as: UTF8.self) }, "hello")

        for method in ["GET", "HEAD"] {
            rejects(["url": "https://example.com", "method": method, "body": encoded],
                    "accepted a body with \(method)")
        }
        rejects(["url": "https://example.com", "method": "POST", "body": "not base64!!"],
                "accepted a non-base64 body")
    }

    func testOversizedBodiesAreRejected() {
        let tooBig = String(repeating: "A", count: (WebNetwork.limit + 2) / 3 * 4 + 4)
        rejects(["url": "https://example.com", "method": "POST", "body": tooBig],
                "accepted a body over the 16 MiB limit")
    }

    // MARK: - Concurrency guards

    func testNetworkMustBeEnabledForTheNoodlet() async {
        let network = WebNetwork()
        do {
            _ = try await network.fetch(["id": "a", "url": "https://example.com"], enabled: false)
            XCTFail("Disabled network performed a request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("network: true"), error.localizedDescription)
        }
    }

    func testAnOverlongRequestIDIsRejected() async {
        let network = WebNetwork()
        do {
            _ = try await network.fetch(
                ["id": String(repeating: "i", count: 101), "url": "https://example.com"], enabled: true)
            XCTFail("Accepted an overlong request id")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("eight concurrent"), error.localizedDescription)
        }
    }

    func testAMissingRequestIDIsRejected() async {
        let network = WebNetwork()
        do {
            _ = try await network.fetch(["url": "https://example.com"], enabled: true)
            XCTFail("Accepted a request without an id")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("eight concurrent"), error.localizedDescription)
        }
    }

    func testCancellingAnUnknownRequestIsHarmless() {
        let network = WebNetwork()
        network.cancel("never-started")
        network.stop()
    }
}
