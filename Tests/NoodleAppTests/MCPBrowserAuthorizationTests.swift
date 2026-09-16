import Foundation
import NoodleMCP
import XCTest
@testable import Noodle

@MainActor final class MCPBrowserAuthorizationTests: XCTestCase {
    func testNativeGoogleStyleCallbackUsesExistingBrowserAndRejectsOtherAppsAndReplays() async throws {
        let redirect = URL(string: "com.googleusercontent.apps.fixture:/oauth2callback")!
        let opened = expectation(description: "Browser opened")
        let browser = MCPBrowserAuthorization { _ in opened.fulfill(); return true }
        let task = Task { try await browser.authorize(url: authorization("native-state"), callbackURL: redirect) }
        defer { task.cancel() }
        await fulfillment(of: [opened], timeout: 2)
        for raw in [
            "com.googleusercontent.apps.other:/oauth2callback?state=native-state&code=test",
            "com.googleusercontent.apps.fixture://host/oauth2callback?state=native-state&code=test",
            "com.googleusercontent.apps.fixture:/other?state=native-state&code=test",
            "com.googleusercontent.apps.fixture:/oauth2callback?state=wrong&code=test"
        ] { XCTAssertFalse(browser.receive(URL(string: raw)!)) }
        let callback = URL(string: redirect.absoluteString + "?state=native-state&code=test")!
        XCTAssertTrue(browser.receive(callback))
        let outcome = try await result(task)
        XCTAssertEqual(try outcome.get(), callback)
        XCTAssertFalse(browser.receive(callback))
    }

    private let redirect = URL(string: "noodle-test://mcp/oauth/callback")!

    private func authorization(_ state: String) -> URL {
        URL(string: "https://example.com/authorize?state=\(state)")!
    }

    private func callback(_ state: String) -> URL {
        URL(string: "noodle-test://mcp/oauth/callback?state=\(state)&code=fixture")!
    }

    private func start(_ browser: MCPBrowserAuthorization, state: String = "first") -> Task<URL, Error> {
        let task = Task { try await browser.authorize(url: authorization(state), callbackURL: redirect) }
        addTeardownBlock { task.cancel() }
        return task
    }

    private func result(_ task: Task<URL, Error>) async throws -> Result<URL, Error> {
        let completed = expectation(description: "Authorization completed")
        Task { _ = await task.result; completed.fulfill() }
        let outcome = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        guard outcome == .completed else {
            task.cancel()
            XCTFail("Authorization did not finish")
            throw CancellationError()
        }
        return await task.result
    }

    func testOnlyTheExactCallbackAndSingleMatchingStateConsumeAuthorization() async throws {
        let opened = expectation(description: "Browser opened")
        let browser = MCPBrowserAuthorization { url in
            XCTAssertEqual(url, self.authorization("first"))
            opened.fulfill()
            return true
        }
        XCTAssertFalse(browser.receive(callback("first")), "An unsolicited callback must be ignored")
        let task = start(browser)
        await fulfillment(of: [opened], timeout: 2)
        for invalid in [
            "other://mcp/oauth/callback?state=first",
            "noodle-test://other/oauth/callback?state=first",
            "noodle-test://mcp:443/oauth/callback?state=first",
            "noodle-test://mcp/oauth/other?state=first",
            "noodle-test://user@mcp/oauth/callback?state=first",
            "noodle-test://user:password@mcp/oauth/callback?state=first",
            "noodle-test://mcp/oauth/callback?state=first#fragment",
            "noodle-test://mcp/oauth/callback?code=fixture",
            "noodle-test://mcp/oauth/callback?state=",
            "noodle-test://mcp/oauth/callback?state=wrong",
            "noodle-test://mcp/oauth/callback?state=first&state=first"
        ] {
            XCTAssertFalse(browser.receive(URL(string: invalid)!), invalid)
        }
        XCTAssertTrue(browser.receive(callback("first")))
        let outcome = try await result(task)
        XCTAssertEqual(try outcome.get(), callback("first"))
        XCTAssertFalse(browser.receive(callback("first")), "A callback can only be consumed once")
    }

    func testMalformedAuthorizationNeverOpensBrowser() async {
        let browser = MCPBrowserAuthorization { _ in XCTFail("Invalid state must not open a browser"); return true }
        for query in ["", "?state", "?state=", "?state=a&state=b"] {
            do {
                _ = try await browser.authorize(url: URL(string: "https://example.com/authorize\(query)")!, callbackURL: redirect)
                XCTFail("Expected invalid callback error for \(query)")
            } catch MCPServiceError.invalidCallback { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSecondAuthorizationCannotReplacePendingLogin() async throws {
        let opened = expectation(description: "Browser opened once")
        let browser = MCPBrowserAuthorization { _ in opened.fulfill(); return true }
        let first = start(browser)
        await fulfillment(of: [opened], timeout: 2)
        do {
            _ = try await browser.authorize(url: authorization("second"), callbackURL: redirect)
            XCTFail("Concurrent login must fail")
        } catch MCPServiceError.invalidCallback { }
        XCTAssertFalse(browser.receive(callback("second")))
        XCTAssertTrue(browser.receive(callback("first")))
        let outcome = try await result(first)
        XCTAssertEqual(try outcome.get(), callback("first"))
    }

    func testCancellationRejectsLateCallbackAndAllowsAnotherLogin() async throws {
        let opened = expectation(description: "First browser opened")
        let reopened = expectation(description: "Second browser opened")
        let browser = MCPBrowserAuthorization { url in
            (url == self.authorization("first") ? opened : reopened).fulfill()
            return true
        }
        let first = start(browser)
        await fulfillment(of: [opened], timeout: 2)
        first.cancel()
        let cancelled = try await result(first)
        guard case .failure(let error) = cancelled else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(browser.receive(callback("first")))
        let second = start(browser, state: "second")
        await fulfillment(of: [reopened], timeout: 2)
        XCTAssertFalse(browser.receive(callback("first")))
        XCTAssertTrue(browser.receive(callback("second")))
        let outcome = try await result(second)
        XCTAssertEqual(try outcome.get(), callback("second"))
    }

    func testAlreadyCancelledAuthorizationDoesNotOpenBrowser() async throws {
        let browser = MCPBrowserAuthorization { _ in XCTFail("Cancelled login must not open a browser"); return true }
        // The main actor cannot enter authorize until this method yields.
        let task = start(browser)
        task.cancel()
        let outcome = try await result(task)
        guard case .failure(let error) = outcome else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(browser.receive(callback("first")))
    }

    func testBrowserOpenFailureClearsPendingLoginForRetry() async throws {
        var opens = 0
        let reopened = expectation(description: "Retry browser opened")
        let browser = MCPBrowserAuthorization { _ in
            opens += 1
            if opens == 1 { return false }
            reopened.fulfill()
            return true
        }
        let failed = try await result(start(browser))
        guard case .failure(let error) = failed else { return XCTFail("Expected browser-open failure") }
        XCTAssertTrue(error.localizedDescription.contains("Could not open your browser"))
        XCTAssertFalse(browser.receive(callback("first")))
        let retry = start(browser, state: "second")
        await fulfillment(of: [reopened], timeout: 2)
        XCTAssertTrue(browser.receive(callback("second")))
        let outcome = try await result(retry)
        XCTAssertEqual(try outcome.get(), callback("second"))
    }

    func testTimeoutRejectsLateCallbackAndAllowsRetry() async throws {
        let reopened = expectation(description: "Retry browser opened")
        let browser = MCPBrowserAuthorization(timeoutDuration: .milliseconds(50)) { url in
            if url == self.authorization("second") { reopened.fulfill() }
            return true
        }
        let expired = try await result(start(browser))
        guard case .failure(MCPServiceError.timedOut) = expired else { return XCTFail("Expected timeout: \(expired)") }
        XCTAssertFalse(browser.receive(callback("first")))
        let retry = start(browser, state: "second")
        await fulfillment(of: [reopened], timeout: 2)
        XCTAssertTrue(browser.receive(callback("second")))
        let outcome = try await result(retry)
        XCTAssertEqual(try outcome.get(), callback("second"))
    }
}
