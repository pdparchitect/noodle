import Foundation

enum NoodleAppIdentity {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Noodle"
    }

    /// Development bundles ship in the release configuration, so `#if DEBUG` cannot tell them apart.
    static var isDevelopment: Bool { isDevelopment(bundleIdentifier: Bundle.main.bundleIdentifier) }

    static func isDevelopment(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasSuffix(".noodle.local") ?? true
    }
}
