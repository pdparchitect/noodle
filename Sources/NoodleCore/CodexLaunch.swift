public enum CodexLaunch {
    /// Explicitly override inherited config for each Noodle runtime and probe.
    public static func appServerArguments(appsEnabled: Bool = false) -> [String] {
        // Codex has no environment switch for its usage reports; see HarnessProvider.reportingOffEnvironment.
        // Its plugins are ChatGPT's, synced from the account with a catalog of every plugin, tens of megabytes in
        // each bot, and made for ChatGPT's own pages; no bot uses them. Turned off as settings rather than with
        // --disable, which an older Codex that does not know a feature refuses to start with.
        ["app-server", "-c", "analytics.enabled=false", "-c", "features.plugins=false", "-c", "features.remote_plugin=false",
         appsEnabled ? "--enable" : "--disable", "apps"]
    }
}
