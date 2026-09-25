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
