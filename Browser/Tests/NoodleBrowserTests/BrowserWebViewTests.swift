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
}
