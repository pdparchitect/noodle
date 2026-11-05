import BrowserBridge
import BrowserCore
import Darwin
@testable import NoodleBrowser
import WebKit
import XCTest

/// A person watching a browser live signs in with what they type or pick from their passwords: the
/// page's sign-in fields are found once when they ask, filled as typing would leave them, and the
/// passwords they filled are emptied when they stop watching, before any bot gets the browser back.
@MainActor final class BrowserSignInTests: XCTestCase {
    private static let site = URL(string: "https://login.example.test/")!

    func testAUsernameAndPasswordAreFoundAndFilledSoThePageSeesThem() async throws {
        let watched = try await Watched(fixture: "sign-in-login.html")
        defer { watched.end() }
        let form = try await watched.form()
        XCTAssertEqual(form.fields.map(\.kind), [.email, .password], "the hidden password or the search box was offered")
        XCTAssertEqual(form.fields.map(\.label), ["Email or username", "Password"])
        XCTAssertEqual(form.host, "login.example.test")
        XCTAssertEqual(form.pageHost, "login.example.test")
        XCTAssertTrue(form.secure)
        XCTAssertFalse(form.crossOrigin)

        let submitted = try await watched.fill(BrowserSignInValues(token: form.token, username: "ada@example.com", password: "correct horse"))
        XCTAssertFalse(submitted)
        let seen = try await watched.page("seen") as? [String: String]
        XCTAssertEqual(seen, ["user": "ada@example.com", "pass": "correct horse"], "the page's input listeners missed the values")
        let submissions = try await watched.page("submitted") as? Int
        XCTAssertEqual(submissions, 0, "the form was submitted without being asked")
        let decoy = try await watched.page("document.querySelector('#decoy').value") as? String
        XCTAssertEqual(decoy, "", "a hidden password field was filled")

        let again = try await watched.form()
        let resubmitted = try await watched.fill(BrowserSignInValues(token: again.token, password: "correct horse", submit: true))
        XCTAssertTrue(resubmitted)
        let resubmissions = try await watched.page("submitted") as? Int
        XCTAssertEqual(resubmissions, 1)
    }

    func testACodeSplitAcrossBoxesIsOneFieldFilledABoxAtATime() async throws {
        let watched = try await Watched(fixture: "sign-in-code.html")
        defer { watched.end() }
        let form = try await watched.form()
        XCTAssertEqual(form.fields, [BrowserSignInField(kind: .oneTimeCode, length: 6)])
        _ = try await watched.fill(BrowserSignInValues(token: form.token, oneTimeCode: "482913"))
        let code = try await watched.page("code()") as? String
        XCTAssertEqual(code, "482913")
        let inputs = try await watched.page("inputs") as? Int
        XCTAssertEqual(inputs, 6)
    }

    func testFieldsInsideShadowRootsAreFound() async throws {
        let watched = try await Watched(fixture: "sign-in-shadow.html")
        defer { watched.end() }
        let form = try await watched.form()
        XCTAssertEqual(form.fields.map(\.kind), [.email, .password])
        _ = try await watched.fill(BrowserSignInValues(token: form.token, username: "ada@example.com", password: "correct horse"))
        let seen = try await watched.page("seen") as? [String: String]
        XCTAssertEqual(seen, ["email": "ada@example.com", "password": "correct horse"])
    }

    /// macOS 26 can report a page's view leaving its window, as a stopping tab's does, as a gesture error of
    /// its own. The error is the system's, so it fails no sign-in test; any other failure still does.
    func testTheSystemsGestureErrorWhenAPageLeavesItsWindowIsNotTheBrowsers() async throws {
        let watched = try await Watched(fixture: "sign-in-shadow.html")
        defer { watched.end() }
        record(XCTIssue(type: .thrownError,
                        compactDescription: #"caught error: "InvalidTransition { phase: idle targetPhase: failed(removedFromContainer) }""#))
    }

    func testAFormInAFrameIsFoundAndSaysWhoseItIs() async throws {
        let watched = try await Watched(fixture: "sign-in-frame.html", frames: 2)
        defer { watched.end() }
        let form = try await watched.form()
        XCTAssertEqual(form.fields.map(\.kind), [.username, .password])
        XCTAssertEqual(form.host, "login.example.test")
        XCTAssertFalse(form.crossOrigin)
        _ = try await watched.fill(BrowserSignInValues(token: form.token, username: "ada", password: "correct horse"))
        let seen = try await watched.frame("seen") as? [String: String]
        XCTAssertEqual(seen, ["user": "ada", "pass": "correct horse"])

        // A frame with an origin of its own is another site, however it was loaded.
        let sandboxed = try await Watched(fixture: "sign-in-frame.html", frames: 2,
                                          changing: ("<iframe ", "<iframe sandbox=\"allow-scripts allow-forms\" "))
        defer { sandboxed.end() }
        let other = try await sandboxed.form()
        XCTAssertEqual(other.fields.map(\.kind), [.username, .password])
        XCTAssertTrue(other.crossOrigin)
        XCTAssertFalse(other.secure)
        XCTAssertEqual(other.pageHost, "login.example.test")
    }

    func testFilledPasswordsAreEmptiedWhenTheLastViewerLeavesBeforeBotsGetTheBrowser() async throws {
        let watched = try await Watched(fixture: "sign-in-login.html")
        defer { watched.end() }
        let form = try await watched.form()
        _ = try await watched.fill(BrowserSignInValues(token: form.token, username: "ada@example.com", password: "correct horse"))
        var bot = BrowserRequest(.eval, browserID: watched.browser, tabID: watched.tab.id)
        bot.text = "return document.querySelector('#pass').value"
        do { _ = try await watched.runtime.perform(bot); XCTFail("a bot used the browser while a person watched it") } catch {}

        watched.viewer.close()
        var read: String?
        for _ in 0..<250 {
            if let answer = try? await watched.runtime.perform(bot).text { read = answer; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(read, "\"\"", "a bot read the password the person filled")
        let user = try await watched.page("document.querySelector('#user').value") as? String
        XCTAssertEqual(user, "ada@example.com", "more than passwords was emptied")
    }

    /// A bot's script could have left a listener in the page to read what a person types, so a page a bot
    /// ran scripts on is not offered for signing in until it loads again.
    func testAPageABotRanScriptsOnIsNotOfferedUntilItReloads() async throws {
        let watched = try await Watched(fixture: "sign-in-login.html") { runtime, browser, tab in
            var bot = BrowserRequest(.eval, browserID: browser, tabID: tab.id)
            bot.text = "document.addEventListener('input', event => { window.stolen = event.target.value }, true); return true"
            _ = try await runtime.perform(bot)
        }
        defer { watched.end() }
        do {
            _ = try await watched.form()
            XCTFail("a page a bot scripted was offered for signing in")
        } catch { XCTAssertEqual(error.localizedDescription, "A bot ran scripts on this page. Reload it, then try again.") }

        _ = try await watched.page("window.replaced = true")
        watched.tab.web.loadHTMLString(try Watched.fixture("sign-in-login.html"), baseURL: Self.site)
        try await watched.loaded()
        let form = try await watched.form()
        XCTAssertEqual(form.fields.map(\.kind), [.email, .password])
    }

    /// A dialog the page shows when the last viewer leaves is dismissed, so the password is still emptied.
    func testAPasswordIsEmptiedEvenWithADialogOpenWhenTheViewerLeaves() async throws {
        let watched = try await Watched(fixture: "sign-in-login.html")
        defer { watched.end() }
        let form = try await watched.form()
        _ = try await watched.fill(BrowserSignInValues(token: form.token, password: "correct horse"))
        // Not awaited: a script call the alert interrupted would wait as long as the alert does.
        watched.tab.web.evaluateJavaScript("setTimeout(() => alert('Leaving so soon?'), 200); true", completionHandler: nil)
        for _ in 0..<250 where watched.tab.dialog == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(watched.tab.dialog, "the page showed no dialog")

        watched.viewer.close()
        var bot = BrowserRequest(.eval, browserID: watched.browser, tabID: watched.tab.id)
        bot.text = "return document.querySelector('#pass').value"
        var read: String?
        for _ in 0..<500 {
            if let answer = try? await watched.runtime.perform(bot).text { read = answer; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(read, "\"\"", "a bot read the password the person filled")
    }

    /// A field of a kind a later Noodle Browser finds is left out, so the Hub still reads the form.
    func testAFormWithAFieldOfAKindNotKnownYetStillReads() throws {
        let token = UUID()
        let json = #"{"token":"\#(token)","host":"a.test","pageHost":"a.test","secure":true,"crossOrigin":false,"#
            + #""fields":[{"kind":"passkey"},{"kind":"password","label":"Password"}]}"#
        let form = try JSONDecoder().decode(BrowserSignInForm.self, from: Data(json.utf8))
        XCTAssertEqual(form.fields, [BrowserSignInField(kind: .password, label: "Password")])
    }

    func testSigningInNeedsSomeoneWatchingAndTheSamePage() async throws {
        let watched = try await Watched(fixture: "sign-in-login.html")
        defer { watched.end() }
        let form = try await watched.form()
        _ = try await watched.page("window.replaced = true")
        watched.tab.web.loadHTMLString(try Watched.fixture("sign-in-login.html"), baseURL: Self.site)
        try await watched.loaded()
        do {
            _ = try await watched.fill(BrowserSignInValues(token: form.token, password: "correct horse"))
            XCTFail("a password went into a page that replaced the one it was meant for")
        } catch { XCTAssertEqual(error.localizedDescription, BrowserTab.signInChanged) }

        watched.viewer.close()
        for _ in 0..<250 where watched.runtime.isWatched(watched.browser) { try await Task.sleep(for: .milliseconds(20)) }
        do {
            _ = try await watched.form()
            XCTFail("sign-in fields were offered with nobody watching")
        } catch { XCTAssertEqual(error.localizedDescription, "Open the browser live to sign in.") }
    }

    func testBotsAndOtherAppsCannotSignInAndTheValuesNeverShowInDescriptions() throws {
        for operation in [BrowserOperation.signInForm, .signInFill] {
            XCTAssertTrue(operation.isManagement)
            XCTAssertFalse(BrowserOperation.agentCases.contains(operation))
            XCTAssertFalse(BrowserOperation.externalCases.contains(operation))
        }
        var fill = BrowserRequest(.signInFill, browserID: UUID())
        XCTAssertThrowsError(try fill.validate(), "a fill with nothing to fill")
        fill.signIn = BrowserSignInValues(token: UUID(), username: "ada@example.com", password: "correct horse")
        XCTAssertNoThrow(try fill.validate())
        var tooLong = fill
        tooLong.signIn?.password = String(repeating: "x", count: BrowserSignInValues.maximumLength + 1)
        XCTAssertThrowsError(try tooLong.validate())
        var stray = BrowserRequest(.eval, browserID: UUID(), tabID: UUID())
        stray.text = "1"; stray.signIn = fill.signIn
        XCTAssertThrowsError(try stray.validate(), "sign-in values rode along another operation")

        var dumped = ""
        dump(fill, to: &dumped)
        for text in [String(describing: fill), String(reflecting: fill), "\(fill.signIn!)", dumped] {
            XCTAssertFalse(text.contains("correct horse"), text)
            XCTAssertFalse(text.contains("ada@example.com"), text)
        }
    }

    func testTheBrowserSaysItCanSignIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = BrowserRuntime(library: BrowserLibrary(root: root))
        defer { runtime.shutdown() }
        let listed = try await runtime.perform(BrowserRequest(.list))
        XCTAssertTrue(listed.features?.contains(BrowserSignInForm.feature) == true)
    }
}

/// A fixture page in a tab of a browser of its own, with someone watching it live.
@MainActor private final class Watched {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runtime: BrowserRuntime
    let browser: UUID
    let tab: BrowserTab
    let viewer: SurfaceSocket
    private let frames: Int

    /// `beforeWatching` runs once the page has loaded, while bots may still use the browser.
    init(fixture name: String, frames: Int = 1, changing: (String, String)? = nil,
         beforeWatching: ((BrowserRuntime, UUID, BrowserTab) async throws -> Void)? = nil) async throws {
        // The page's view goes into its tab's window while it loads and while someone watches, and out again
        // after, and when the tab stops. macOS 26's gesture tracking now and then throws an InvalidTransition
        // error of its own from inside that removal, which XCTest then reports against the test.
        let systemGestures = XCTExpectedFailure.Options()
        systemGestures.isStrict = false
        systemGestures.issueMatcher = { issue in
            let text = [issue.compactDescription, issue.detailedDescription ?? "", issue.associatedError.map { "\($0)" } ?? ""].joined()
            return text.contains("InvalidTransition") && text.contains("removedFromContainer")
        }
        XCTExpectFailure("macOS gesture tracking failed while a page's view left its window", options: systemGestures)
        let library = BrowserLibrary(root: root)
        runtime = BrowserRuntime(library: library)
        browser = try library.create(name: "Sign in").id
        tab = try runtime.makeTab(browserID: browser)
        self.frames = frames
        var html = try Self.fixture(name)
        if let changing { html = html.replacingOccurrences(of: changing.0, with: changing.1) }
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        viewer = SurfaceSocket(fd: fds[1])
        tab.web.loadHTMLString(html, baseURL: URL(string: "https://login.example.test/")!)
        try await loaded()
        try await beforeWatching?(runtime, browser, tab)
        _ = try await runtime.perform(BrowserRequest(.surfaceStream, browserID: browser, tabID: tab.id), surface: SurfaceSocket(fd: fds[0]))
        XCTAssertTrue(runtime.isWatched(browser))
    }

    static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Waits for the fixture, and its frames, to load and say they are there; after a page set `replaced`, for the next.
    func loaded() async throws {
        for _ in 0..<250 {
            let ready = try? await tab.web.callAsyncJavaScript(
                "return location.host === 'login.example.test' && document.readyState === 'complete' && !window.replaced", contentWorld: .page) as? Bool
            if ready == true, tab.frames.count >= frames { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the fixture did not load")
    }

    func form() async throws -> BrowserSignInForm {
        let found = try await runtime.perform(BrowserRequest(.signInForm, browserID: browser)).signInForm
        return try XCTUnwrap(found)
    }

    func fill(_ values: BrowserSignInValues) async throws -> Bool {
        var request = BrowserRequest(.signInFill, browserID: browser)
        request.signIn = values
        return try await runtime.perform(request).submitted ?? false
    }

    /// What the page's own scripts see.
    func page(_ expression: String) async throws -> Any? {
        try await tab.web.callAsyncJavaScript("return \(expression)", contentWorld: .page)
    }

    /// What the scripts of the page's frame see.
    func frame(_ expression: String) async throws -> Any? {
        let frame = try XCTUnwrap(tab.frames.first { !$0.value.isMainFrame }?.value)
        return try await tab.web.callAsyncJavaScript("return \(expression)", in: frame, contentWorld: .page)
    }

    func end() {
        viewer.close()
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
