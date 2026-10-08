import Foundation
import Testing

/// The external socket is out of reach of Noodle's bots only because no Noodle or Hub process
/// holds its app group. This keeps it that way.
@Suite struct ExternalGroupTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func onlyTheCompanionAppsHoldTheirExternalGroups() throws {
        let manager = FileManager.default
        var checked = 0
        for folder in ["Support", "Hub/Support", "Tools", "Applet/Support"] {
            let root = Self.repository.appendingPathComponent(folder)
            for case let url as URL in manager.enumerator(at: root, includingPropertiesForKeys: nil) ?? .init() where url.pathExtension == "entitlements" {
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.contains("EXTERNAL_GROUP") && !text.contains("external-"), "\(url.path) holds an external tools group")
                checked += 1
            }
        }
        #expect(checked >= 4)
        let browser = try String(contentsOf: Self.repository.appendingPathComponent("Browser/Support/Browser.entitlements"), encoding: .utf8)
        #expect(browser.contains("$(BROWSER_EXTERNAL_GROUP_SUFFIX)"))
    }
}
