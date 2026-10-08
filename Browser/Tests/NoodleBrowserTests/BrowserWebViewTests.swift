import BrowserCore
@testable import NoodleBrowser
import XCTest

final class BrowserWebViewTests: XCTestCase {
    /// Switching browsers and back can tear down the view left behind after the returning one took the page.
    @MainActor func testTearingDownAViewLeftBehindKeepsThePageWhereItWent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let tab = try runtime.makeTab(browserID: try library.create(name: "Work").id)
        let left = BrowserWebContainer(web: tab.web), returning = BrowserWebContainer(web: tab.web)
        BrowserWebView.dismantleNSView(left, coordinator: tab)
        XCTAssertTrue(tab.web.superview === returning)
        BrowserWebView.dismantleNSView(returning, coordinator: tab)
        XCTAssertTrue(tab.web.window === tab.surface)
    }

    /// A tab shows the page's own icon: one that fits a tab, a scalable one before any other, and
    /// the site's favicon.ico when the page names none.
    func testATabPicksThePagesIconThatFitsATab() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/news/today"))
        func link(_ rel: String, _ href: String, sizes: String = "", type: String = "") -> [String: String] {
            ["rel": rel, "href": href, "sizes": sizes, "type": type]
        }
        let sized = [link("icon", "https://example.com/16.png", sizes: "16x16"), link("icon", "https://example.com/32.png", sizes: "32x32"),
                     link("icon", "https://example.com/96.png", sizes: "96x96"), link("apple-touch-icon", "https://example.com/180.png")]
        XCTAssertEqual(BrowserFavicon.choose(sized, page: page)?.absoluteString, "https://example.com/32.png")
        XCTAssertEqual(BrowserFavicon.choose(sized + [link("icon", "https://example.com/i.svg", sizes: "any", type: "image/svg+xml")],
                                             page: page)?.absoluteString, "https://example.com/i.svg")
        XCTAssertEqual(BrowserFavicon.choose([link("apple-touch-icon", "https://example.com/180.png")], page: page)?.absoluteString,
                       "https://example.com/180.png", "a touch icon is better than none")
        XCTAssertEqual(BrowserFavicon.choose([link("shortcut icon", "/old.ico")], page: page)?.absoluteString, "https://example.com/old.ico")
        XCTAssertEqual(BrowserFavicon.choose([link("icon", "javascript:alert(1)")], page: page)?.absoluteString,
                       "https://example.com/favicon.ico", "an icon that is not an image address was used")
        XCTAssertEqual(BrowserFavicon.choose([], page: page)?.absoluteString, "https://example.com/favicon.ico")
        XCTAssertNil(BrowserFavicon.choose([], page: try XCTUnwrap(URL(string: "about:blank"))))
    }
}
