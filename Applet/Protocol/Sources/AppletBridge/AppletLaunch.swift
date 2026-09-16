import AppKit

public enum AppletLaunch {
    /// Launch Services preserves URLs from sandboxed callers, unlike launch arguments.
    /// This URL starts the provider without opening a creation.
    public static var backgroundURL: URL { URL(string: AppletBuildIdentity.current.urlScheme + "://provider/start")! }

    @discardableResult
    public static func openInBackground(at applicationURL: URL) async throws -> NSRunningApplication {
        guard AppletBuildIdentity.processIdentity != nil,
              AppletApplication.isInstalled(at: applicationURL) else {
            throw AppletError("Open the matching signed Applet build for this environment.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return try await NSWorkspace.shared.open([backgroundURL],
            withApplicationAt: applicationURL, configuration: configuration)
    }
}
