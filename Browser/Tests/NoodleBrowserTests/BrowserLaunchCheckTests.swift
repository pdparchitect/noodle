import Foundation
import NoodleLaunchChecks
import XCTest

/// Verification scripts pass plain argument names; the app may only know their digests.
final class BrowserLaunchCheckTests: XCTestCase {
    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/NoodleBrowser")
        return try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testEveryDigestMatchesTheNameWrittenBesideIt() throws {
        let line = try NSRegularExpression(pattern: #"static let \w+ = "([0-9a-f]{64})"\s+// (--[a-z-]+)$"#, options: .anchorsMatchLines)
        var names: [String] = []
        for source in try sources() {
            let text = source.text as NSString
            for match in line.matches(in: source.text, range: NSRange(location: 0, length: text.length)) {
                let name = text.substring(with: match.range(at: 2))
                XCTAssertEqual(LaunchChecks.digest(name), text.substring(with: match.range(at: 1)), name)
                names.append(name)
            }
        }
        XCTAssertEqual(names.sorted(), ["--browser-ui-id", "--browser-ui-test", "--cleanup", "--cleanup-ui", "--pointer-only", "--restore",
            "--serve-smoke", "--smoke-id", "--smoke-port", "--smoke-test", "--webmcp-demos", "--webmcp-only"])
    }

    func testSourcesSpellNoLaunchArgument() throws {
        for source in try sources() {
            XCTAssertFalse(source.text.contains("\"--"), "\(source.name) spells a launch argument")
            XCTAssertFalse(source.text.contains("hasSuffix(\"-test\")"), "\(source.name) matches launch arguments by suffix")
        }
    }
}
