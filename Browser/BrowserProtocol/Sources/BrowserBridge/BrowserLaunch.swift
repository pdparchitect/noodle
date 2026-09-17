import AppKit

public enum BrowserLaunch {
    /// Launch Services preserves URLs from sandboxed callers, unlike launch arguments.
    /// This URL starts the provider without opening a creation.
    public static var backgroundURL: URL { URL(string: BrowserBuildIdentity.current.urlScheme + "://provider/start")! }

    @discardableResult
    public static func openInBackground(at applicationURL: URL) async throws -> NSRunningApplication {
        guard BrowserBuildIdentity.processIdentity != nil,
              BrowserApplication.isInstalled(at: applicationURL) else {
            throw BrowserError("Open the matching signed Browser build for this environment.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return try await NSWorkspace.shared.open([backgroundURL],
            withApplicationAt: applicationURL, configuration: configuration)
    }
}
