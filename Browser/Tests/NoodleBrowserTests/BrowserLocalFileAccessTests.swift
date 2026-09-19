import Foundation
@testable import NoodleBrowser
import XCTest

final class BrowserLocalFileAccessTests: XCTestCase {
    func testPageNavigationNeverReachesLocalFilesOrOtherApplications() throws {
        for url in ["https://example.com/", "HTTP://example.com/", "about:blank", "blob:https://example.com/1", "data:text/html,ok"] {
            XCTAssertTrue(BrowserTab.permitsNavigation(try XCTUnwrap(URL(string: url))), url)
        }
        for url in ["file:///etc/passwd", "FILE:///etc/passwd", "file://localhost/etc/passwd", "javascript:alert(1)", "ftp://example.com/",
                    "x-apple.systempreferences:", "noodlebrowser://provider/start", "mailto:a@example.com", "/etc/passwd"] {
            XCTAssertFalse(BrowserTab.permitsNavigation(try XCTUnwrap(URL(string: url))), url)
        }
        XCTAssertFalse(BrowserTab.permitsNavigation(URL(fileURLWithPath: "/etc/passwd")))
    }

    /// Local content enters a page only through the broker-staged upload.
    func testSourcesNeverGrantWebKitLocalFileAccess() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["loadFileURL", "allowingReadAccessTo", "allowFileAccessFromFileURLs", "allowUniversalAccessFromFileURLs"] {
                XCTAssertFalse(source.contains(forbidden), "\(file.lastPathComponent) uses \(forbidden)")
            }
        }
    }
}
