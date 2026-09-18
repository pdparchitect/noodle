import Foundation
@testable import NoodleBrowser
import XCTest

final class BrowserResourcesTests: XCTestCase {
    func testPackagedAppUsesItsOwnResourcesForBothSwiftPMBundleLayouts() throws {
        for resourcePath in ["Resources", "Contents/Resources/Resources"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = root.appendingPathComponent("Relocated Browser.app")
            let bundle = app.appendingPathComponent("Contents/Resources/NoodleBrowser_NoodleBrowser.bundle")
            let resources = bundle.appendingPathComponent(resourcePath)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.browser.resources", "CFBundlePackageType": "APPL", "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            if resourcePath.hasPrefix("Contents/") {
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.browser.scripts", "CFBundlePackageType": "BNDL"], format: .xml, options: 0)
                    .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            }
            for name in ["Inspect.js", "PointerTarget.js", "WebMCP.js"] {
                try Data("packaged \(name)".utf8).write(to: resources.appendingPathComponent(name))
            }

            let resolved = BrowserResources.resolve(in: try XCTUnwrap(Bundle(url: app)))
            XCTAssertEqual(resolved.bundleURL.standardizedFileURL, bundle.standardizedFileURL)
            let scripts = try XCTUnwrap(resolved.url(forResource: "Resources", withExtension: nil))
            for name in ["Inspect.js", "PointerTarget.js", "WebMCP.js"] {
                XCTAssertEqual(try String(contentsOf: scripts.appendingPathComponent(name), encoding: .utf8), "packaged \(name)")
            }
        }
    }

    func testPackageTestsCanLoadAllBrowserScripts() throws {
        let scripts = try XCTUnwrap(BrowserResources.bundle.url(forResource: "Resources", withExtension: nil))
        for name in ["Inspect.js", "PointerTarget.js", "WebMCP.js"] {
            XCTAssertFalse(try Data(contentsOf: scripts.appendingPathComponent(name)).isEmpty, name)
        }
    }
}
