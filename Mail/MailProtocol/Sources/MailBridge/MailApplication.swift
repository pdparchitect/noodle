import AppKit

public enum MailApplication {
    /// Exact-id discovery only. A local build never falls back to the release.
    public static func locate(build: MailBuildIdentity = .current) -> URL? {
        guard MailBuildIdentity.processIdentity != nil else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: build.providerID)
            .filter { !$0.isTerminated && $0.bundleIdentifier == build.providerID }.compactMap(\.bundleURL)
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: build.providerID)
        let sibling = containingApplication(of: Bundle.main.bundleURL).deletingLastPathComponent().appendingPathComponent(build.appName + ".app")
        var known = Dictionary(running.map { ($0.standardizedFileURL.path, build.providerID) }, uniquingKeysWith: { a, _ in a })
        if let registered { known[registered.standardizedFileURL.path] = build.providerID }
        if Bundle(url: sibling)?.bundleIdentifier == build.providerID { known[sibling.standardizedFileURL.path] = build.providerID }
        return select(running: running, sibling: build == .development ? sibling : nil,
                      registered: registered, build: build, identify: { known[$0.standardizedFileURL.path] })
    }
    /// Noodle's Mail tool extension runs inside Noodle.app; a development companion sits beside
    /// that app, not beside the extension.
    public static func containingApplication(of bundle: URL) -> URL {
        let contents = bundle.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        return bundle.pathExtension == "appex" && contents.lastPathComponent == "Contents" && app.pathExtension == "app" ? app : bundle
    }
    public static func select(running: [URL], sibling: URL?, registered: URL?, build: MailBuildIdentity,
                              identify: @escaping (URL) -> String?) -> URL? {
        let valid: (URL) -> Bool = { identify($0) == build.providerID && !$0.pathComponents.contains(".Trash") && !$0.pathComponents.contains(".Trashes") }
        let running = running.filter(valid)
        let sibling = sibling.flatMap { valid($0) ? $0 : nil }
        if let sibling, running.contains(where: { $0.standardizedFileURL == sibling.standardizedFileURL }) { return sibling }
        return running.first ?? sibling ?? registered.flatMap { valid($0) ? $0 : nil }
    }
    public static func isInstalled(at url: URL?, build: MailBuildIdentity = .current) -> Bool {
        guard let url, !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes"),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL) {
            guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == build.providerID,
                  let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
            return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + name).path)
        }
        // Another app's Info.plist may be unreadable in App Sandbox. AppKit's exact-id lookup
        // supplies the identity; the socket verifies the signature.
        return locate(build: build)?.standardizedFileURL == url.standardizedFileURL
    }
}

public enum MailLaunch {
    /// Launch Services keeps URLs from sandboxed callers, unlike launch arguments.
    /// This URL starts Noodle Mail's socket without opening its window.
    public static var backgroundURL: URL { URL(string: MailBuildIdentity.current.urlScheme + "://provider/start")! }

    @discardableResult
    public static func openInBackground(at applicationURL: URL) async throws -> NSRunningApplication {
        guard MailBuildIdentity.processIdentity != nil, MailApplication.isInstalled(at: applicationURL) else {
            throw MailError("Open the matching signed \(MailBuildIdentity.current.appName) build for this environment.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return try await NSWorkspace.shared.open([backgroundURL], withApplicationAt: applicationURL, configuration: configuration)
    }
}
