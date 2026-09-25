import Testing
import UIKit

@Suite struct AppBundleTests {
    @Test func homeScreenNameIsNoodle() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(name == "Noodle Dev")
    }

    @Test func versionComesFromTheVersionFile() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(version?.split(separator: ".").count == 3)
    }

    @Test func symbolIsBundled() {
        #expect(UIImage(named: "Symbol") != nil)
    }
}
