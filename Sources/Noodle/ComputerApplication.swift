import AppKit
import ComputerBridge

/// Launch Services may prefer an installed release over the local app that owns
/// the running computer library. Keep document opens on that same provider.
@MainActor enum ComputerApplication {
    static func locate() -> URL? {
        let identity = ComputerBuildIdentity.current
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identity.providerID)
            .filter { !$0.isTerminated && $0.bundleIdentifier == identity.providerID }
        let running = applications.compactMap(\.bundleURL)
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identity.providerID)
        // App Sandbox may deny reading another app's Info.plist in a checkout.
        // Use the identities returned by AppKit for its exact-ID queries; the
        // connection separately authenticates the provider's signing identity.
        var known: [String: String] = [:]
        for url in running { known[url.standardizedFileURL.path] = identity.providerID }
        if let registered { known[registered.standardizedFileURL.path] = identity.providerID }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(identity.appName + ".app")
        if Bundle(url: sibling)?.bundleIdentifier == identity.providerID {
            known[sibling.standardizedFileURL.path] = identity.providerID
        }
        let development = identity == .development
            && known[sibling.standardizedFileURL.path] == identity.providerID ? sibling : nil
        return select(running: running, development: development,
            registered: registered, providerID: identity.providerID,
            identify: { known[$0.standardizedFileURL.path] })
    }

    static func select(running: [URL], development: URL?, registered: URL?,
                       providerID: String = ComputerConnection.providerID,
                       identify: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> URL? {
        // Check every candidate's reported identity, including registered results.
        // A missing local build must never silently open the production app.
        let running = running.filter { identify($0) == providerID }
        let development = development.flatMap { identify($0) == providerID ? $0 : nil }
        let registered = registered.flatMap { identify($0) == providerID ? $0 : nil }
        if let development, running.contains(where: { $0.standardizedFileURL == development.standardizedFileURL }) {
            return development
        }
        return running.first ?? development ?? registered
    }
}
