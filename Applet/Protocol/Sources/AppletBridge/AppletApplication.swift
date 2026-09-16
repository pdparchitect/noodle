import AppKit

public enum AppletApplication {
    /// Exact-ID discovery only. A local build never falls back to the release.
    public static func locate(build: AppletBuildIdentity = .current) -> URL? {
        guard AppletBuildIdentity.processIdentity != nil else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: build.providerID)
            .filter { !$0.isTerminated && $0.bundleIdentifier == build.providerID }.compactMap(\.bundleURL)
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: build.providerID)
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(build.appName + ".app")
        var known = Dictionary(running.map { ($0.standardizedFileURL.path, build.providerID) }, uniquingKeysWith: { a, _ in a })
        if let registered { known[registered.standardizedFileURL.path] = build.providerID }
        if Bundle(url: sibling)?.bundleIdentifier == build.providerID { known[sibling.standardizedFileURL.path] = build.providerID }
        return select(running: running, sibling: build == .development ? sibling : nil,
                      registered: registered, build: build, identify: { known[$0.standardizedFileURL.path] })
    }
    public static func select(running: [URL], sibling: URL?, registered: URL?, build: AppletBuildIdentity,
                              identify: @escaping (URL) -> String?) -> URL? {
        let valid: (URL) -> Bool = { identify($0) == build.providerID && !$0.pathComponents.contains(".Trash") && !$0.pathComponents.contains(".Trashes") }
        let running = running.filter(valid)
        let sibling = sibling.flatMap { valid($0) ? $0 : nil }
        if let sibling, running.contains(where: { $0.standardizedFileURL == sibling.standardizedFileURL }) { return sibling }
        return running.first ?? sibling ?? registered.flatMap { valid($0) ? $0 : nil }
    }
    public static func isInstalled(at url: URL?, build: AppletBuildIdentity = .current) -> Bool {
        guard let url, !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes"),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL) {
            guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == build.providerID,
                  let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
            return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + name).path)
        }
        // Another app's Info.plist may be unreadable in App Sandbox. AppKit's
        // exact-ID lookup supplies discovery identity; the socket verifies signing.
        return locate(build: build)?.standardizedFileURL == url.standardizedFileURL
    }
}
