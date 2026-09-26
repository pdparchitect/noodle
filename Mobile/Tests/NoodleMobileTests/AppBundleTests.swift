import Testing
import UIKit
@testable import NoodleMobile

@Suite struct AppBundleTests {
    @Test func homeScreenNameIsNoodle() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(name == "Noodle Dev")
    }

    @Test func versionComesFromTheVersionFile() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(version?.split(separator: ".").count == 3)
    }

    /// The written word, pen included, fills the website's wordmark box.
    @Test func wordmarkFillsItsBox() {
        let drawn = Wordmark.skeleton.boundingRect.insetBy(dx: -Wordmark.pen / 2, dy: -Wordmark.pen / 2)
        #expect(abs(drawn.minX - Wordmark.bounds.minX) < 1 && abs(drawn.maxX - Wordmark.bounds.maxX) < 1)
        #expect(abs(drawn.minY - Wordmark.bounds.minY) < 1 && abs(drawn.maxY - Wordmark.bounds.maxY) < 1)
    }

    /// Invitation links and QR codes are noodle://join-hub links, the same as on the Mac.
    @Test func invitationLinksOpenTheApp() {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        #expect(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("noodle") == true })
    }

    /// iOS refuses the camera and the Hub's local address to an app that does not say why it needs them.
    @Test func permissionsSayWhyTheyAreNeeded() {
        for key in ["NSCameraUsageDescription", "NSLocalNetworkUsageDescription", "NSMicrophoneUsageDescription"] {
            #expect((Bundle.main.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false, "\(key)")
        }
    }
}
