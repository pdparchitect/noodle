import AppKit
import ComputerBridge

/// Launch Services may prefer an installed release over the local app that owns
/// the running computer library. Keep document opens on that same provider.
@MainActor enum ComputerApplication {
    static func locate() -> URL? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ComputerConnection.providerID)
            .filter { !$0.isTerminated }.compactMap(\.bundleURL)
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Noodle Computer.app")
        let development = Bundle.main.bundleIdentifier == "com.pdparchitect.noodle.local"
            && Bundle(url: sibling)?.bundleIdentifier == ComputerConnection.providerID ? sibling : nil
        return select(running: running, development: development,
            registered: NSWorkspace.shared.urlForApplication(withBundleIdentifier: ComputerConnection.providerID))
    }

    static func select(running: [URL], development: URL?, registered: URL?) -> URL? {
        if let development, running.contains(where: { $0.standardizedFileURL == development.standardizedFileURL }) {
            return development
        }
        return running.first ?? development ?? registered
    }
}
