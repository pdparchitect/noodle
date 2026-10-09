import CryptoKit
import Foundation
import XCTest

/// Verification runs pass plain argument names; the app may only know their digests.
final class ComputerLaunchCheckTests: XCTestCase {
    func testEveryDigestMatchesTheNameWrittenBesideIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/NoodleComputer")
        let line = try NSRegularExpression(pattern: #"static let \w+ = "([0-9a-f]{64})"\s+// (--[a-z-]+)$"#, options: .anchorsMatchLines)
        var names: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let text = source as NSString
            for match in line.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let name = text.substring(with: match.range(at: 2))
                let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, text.substring(with: match.range(at: 1)), name)
                names.append(name)
            }
            // The one plain argument is the production background launch.
            XCTAssertFalse(source.replacingOccurrences(of: "\"--noodle-background\"", with: "").contains("\"--"),
                           "\(file.lastPathComponent) spells a launch argument")
            XCTAssertFalse(source.contains("hasSuffix(\"-test\")") || source.contains("hasSuffix(\"-preview\")"),
                           "\(file.lastPathComponent) matches launch arguments by suffix")
        }
        XCTAssertEqual(names.count, 21)
    }
}
