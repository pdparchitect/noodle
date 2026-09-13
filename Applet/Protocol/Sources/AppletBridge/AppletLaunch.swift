import AppKit

public enum AppletLaunch {
    /// Launch Services preserves URLs from sandboxed callers, unlike launch arguments.
    /// This URL starts the provider without opening a creation.
    public static let backgroundURL = URL(string: "noodlet://provider/start")!

    @discardableResult
    public static func openInBackground(at applicationURL: URL) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return try await NSWorkspace.shared.open([backgroundURL],
            withApplicationAt: applicationURL, configuration: configuration)
    }
}
