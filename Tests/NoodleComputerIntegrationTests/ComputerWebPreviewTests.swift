import AppKit
import ComputerBridge
import WebKit
import XCTest
@testable import Noodle

private final class PreviewChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

@MainActor final class ComputerWebPreviewTests: XCTestCase {
    private func fixture() async throws -> ComputerLifecycleFixture {
        _ = NSApplication.shared
        let f = try ComputerLifecycleFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        try await f.prepare()
        var response = ComputerResponse()
        response.display = .init(url: URL(string: "https://guest.invalid/")!, password: "fixture-only")
        f.provider.responses[.display] = response
        return f
    }
    private func preview(_ f: ComputerLifecycleFixture, clock: PreviewPollClock) -> ComputerPreviewWeb {
        let web = ComputerPreviewWeb(card: f.card, controller: f.controller, sleep: clock.sleep, load: { _, _ in })
        addTeardownBlock { @MainActor in web.stop(); clock.finish() }
        web.start(); return web
    }
    private func policy(_ web: ComputerPreviewWeb, view: WKWebView, url: String, download: Bool = false) -> WKNavigationActionPolicy? {
        web.navigationPolicy(in: view, url: URL(string: url), download: download)
    }

    func testWebPreviewUsesEphemeralProfileAndRestrictsNavigationToGuest() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), web = preview(f, clock: clock)
        try await f.wait { web.view != nil }
        let view = try XCTUnwrap(web.view)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(view.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertEqual(policy(web, view: view, url: "https://guest.invalid/page"), .allow)
        for url in ["http://guest.invalid/", "https://other.invalid/", "https://guest.invalid:8000/", "file:///tmp/fixture", "https://user:password@guest.invalid/"] {
            XCTAssertEqual(policy(web, view: view, url: url), .cancel, url)
        }
        XCTAssertEqual(policy(web, view: view, url: "https://guest.invalid/file", download: true), .cancel)
        XCTAssertTrue(view.configuration.userContentController.userScripts.contains { $0.source.contains("navigator, 'clipboard'") })
        web.stop()
        XCTAssertEqual(policy(web, view: view, url: "https://guest.invalid/"), .cancel)
    }

    func testLateFailureFromStoppedPreviewCannotRemoveRestartedView() async throws {
        let f = try await fixture(), clock = PreviewPollClock()
        f.provider.blockedOperation = .display
        let web = preview(f, clock: clock), old = web.task
        try await f.wait { f.provider.blocked != nil }
        web.stop(); web.start()
        try await f.wait { web.view != nil }
        let current = web.view
        f.provider.blocked?.finish(.failure(ComputerBridgeError("Retired display error")))
        await old?.value
        XCTAssertTrue(web.view === current)
        XCTAssertFalse(web.status.stringValue.contains("Retired"))
    }

    func testMissingDisplayRemovesExistingPageAndOffersRecovery() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), web = preview(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        f.provider.responses[.display] = .init()
        clock.tick(); await web.task?.value
        XCTAssertNil(web.view)
        XCTAssertTrue(web.status.stringValue.localizedCaseInsensitiveContains("display"))
    }

    func testChangedCredentialsRequireExplicitReconnect() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), web = preview(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        var changed = ComputerResponse()
        changed.display = .init(url: URL(string: "https://guest.invalid/")!, password: "replacement")
        f.provider.responses[.display] = changed
        clock.tick(); await web.task?.value
        XCTAssertNil(web.view)
        XCTAssertTrue(web.status.stringValue.contains("restarted"))
        XCTAssertEqual(f.provider.count(.display), 2)
    }

    func testRetiredAndRevokedWebViewsCannotCommitNavigationResponses() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), web = preview(f, clock: clock)
        try await f.wait { web.view != nil }
        let old = try XCTUnwrap(web.view)
        web.stop(); web.start()
        try await f.wait { web.view != nil }
        let current = try XCTUnwrap(web.view)
        XCTAssertEqual(policy(web, view: old, url: "https://guest.invalid/"), .cancel)
        let url = URL(string: "https://guest.invalid/")!
        XCTAssertEqual(web.responsePolicy(in: old, url: url, supported: true), .cancel)
        XCTAssertEqual(web.responsePolicy(in: current, url: url, supported: true), .allow)
        XCTAssertEqual(web.responsePolicy(in: current, url: URL(string: "https://other.invalid/"), supported: true), .cancel)
        XCTAssertEqual(web.responsePolicy(in: current, url: url, supported: false), .cancel)
        try f.controller.assign([], to: f.a)
        XCTAssertEqual(web.responsePolicy(in: current, url: url, supported: true), .cancel)
    }

    func testCredentialsAreOnlyReturnedToCurrentAuthorizedWebView() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), web = preview(f, clock: clock)
        try await f.wait { web.view != nil }
        let old = try XCTUnwrap(web.view)
        web.stop(); web.start()
        try await f.wait { web.view != nil }
        let current = try XCTUnwrap(web.view)
        let space = URLProtectionSpace(host: "guest.invalid", port: 443, protocol: "https", realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: PreviewChallengeSender())
        web.webView(old, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge); XCTAssertNil(credential)
        }
        web.webView(current, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential); XCTAssertEqual(credential?.password, "fixture-only")
        }
        try f.controller.assign([], to: f.a)
        web.webView(current, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge); XCTAssertNil(credential)
        }
    }

    func testRevocationDuringPollRemovesPageAndRejectsLateNavigationCallbacks() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), web = preview(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        let view = try XCTUnwrap(web.view)
        f.provider.blockedOperation = .display
        clock.tick(); try await f.wait { f.provider.blocked != nil }
        try f.controller.assign([], to: f.a)
        f.provider.blocked?.finish(.success(f.provider.response(.display)))
        await web.task?.value
        XCTAssertNil(web.view); XCTAssertTrue(web.status.stringValue.contains("revoked"))
        web.webView(view, didFail: nil, withError: ComputerBridgeError("Retired navigation"))
        XCTAssertTrue(web.status.stringValue.contains("revoked"))
    }
}
